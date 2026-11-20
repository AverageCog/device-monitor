import Foundation
import Security
import os

/// What the client and pairing need from a connection pool with one trust policy. `PinnedSession`
/// is the only production implementation; unit tests script their own.
protocol PinnedTransport: Sendable {
    func data(for request: URLRequest, timeout: TimeInterval, maxResponseBytes: Int) async throws -> PinnedSession.Response
    func bytes(for request: URLRequest, idleTimeout: TimeInterval) -> PinnedSession.ByteStream
    /// Cancels everything in flight and accepts no more requests.
    func invalidate()
    /// Lets requests in flight finish and accepts no more.
    func retire()
}

/// A `URLSession` whose every TLS connection passes standard validation (trusted chain, validity,
/// hostname) and then one fixed pin policy, before a single HTTP byte is written.
///
/// The policy belongs to the session rather than to a request because `URLSession` reuses
/// connections: a request only triggers a handshake when no verified connection is idle, so a
/// per-request policy could ride on a connection that was checked against a different pin. One
/// session, one policy, one connection pool; a new pin means a new `PinnedSession`.
///
/// No cookies, no cache, no credential storage, no redirects, HTTPS only.
public final class PinnedSession: Sendable {
    public enum Policy: Sendable, Hashable {
        /// Accept any key that passes standard validation and report its pin with the response.
        /// Only for the unauthenticated probe that starts pairing.
        case capture
        /// Refuse the handshake unless the leaf certificate's key has this pin.
        case require(pin: String)
    }

    public struct Response: Sendable {
        public let data: Data
        public let response: HTTPURLResponse
        /// The pin of the key that served this response. With `.capture` it is nil when the
        /// request rode on a connection opened by an earlier request of the same session.
        public let peerPin: String?
    }

    enum StreamEvent: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    /// A response being received. Abandoning `events` does not stop the request (the producer
    /// keeps the stream alive), so whoever stops reading early must call `cancel`.
    struct ByteStream: Sendable {
        let events: AsyncThrowingStream<StreamEvent, any Error>
        let cancel: @Sendable () -> Void
    }

    public let policy: Policy
    private let core: Core
    private let session: URLSession

    public convenience init(policy: Policy) {
        self.init(policy: policy, testingTrustAnchors: [])
    }

    /// TESTING ONLY. `testingTrustAnchors` are DER certificates trusted in addition to the system
    /// and user-installed roots, so tests can reach a hub behind a throwaway CA.
    ///
    /// Deliberately `internal`: the app target cannot call it, and a release build of this package
    /// has no `@testable` access either. Do not add a public path to it; a device or simulator
    /// that must trust a test CA gets it installed as a root certificate instead.
    init(policy: Policy, testingTrustAnchors: [Data]) {
        let core = Core(policy: policy, anchors: testingTrustAnchors)
        let queue = OperationQueue()
        queue.name = "DMCore.PinnedSession"
        queue.maxConcurrentOperationCount = 1
        self.policy = policy
        self.core = core
        self.session = URLSession(configuration: Self.configuration(), delegate: core, delegateQueue: queue)
    }

    deinit {
        // The session retains its delegate until it is invalidated.
        session.invalidateAndCancel()
    }

    /// Performs one request. `timeout` bounds the whole exchange, not just the gaps between
    /// packets; the body is refused beyond `maxResponseBytes`. Any HTTP status is returned except
    /// a redirect, which throws `HubError.redirectRefused`.
    public func data(for request: URLRequest, timeout: TimeInterval, maxResponseBytes: Int) async throws -> Response {
        guard let request = Self.prepared(request, idleTimeout: timeout) else { throw HubError.invalidRequest }
        let canceller = Canceller()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                core.start(request, on: session, sink: .data(limit: maxResponseBytes, continuation: continuation), deadline: timeout, canceller: canceller)
            }
        } onCancel: {
            canceller.cancel()
        }
    }

    /// Opens a long-lived response and delivers it as the session's delegate receives it: first
    /// the response head, then each chunk of body. Ends with an error if nothing arrives for
    /// `idleTimeout`; cancelling the consuming task cancels the request.
    func bytes(for request: URLRequest, idleTimeout: TimeInterval) -> ByteStream {
        let canceller = Canceller()
        let events = AsyncThrowingStream<StreamEvent, any Error>(bufferingPolicy: .unbounded) { continuation in
            guard let request = Self.prepared(request, idleTimeout: idleTimeout) else {
                continuation.finish(throwing: HubError.invalidRequest)
                return
            }
            // Holding `self` keeps the URLSession alive for as long as the stream is.
            continuation.onTermination = { _ in withExtendedLifetime(self) { canceller.cancel() } }
            core.start(request, on: session, sink: .stream(continuation), deadline: nil, canceller: canceller)
        }
        return ByteStream(events: events, cancel: { canceller.cancel() })
    }

    public func invalidate() {
        core.close()
        session.invalidateAndCancel()
    }

    func retire() {
        core.close()
        session.finishTasksAndInvalidate()
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    private static func prepared(_ request: URLRequest, idleTimeout: TimeInterval) -> URLRequest? {
        guard request.url?.scheme == "https" else { return nil }
        var request = request
        request.timeoutInterval = idleTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        return request
    }
}

extension PinnedSession: PinnedTransport {}

/// Lets a cancellation that arrives before the `URLSessionTask` exists still reach it.
private final class Canceller: Sendable {
    private struct State {
        var cancelled = false
        var task: URLSessionTask?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func bind(_ task: URLSessionTask) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// The session delegate. Callbacks arrive on the session's serial queue; requests start and are
/// cancelled from any thread, so all state sits behind one lock and is keyed by task.
private final class Core: NSObject, URLSessionDataDelegate {
    enum Sink: Sendable {
        case data(limit: Int, continuation: CheckedContinuation<PinnedSession.Response, any Error>)
        case stream(AsyncThrowingStream<PinnedSession.StreamEvent, any Error>.Continuation)
    }

    private struct TaskState: Sendable {
        let sink: Sink
        var body = Data()
        var response: HTTPURLResponse?
        /// The key this task's own handshake presented.
        var peerPin: String?
        /// Why this layer stopped the task. It replaces the bare "cancelled" URLSession reports.
        var failure: HubError?
    }

    private struct State: Sendable {
        var tasks: [Int: TaskState] = [:]
        var closed = false
        var verifiedHandshakes = 0
    }

    private let policy: PinnedSession.Policy
    private let anchors: [Data]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(policy: PinnedSession.Policy, anchors: [Data]) {
        self.policy = policy
        self.anchors = anchors
    }

    func start(_ request: URLRequest, on session: URLSession, sink: Sink, deadline: TimeInterval?, canceller: Canceller) {
        // Creating a task on an invalidated session raises an Objective-C exception, so creation
        // and `close()` exclude each other.
        let task: URLSessionDataTask? = state.withLock { state in
            guard !state.closed else { return nil }
            let task = session.dataTask(with: request)
            state.tasks[task.taskIdentifier] = TaskState(sink: sink)
            return task
        }
        guard let task else {
            Self.finish(sink, .failure(HubError.cancelled))
            return
        }
        task.resume()
        canceller.bind(task)
        if let deadline {
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self, weak task] in
                guard let self, let task else { return }
                self.stop(task, because: .unreachable(HubError.Reason.timedOut))
            }
        }
    }

    func close() {
        state.withLock { $0.closed = true }
    }

    /// Records why a task is being stopped, then cancels it. The first reason wins.
    private func stop(_ task: URLSessionTask, because failure: HubError) {
        let id = task.taskIdentifier
        let running = state.withLock { state in
            guard state.tasks[id] != nil else { return false }
            if state.tasks[id]?.failure == nil { state.tasks[id]?.failure = failure }
            return true
        }
        if running { task.cancel() }
    }

    private static func finish(_ sink: Sink, _ result: Result<PinnedSession.Response, any Error>) {
        switch (sink, result) {
        case (.data(_, let continuation), _): continuation.resume(with: result)
        case (.stream(let continuation), .success): continuation.finish()
        case (.stream(let continuation), .failure(let error)): continuation.finish(throwing: error)
        }
    }

    // MARK: Trust

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let id = task.taskIdentifier
        let trust = challenge.protectionSpace.serverTrust
        let verdict: Result<String, HubError> = if let trust {
            evaluate(trust).flatMap { pin in
                if case .require(let enrolled) = policy, enrolled != pin { .failure(.pinMismatch(peerPin: pin)) } else { .success(pin) }
            }
        } else {
            .failure(.untrustedCertificate("The hub presented no certificate."))
        }
        state.withLock { state in
            switch verdict {
            case .success(let pin):
                state.verifiedHandshakes += 1
                state.tasks[id]?.peerPin = pin
            case .failure(let failure):
                if state.tasks[id]?.failure == nil { state.tasks[id]?.failure = failure }
            }
        }
        if case .success = verdict, let trust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Ends the handshake: the request, and with it the bearer, is never written.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Standard evaluation first, then the pin of the leaf it validated.
    private func evaluate(_ trust: SecTrust) -> Result<String, HubError> {
        if !anchors.isEmpty {
            let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard certificates.count == anchors.count,
                  SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
                  // Keep trusting the system and user-installed roots as well.
                  SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
                return .failure(.untrustedCertificate("The test trust anchors are unusable."))
            }
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = ((error as (any Error)?)?.localizedDescription ?? "").unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F }
            var text = String(String.UnicodeScalarView(reason.prefix(200)))
            if !text.isEmpty, !text.hasSuffix(".") { text += "." }
            return .failure(.untrustedCertificate(text))
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let pin = try? SPKIPin.pin(certificateDER: SecCertificateCopyData(leaf) as Data) else {
            return .failure(.untrustedCertificate("Its public key could not be read."))
        }
        return .success(pin)
    }

    // MARK: Responses

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let id = task.taskIdentifier
        state.withLock { state in
            if state.tasks[id]?.failure == nil { state.tasks[id]?.failure = .redirectRefused }
        }
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        let http = response as? HTTPURLResponse
        let opened: Sink? = state.withLock { state in
            guard let sink = state.tasks[id]?.sink, state.tasks[id]?.failure == nil else { return nil }
            var failure: HubError?
            if let http {
                // Fail closed if the system ever skipped the trust callback for this session.
                if state.verifiedHandshakes == 0 { failure = .untrustedCertificate(HubError.Reason.unverified) }
                else if (300..<400).contains(http.statusCode) { failure = .redirectRefused }
                else if case .data(let limit, _) = sink, http.expectedContentLength > Int64(limit) { failure = .responseTooLarge }
            } else {
                failure = .invalidResponse
            }
            if let failure {
                state.tasks[id]?.failure = failure
                return nil
            }
            state.tasks[id]?.response = http
            return sink
        }
        guard let opened, let http else {
            completionHandler(.cancel)
            return
        }
        if case .stream(let continuation) = opened { continuation.yield(.response(http)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        enum Action { case ignore, cancel, forward(AsyncThrowingStream<PinnedSession.StreamEvent, any Error>.Continuation) }
        let action: Action = state.withLock { state in
            guard let sink = state.tasks[id]?.sink, state.tasks[id]?.failure == nil else { return .ignore }
            switch sink {
            case .stream(let continuation):
                return .forward(continuation)
            case .data(let limit, _):
                guard (state.tasks[id]?.body.count ?? 0) + data.count <= limit else {
                    state.tasks[id]?.failure = .responseTooLarge
                    return .cancel
                }
                state.tasks[id]?.body.append(data)
                return .ignore
            }
        }
        switch action {
        case .ignore: break
        case .cancel: dataTask.cancel()
        case .forward(let continuation): continuation.yield(.data(data))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let finished = state.withLock({ $0.tasks.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = finished.failure ?? error.map(HubError.transport) {
            Self.finish(finished.sink, .failure(failure))
        } else if let response = finished.response {
            // Every connection of a `.require` session presented the enrolled key.
            let pin: String? = if case .require(let enrolled) = policy { enrolled } else { finished.peerPin }
            Self.finish(finished.sink, .success(PinnedSession.Response(data: finished.body, response: response, peerPin: pin)))
        } else {
            Self.finish(finished.sink, .failure(HubError.invalidResponse))
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        // Every task has completed by now; this only guards against a continuation left waiting.
        let abandoned = state.withLock { state in
            let tasks = Array(state.tasks.values)
            state.tasks = [:]
            return tasks
        }
        for task in abandoned { Self.finish(task.sink, .failure(HubError.cancelled)) }
    }
}

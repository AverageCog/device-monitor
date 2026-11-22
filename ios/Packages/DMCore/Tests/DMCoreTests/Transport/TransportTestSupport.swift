import CryptoKit
import Foundation
import os
@testable import DMCore

/// A scripted hub for the unit tests: it stands where `PinnedSession` would, so client logic can
/// be exercised without a network. A handshake is modelled the way TLS behaves: a transport that
/// requires a pin other than the one the "server" presents fails before the request is seen.
final class FakeHub: Sendable {
    struct Call: Sendable {
        let policy: PinnedSession.Policy
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let contentType: String?
        let body: Data?
        let timeout: TimeInterval
        let limit: Int
        let isStream: Bool

        var json: [String: String] {
            (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]) ?? [:]
        }
    }

    struct Reply: Sendable {
        var status = 200
        var body = Data()

        static func json(_ status: Int = 200, _ text: String) -> Reply { Reply(status: status, body: Data(text.utf8)) }
    }

    typealias Handler = @Sendable (Call) async throws -> Reply
    typealias StreamHandler = @Sendable (Call) -> AsyncThrowingStream<PinnedSession.StreamEvent, any Error>

    private struct State: Sendable {
        var servedPin: String
        var handler: Handler = { _ in Reply() }
        var streamHandler: StreamHandler = { _ in AsyncThrowingStream { $0.finish() } }
        var calls: [Call] = []
        var refusedHandshakes: [PinnedSession.Policy] = []
        var policies: [PinnedSession.Policy] = []
        var invalidated: [PinnedSession.Policy] = []
        var retired: [PinnedSession.Policy] = []
        var streamCancels = 0
        var reportsPinOnCapture = true
    }

    private let state: OSAllocatedUnfairLock<State>

    init(servedPin: String) {
        state = OSAllocatedUnfairLock(initialState: State(servedPin: servedPin))
    }

    var connect: @Sendable (PinnedSession.Policy) -> any PinnedTransport {
        { policy in
            self.state.withLock { $0.policies.append(policy) }
            return FakeTransport(hub: self, policy: policy)
        }
    }

    var servedPin: String {
        get { state.withLock { $0.servedPin } }
        set { state.withLock { $0.servedPin = newValue } }
    }

    var reportsPinOnCapture: Bool {
        get { state.withLock { $0.reportsPinOnCapture } }
        set { state.withLock { $0.reportsPinOnCapture = newValue } }
    }

    func onRequest(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }
    func onStream(_ handler: @escaping StreamHandler) { state.withLock { $0.streamHandler = handler } }

    /// Requests that got past the handshake, in order.
    var calls: [Call] { state.withLock { $0.calls } }
    var refusedHandshakes: [PinnedSession.Policy] { state.withLock { $0.refusedHandshakes } }
    /// Every transport the client asked for.
    var policies: [PinnedSession.Policy] { state.withLock { $0.policies } }
    var invalidated: [PinnedSession.Policy] { state.withLock { $0.invalidated } }
    var retired: [PinnedSession.Policy] { state.withLock { $0.retired } }
    var streamCancels: Int { state.withLock { $0.streamCancels } }

    func calls(to path: String) -> [Call] { calls.filter { $0.path == path } }

    /// The pin a verified handshake saw, or the mismatch a pinned client reports.
    fileprivate func handshake(_ policy: PinnedSession.Policy) throws -> String? {
        try state.withLock { state in
            if case .require(let pin) = policy, pin != state.servedPin {
                state.refusedHandshakes.append(policy)
                throw HubError.pinMismatch(peerPin: state.servedPin)
            }
            if case .capture = policy, !state.reportsPinOnCapture { return nil }
            return state.servedPin
        }
    }

    fileprivate func record(_ call: Call) -> (Handler, StreamHandler) {
        state.withLock { state in
            state.calls.append(call)
            return (state.handler, state.streamHandler)
        }
    }

    fileprivate func closed(_ policy: PinnedSession.Policy, retired: Bool) {
        state.withLock { state in
            if retired { state.retired.append(policy) } else { state.invalidated.append(policy) }
        }
    }

    fileprivate func streamCancelled() { state.withLock { $0.streamCancels += 1 } }
}

private final class FakeTransport: PinnedTransport {
    private enum Phase: Sendable { case open, retired, invalidated }

    private struct State: Sendable {
        var phase = Phase.open
        /// Requests and streams that were let in and have not ended yet.
        var inFlight = 0
        var running: [UUID: Task<FakeHub.Reply, any Error>] = [:]
        var streams: [UUID: AsyncThrowingStream<PinnedSession.StreamEvent, any Error>.Continuation] = [:]
    }

    private let hub: FakeHub
    private let policy: PinnedSession.Policy
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(hub: FakeHub, policy: PinnedSession.Policy) {
        self.hub = hub
        self.policy = policy
    }

    private func describe(_ request: URLRequest, timeout: TimeInterval, limit: Int, isStream: Bool) -> FakeHub.Call {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        return FakeHub.Call(
            policy: policy, method: request.httpMethod ?? "GET", path: components?.percentEncodedPath ?? "", query: components?.percentEncodedQuery,
            authorization: request.value(forHTTPHeaderField: "Authorization"), contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: request.httpBody, timeout: timeout, limit: limit, isStream: isStream)
    }

    /// Lets one request or stream in, or says how the real session refuses it. Like the real
    /// session, letting in and closing exclude each other.
    private func admit() -> (any Error)? {
        state.withLock { state in
            switch state.phase {
            case .open:
                state.inFlight += 1
                return nil
            case .retired: return PinnedSession.Retired()
            case .invalidated: return HubError.cancelled
            }
        }
    }

    private func ended() { state.withLock { $0.inFlight -= 1 } }

    func data(for request: URLRequest, timeout: TimeInterval, maxResponseBytes: Int) async throws -> PinnedSession.Response {
        if let refusal = admit() { throw refusal }
        defer { ended() }
        let peerPin = try hub.handshake(policy)
        let call = describe(request, timeout: timeout, limit: maxResponseBytes, isStream: false)
        let (handler, _) = hub.record(call)
        let id = UUID()
        let work = Task { try await handler(call) }
        // A retired transport lets this request finish; an invalidated one cancels it.
        let cancelled = state.withLock { state in
            if state.phase != .invalidated { state.running[id] = work }
            return state.phase == .invalidated
        }
        if cancelled { work.cancel() }
        defer { state.withLock { _ = $0.running.removeValue(forKey: id) } }
        let reply: FakeHub.Reply
        do {
            reply = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError {
            throw HubError.cancelled
        }
        if (300..<400).contains(reply.status) { throw HubError.redirectRefused }
        guard reply.body.count <= maxResponseBytes else { throw HubError.responseTooLarge }
        // Everything the hub's `send()` writes is labelled as JSON.
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return PinnedSession.Response(data: reply.body, response: response, peerPin: peerPin)
    }

    func bytes(for request: URLRequest, idleTimeout: TimeInterval) -> PinnedSession.ByteStream {
        let hub = hub, state = state
        let cancel: @Sendable () -> Void = { hub.streamCancelled() }
        func failed(_ error: any Error) -> PinnedSession.ByteStream {
            PinnedSession.ByteStream(events: AsyncThrowingStream { $0.finish(throwing: error) }, cancel: cancel)
        }
        if let refusal = admit() { return failed(refusal) }
        do {
            _ = try hub.handshake(policy)
        } catch {
            ended()
            return failed(error)
        }
        let call = describe(request, timeout: idleTimeout, limit: 0, isStream: true)
        let (_, handler) = hub.record(call)
        let source = handler(call)
        let id = UUID()
        // The scripted response passes through a stream of the transport's own, so that it is in
        // flight until it ends and invalidation can end it, as with the real session.
        let events = AsyncThrowingStream<PinnedSession.StreamEvent, any Error>(bufferingPolicy: .unbounded) { continuation in
            let finished: @Sendable () -> Void = {
                state.withLock { state in
                    if state.streams.removeValue(forKey: id) != nil { state.inFlight -= 1 }
                }
            }
            let open = state.withLock { state in
                if state.phase != .invalidated { state.streams[id] = continuation } else { state.inFlight -= 1 }
                return state.phase != .invalidated
            }
            guard open else {
                continuation.finish(throwing: HubError.cancelled)
                return
            }
            let forward = Task {
                do {
                    for try await event in source { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                finished()
            }
            continuation.onTermination = { _ in
                forward.cancel()
                finished()
            }
        }
        return PinnedSession.ByteStream(events: events, cancel: cancel)
    }

    func invalidate() {
        let (running, streams) = state.withLock { state in
            state.phase = .invalidated
            defer {
                state.inFlight -= state.streams.count
                state.running = [:]
                state.streams = [:]
            }
            return (Array(state.running.values), Array(state.streams.values))
        }
        running.forEach { $0.cancel() }
        streams.forEach { $0.finish(throwing: HubError.cancelled) }
        hub.closed(policy, retired: false)
    }

    func retire() {
        state.withLock { state in
            if state.phase == .open { state.phase = .retired }
        }
        hub.closed(policy, retired: true)
    }

    var isDrained: Bool {
        state.withLock { $0.phase != .open && $0.inFlight == 0 }
    }
}

/// Stands between the client and a transport and holds chosen requests back before they reach it,
/// the way a busy executor delays the hop from the client's actor to `PinnedTransport.data`.
final class HeldTransport: PinnedTransport {
    private let inner: any PinnedTransport
    private let hold: @Sendable (URLRequest) async -> Void

    init(_ inner: any PinnedTransport, hold: @escaping @Sendable (URLRequest) async -> Void) {
        self.inner = inner
        self.hold = hold
    }

    func data(for request: URLRequest, timeout: TimeInterval, maxResponseBytes: Int) async throws -> PinnedSession.Response {
        await hold(request)
        return try await inner.data(for: request, timeout: timeout, maxResponseBytes: maxResponseBytes)
    }

    func bytes(for request: URLRequest, idleTimeout: TimeInterval) -> PinnedSession.ByteStream { inner.bytes(for: request, idleTimeout: idleTimeout) }
    func invalidate() { inner.invalidate() }
    func retire() { inner.retire() }
    var isDrained: Bool { inner.isDrained }
}

enum TransportFixtures {
    static let origin = "https://hub.example:8443"
    static let client = "cLiEnT-credential_0123456789abcdefghijklmno"
    static let proof = "pRoOf_secret-0123456789ABCDEFGHIJKLMNOPQRST"
    static let id = "0b8f6a52-6c1e-4b7e-9a57-0d7a6d2c9f11"
    static let code = "vQZQ-sH2nBEYHfiE0uy58cZyG76jJ790eLJVZBZ_0p4"

    /// A distinct, well-formed pin per letter.
    static func pin(_ letter: Character) -> String { String(repeating: letter, count: 43) + "=" }

    static func enrollment(pin: String = pin("A")) throws -> Enrollment {
        try Enrollment(origin: HubOrigin(origin), id: id, client: client, proof: proof, pin: pin, name: "Test iPhone", pairedAt: Date(timeIntervalSince1970: 1_795_000_000))
    }

    /// What the real hub does at `POST /api/desktop/tls-proof` for this enrollment
    /// (`desktopProofKey()` in `access.js` and the route in `server.js`).
    static func proofReply(to call: FakeHub.Call, signing pin: String, client: String = client, proof: String = proof) -> FakeHub.Reply {
        let key = HubIdentity.proofKey(client: client, proof: proof)
        let body = call.json
        guard let lookup = body["lookup"], let nonce = body["nonce"], let challenge = body["challenge"],
              HubIdentity.isValidSecret(nonce), lookup == HubIdentity.mac(key, "lookup"),
              challenge == HubIdentity.mac(key, "desktop", origin, nonce) else {
            return .json(403, #"{"error":"Desktop proof refused"}"#)
        }
        let object = ["proof": HubIdentity.mac(key, "hub", origin, nonce, pin)]
        return FakeHub.Reply(status: 200, body: (try? JSONEncoder().encode(object)) ?? Data())
    }

    static let proofPath = "/api/desktop/tls-proof"
}

/// Counts and remembers across `@Sendable` closures.
final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    @discardableResult func increment() -> Int { value.withLock { $0 += 1; return $0 } }
}

/// A credential store whose `save` can be made to fail.
final class FailingStore: CredentialStore {
    private let inner: InMemoryCredentialStore
    private let failures = OSAllocatedUnfairLock(initialState: 0)
    let saves = Counter()

    init(_ enrollment: Enrollment?, failingSaves: Int) {
        inner = InMemoryCredentialStore(enrollment)
        failures.withLock { $0 = failingSaves }
    }

    func load() throws -> Enrollment? { try inner.load() }

    func save(_ enrollment: Enrollment) throws {
        saves.increment()
        let fail = failures.withLock { remaining in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fail { throw CredentialStoreError.keychain(status: -25308) }
        try inner.save(enrollment)
    }

    func clear() throws { try inner.clear() }
}

func hubError(_ operation: () async throws -> Void) async -> HubError? {
    do {
        try await operation()
        return nil
    } catch let error as HubError {
        return error
    } catch {
        return .unreachable("unexpected error type: \(type(of: error))")
    }
}

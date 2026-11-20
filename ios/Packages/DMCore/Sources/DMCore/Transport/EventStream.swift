import Foundation
import os

/// The hub's live stream (`GET /api/stream`), one connection attempt at a time. Counterpart of
/// `HubEvents.read()` in `public/session.js`; reconnecting is the caller's business (the dashboard
/// waits 3 s).
///
/// ```swift
/// do {
///     for try await frame in EventStream(client: client).frames() { apply(frame) }   // JSON per frame
///     // the hub closed the stream
/// } catch let error as HubError where error.isUnauthorized {
///     // the enrollment was revoked
/// } catch { /* unreachable: retry later */ }
/// ```
public struct EventStream: Sendable {
    public static let path = "/api/stream"
    /// The hub sends a status frame every 3 s; this much silence means the connection is dead.
    public static let idleTimeout: TimeInterval = 15
    /// Frames the consumer has not taken yet may hold this much before the stream gives up.
    static let backlogLimit = 64 * 1024 * 1024

    private let client: HubClient
    private let idleTimeout: TimeInterval

    public init(client: HubClient) {
        self.init(client: client, idleTimeout: Self.idleTimeout)
    }

    init(client: HubClient, idleTimeout: TimeInterval) {
        self.client = client
        self.idleTimeout = idleTimeout
    }

    /// Connects and yields the payload of each `data:` frame as it completes; the first is the
    /// snapshot. The sequence
    /// - throws `HubError.unauthorized` when the hub answers 401/403,
    /// - throws another `HubError` when the hub cannot be reached or verified, when the connection
    ///   drops, or when nothing arrives for 15 s,
    /// - finishes without an error when the hub ends the response cleanly.
    ///
    /// The network request is cancelled when the consuming task is cancelled and when the returned
    /// stream (with its iterator) is discarded, so leaving the loop early is enough.
    /// A changed hub TLS key is verified and adopted exactly as for `HubClient.request`.
    public func frames() -> AsyncThrowingStream<Data, any Error> {
        let connection = Connection(client: client, idleTimeout: idleTimeout)
        // Pull-based on purpose: the stream owns `connection` through this closure and nothing
        // else does, so dropping the stream is what ends the connection.
        return AsyncThrowingStream(unfolding: { try await connection.next() })
    }

    private final class Connection: Sendable {
        private let queue: FrameQueue
        private let worker: Task<Void, Never>

        init(client: HubClient, idleTimeout: TimeInterval) {
            let queue = FrameQueue(limit: EventStream.backlogLimit)
            self.queue = queue
            self.worker = Task { await EventStream.run(client: client, idleTimeout: idleTimeout, into: queue) }
        }

        deinit {
            worker.cancel()
            queue.abandon()
        }

        func next() async throws -> Data? {
            do {
                if let frame = try await queue.next() { return frame }
            } catch {
                worker.cancel()
                throw error
            }
            worker.cancel()
            return nil
        }
    }

    private static func run(client: HubClient, idleTimeout: TimeInterval, into queue: FrameQueue) async {
        do {
            var recovered = false
            while true {
                guard !Task.isCancelled else { throw HubError.cancelled }
                let (pin, stream) = try await client.openStream(idleTimeout: idleTimeout)
                do {
                    try await pump(stream, into: queue)
                    queue.finish(nil)
                    return
                } catch HubError.pinMismatch(let peerPin) where !recovered {
                    // Refused in the handshake, before the bearer was sent: prove, then reconnect once.
                    recovered = true
                    try await client.refresh(previous: pin, candidate: peerPin)
                }
            }
        } catch {
            queue.finish(error)
        }
    }

    private static func pump(_ stream: PinnedSession.ByteStream, into queue: FrameQueue) async throws {
        defer { stream.cancel() }
        var parser = SSEParser()
        var head: HTTPURLResponse?
        var refusal = Data()
        for try await event in stream.events {
            switch event {
            case .response(let response):
                head = response
            case .data(let chunk):
                guard let head else { continue }
                if (200..<300).contains(head.statusCode) {
                    for frame in try parser.feed(chunk) {
                        guard queue.push(frame) else { return }
                    }
                } else if refusal.count + chunk.count <= HubClient.smallResponseLimit {
                    refusal.append(chunk)
                }
            }
        }
        if let head, !(200..<300).contains(head.statusCode) {
            throw HubError.status(head.statusCode, body: refusal, to: .stream)
        }
    }
}

/// Hands frames from the connection to the one task iterating them.
final class FrameQueue: Sendable {
    private struct State: Sendable {
        var frames: [Data] = []
        var head = 0
        var bytes = 0
        var waiter: CheckedContinuation<Data?, any Error>?
        var ended = false
        var failure: (any Error)?
        var abandoned = false
    }

    private enum Step: Sendable {
        case deliver(Data)
        case end((any Error)?)
        case wait
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = limit
    }

    /// False once the consumer is gone or too far behind; the producer should stop.
    func push(_ frame: Data) -> Bool {
        let (accepted, waiter): (Bool, CheckedContinuation<Data?, any Error>?) = state.withLock { state in
            guard !state.ended, !state.abandoned else { return (false, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (true, waiter)
            }
            guard state.bytes + frame.count <= limit else {
                state.ended = true
                state.failure = HubError.unreachable("The app fell too far behind the hub's live stream.")
                return (false, nil)
            }
            state.frames.append(frame)
            state.bytes += frame.count
            return (true, nil)
        }
        waiter?.resume(returning: frame)
        return accepted
    }

    /// Ends the sequence once the frames already queued have been delivered.
    func finish(_ error: (any Error)?) {
        let waiter: CheckedContinuation<Data?, any Error>? = state.withLock { state in
            guard !state.ended else { return nil }
            state.ended = true
            state.failure = error
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: Self.ending(error))
    }

    private static func ending(_ error: (any Error)?) -> Result<Data?, any Error> {
        if let error { .failure(error) } else { .success(nil) }
    }

    /// The consumer stopped: drop what is queued and release it if it is waiting.
    func abandon() {
        let waiter: CheckedContinuation<Data?, any Error>? = state.withLock { state in
            state.abandoned = true
            state.frames = []
            state.head = 0
            state.bytes = 0
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                let step: Step = state.withLock { state in
                    if state.head < state.frames.count {
                        let frame = state.frames[state.head]
                        state.frames[state.head] = Data()
                        state.head += 1
                        state.bytes -= frame.count
                        if state.head == state.frames.count {
                            state.frames.removeAll(keepingCapacity: true)
                            state.head = 0
                        }
                        return .deliver(frame)
                    }
                    if state.abandoned { return .end(nil) }
                    if state.ended { return .end(state.failure) }
                    // One consumer at a time; a second concurrent caller is told the stream is over.
                    if state.waiter != nil { return .end(nil) }
                    state.waiter = continuation
                    return .wait
                }
                switch step {
                case .deliver(let frame): continuation.resume(returning: frame)
                case .end(let error): continuation.resume(with: Self.ending(error))
                case .wait: break
                }
            }
        } onCancel: {
            abandon()
        }
    }
}

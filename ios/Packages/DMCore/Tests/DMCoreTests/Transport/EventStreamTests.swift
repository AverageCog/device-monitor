import Foundation
import Testing
@testable import DMCore

@Suite struct EventStreamTests {
    typealias F = TransportFixtures
    typealias Events = AsyncThrowingStream<PinnedSession.StreamEvent, any Error>

    static func head(_ status: Int) -> PinnedSession.StreamEvent {
        .response(HTTPURLResponse(url: URL(string: F.origin + EventStream.path)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    /// A response that arrives as `chunks` and then ends, cleanly or with `failure`.
    static func script(_ status: Int, _ chunks: [String], failure: HubError? = nil) -> Events {
        Events { continuation in
            continuation.yield(head(status))
            for chunk in chunks { continuation.yield(.data(Data(chunk.utf8))) }
            continuation.finish(throwing: failure)
        }
    }

    static func collect(_ stream: AsyncThrowingStream<Data, any Error>) async -> (frames: [String], failure: HubError?) {
        var frames: [String] = []
        do {
            for try await frame in stream { frames.append(String(decoding: frame, as: UTF8.self)) }
            return (frames, nil)
        } catch let error as HubError {
            return (frames, error)
        } catch {
            return (frames, .unreachable("unexpected error type"))
        }
    }

    static func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func deliversFramesAcrossChunkBoundaries() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        hub.onStream { _ in
            Self.script(200, [#"data: {"type":"snap"#, #"shot","devices":[]}"#, "\n", "\ndata: {\"type\":\"status\"}\n\n: ping\n\ndata: {\"name\":\"Zo", "ë\"}\n\n"])
        }
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.frames == [#"{"type":"snapshot","devices":[]}"#, #"{"type":"status"}"#, #"{"name":"Zoë"}"#])
        #expect(result.failure == nil)          // the hub ended the response cleanly

        let call = try #require(hub.calls.first)
        #expect(hub.calls.count == 1)
        #expect(call.isStream && call.method == "GET" && call.path == "/api/stream" && call.query == nil)
        #expect(call.authorization == "Bearer " + F.client)
        #expect(call.policy == .require(pin: F.pin("A")))
        #expect(call.timeout == 15)             // the idle limit
        #expect(EventStream.idleTimeout == 15 && EventStream.path == "/api/stream")
        #expect(await Self.eventually { hub.streamCancels == 1 })
    }

    @Test func clientConvenienceOpensTheSameStream() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        hub.onStream { _ in Self.script(200, ["data: one\n\ndata: two\n\n"]) }
        #expect(await Self.collect(client.events()).frames == ["one", "two"])
        #expect(hub.calls.map(\.path) == ["/api/stream"])
    }

    @Test func deliversFramesFoundationCanDecodeWhenTheHubCutAStringInsideAnEmoji() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        // The escape arrives split across chunks, like anything else in a frame.
        hub.onStream { _ in
            Self.script(200, [#"data: {"type":"snapshot","devices":[{"latest":{"hostname":"aaa\ud8"#, #"3d"}}]}"# + "\n\ndata: {\"name\":\"\\ud83d\\ude00\"}\n\n"])
        }
        let result = await Self.collect(EventStream(client: client).frames())
        // Half a pair becomes the escape for U+FFFD; an escaped pair is left as it came.
        #expect(result.frames == ["{\"type\":\"snapshot\",\"devices\":[{\"latest\":{\"hostname\":\"aaa\\ufffd\"}}]}", "{\"name\":\"\\ud83d\\ude00\"}"])
        #expect(result.failure == nil)
        for frame in result.frames {
            #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(frame.utf8)) }
        }
    }

    @Test func reportsRefusalsWithTheHubsWords() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        func refusal(_ status: Int, _ chunks: [String]) async -> HubError? {
            hub.onStream { _ in Self.script(status, chunks) }
            let result = await Self.collect(EventStream(client: client).frames())
            #expect(result.frames.isEmpty)
            return result.failure
        }
        #expect(await refusal(401, [#"{"error":"Open a fresh "#, #"dashboard invitation."}"#]) == .unauthorized(status: 401, message: "Open a fresh dashboard invitation."))
        // For the stream a 403 counts too, as it does for the desktop app (dashboardProtocol() in main.js).
        #expect(await refusal(403, [#"{"error":"Use the configured HTTPS hub address."}"#]) == .unauthorized(status: 403, message: "Use the configured HTTPS hub address."))
        #expect(await refusal(401, []) == .unauthorized(status: 401, message: "HTTP 401"))
        #expect(await refusal(503, [#"{"error":"too many connections"}"#]) == .http(status: 503, message: "too many connections"))
        #expect(await refusal(500, ["data: {\"type\":\"snapshot\"}\n\n"]) == .http(status: 500, message: "HTTP 500"))
        // An error body is bounded like any small response.
        #expect(await refusal(500, Array(repeating: String(repeating: "x", count: 4096), count: 40)) == .http(status: 500, message: "HTTP 500"))
    }

    @Test func deliversWhatArrivedBeforeAFailure() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        let lost = HubError.unreachable("The connection to the hub was lost.")
        hub.onStream { _ in Self.script(200, ["data: one\n\n", "data: two\n\ndata: thr"], failure: lost) }
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.frames == ["one", "two"])
        #expect(result.failure == lost)

        // Fifteen silent seconds end the connection with the transport's timeout.
        let silent = HubError.unreachable(HubError.Reason.timedOut)
        hub.onStream { _ in Self.script(200, ["data: snapshot\n\n"], failure: silent) }
        let stalled = await Self.collect(EventStream(client: client).frames())
        #expect(stalled.frames == ["snapshot"] && stalled.failure == silent)

        hub.onStream { _ in Events { $0.finish(throwing: HubError.untrustedCertificate("x")) } }
        #expect(await Self.collect(EventStream(client: client).frames()).failure == .untrustedCertificate("x"))
    }

    @Test func recoversFromARotatedKeyLikeARequest() async throws {
        let (hub, store, client) = try HubClientTests.setUp(serving: F.pin("B"))
        HubClientTests.honestHub(hub)
        hub.onStream { _ in Self.script(200, ["data: snapshot\n\n"]) }
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.frames == ["snapshot"] && result.failure == nil)
        #expect(hub.refusedHandshakes == [.require(pin: F.pin("A"))])
        #expect(hub.calls.map(\.path) == [F.proofPath, "/api/stream"])
        #expect(hub.calls[0].authorization == nil)
        #expect(hub.calls[1].policy == .require(pin: F.pin("B")))
        #expect(try store.load()?.pin == F.pin("B"))

        // A stream and requests that meet the rotation together still share one proof.
        let (busy, _, shared) = try HubClientTests.setUp(serving: F.pin("B"))
        HubClientTests.honestHub(busy, proofDelay: .milliseconds(100))
        busy.onStream { _ in Self.script(200, ["data: snapshot\n\n"]) }
        async let streamed = Self.collect(EventStream(client: shared).frames())
        async let first = shared.request(path: "/api/devices")
        async let second = shared.request(path: "/api/alerts")
        _ = try await (first, second)
        #expect(await streamed.frames == ["snapshot"])
        #expect(busy.calls(to: F.proofPath).count == 1)
    }

    @Test func anImpostorNeverSeesTheBearer() async throws {
        let (hub, store, client) = try HubClientTests.setUp(serving: F.pin("B"))
        hub.onRequest { _ in .json(403, #"{"error":"Desktop proof refused"}"#) }
        hub.onStream { _ in Self.script(200, ["data: stolen\n\n"]) }
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.frames.isEmpty && result.failure == .identityProofFailed)
        #expect(hub.calls.map(\.path) == [F.proofPath])
        #expect(hub.calls.allSatisfy { $0.authorization == nil })
        #expect(try store.load()?.pin == F.pin("A"))
    }

    @Test func aSecondMismatchIsNotRetried() async throws {
        let (hub, _, client) = try HubClientTests.setUp(serving: F.pin("B"))
        hub.onRequest { call in
            defer { hub.servedPin = F.pin("C") }
            return F.proofReply(to: call, signing: F.pin("B"))
        }
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.failure == .pinMismatch(peerPin: F.pin("C")))
        #expect(hub.calls.map(\.path) == [F.proofPath])
    }

    @Test func cancellingTheConsumerCancelsTheRequest() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        hub.onStream { _ in
            Events { continuation in
                continuation.yield(Self.head(200))
                continuation.yield(.data(Data("data: snapshot\n\n".utf8)))      // then the hub goes on forever
            }
        }
        let received = Counter()
        let consumer = Task {
            var frames = 0
            for try await _ in EventStream(client: client).frames() {
                frames += 1
                received.increment()
            }
            return frames
        }
        #expect(await Self.eventually { received.count == 1 })
        #expect(hub.streamCancels == 0)
        consumer.cancel()
        #expect(try await consumer.value == 1)
        #expect(await Self.eventually { hub.streamCancels == 1 })
    }

    @Test func leavingTheLoopCancelsTheRequest() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        hub.onStream { _ in
            Events { continuation in
                continuation.yield(Self.head(200))
                continuation.yield(.data(Data("data: one\n\ndata: two\n\n".utf8)))
            }
        }
        func firstFrame() async throws -> String? {
            for try await frame in EventStream(client: client).frames() { return String(decoding: frame, as: UTF8.self) }
            return nil
        }
        #expect(try await firstFrame() == "one")
        // Nothing was cancelled explicitly: dropping the stream is what ends the connection.
        #expect(await Self.eventually { hub.streamCancels == 1 })

        // A stream that is never iterated is cleaned up the same way, whether or not it got as
        // far as opening a connection.
        _ = EventStream(client: client).frames()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await Self.eventually { hub.streamCancels == hub.calls.count })
    }

    @Test func aClosedClientOpensNothing() async throws {
        let (hub, _, client) = try HubClientTests.setUp()
        await client.close()
        let result = await Self.collect(EventStream(client: client).frames())
        #expect(result.frames.isEmpty && result.failure == .cancelled)
        #expect(hub.calls.isEmpty)
    }

    // MARK: FrameQueue

    @Test func queueDeliversInOrderThenEnds() async throws {
        let queue = FrameQueue(limit: 1024)
        #expect(queue.push(Data("a".utf8)) && queue.push(Data("b".utf8)))
        queue.finish(nil)
        #expect(!queue.push(Data("late".utf8)))
        #expect(try await queue.next() == Data("a".utf8))
        #expect(try await queue.next() == Data("b".utf8))
        #expect(try await queue.next() == nil)
        #expect(try await queue.next() == nil)
    }

    @Test func queueDeliversBufferedFramesBeforeTheError() async throws {
        let queue = FrameQueue(limit: 1024)
        #expect(queue.push(Data("a".utf8)))
        queue.finish(HubError.redirectRefused)
        queue.finish(nil)                                   // the first ending wins
        #expect(try await queue.next() == Data("a".utf8))
        await #expect(throws: HubError.redirectRefused) { try await queue.next() }
    }

    @Test func queueWakesAWaitingConsumer() async throws {
        let queue = FrameQueue(limit: 1024)
        let consumer = Task { try await [queue.next(), queue.next(), queue.next()] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(queue.push(Data("a".utf8)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(queue.push(Data("b".utf8)))
        queue.finish(nil)
        #expect(try await consumer.value == [Data("a".utf8), Data("b".utf8), nil])
    }

    @Test func queueStopsAProducerThatOutrunsTheConsumer() async throws {
        let queue = FrameQueue(limit: 100)
        #expect(queue.push(Data(count: 60)))
        #expect(queue.push(Data(count: 40)))
        #expect(!queue.push(Data(count: 1)))
        #expect(try await queue.next()?.count == 60)
        #expect(try await queue.next()?.count == 40)
        await #expect(throws: HubError.unreachable("The app fell too far behind the hub's live stream.")) { try await queue.next() }

        // Taking frames frees room.
        let steady = FrameQueue(limit: 100)
        for _ in 0..<50 {
            #expect(steady.push(Data(count: 90)))
            #expect(try await steady.next()?.count == 90)
        }
    }

    @Test func queueReleasesACancelledConsumer() async throws {
        let queue = FrameQueue(limit: 1024)
        let consumer = Task { try await queue.next() }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        #expect(try await consumer.value == nil)
        #expect(!queue.push(Data("ignored".utf8)))
        #expect(try await queue.next() == nil)

        let abandoned = FrameQueue(limit: 1024)
        #expect(abandoned.push(Data("x".utf8)))
        abandoned.abandon()
        #expect(try await abandoned.next() == nil)
    }
}

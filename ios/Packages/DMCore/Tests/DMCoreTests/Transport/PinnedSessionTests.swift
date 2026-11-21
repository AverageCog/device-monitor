import Foundation
import Testing
@testable import DMCore

/// What a `PinnedSession` decides before it uses the network. Its behaviour on the wire is covered
/// by `TransportE2ETests`.
@Suite struct PinnedSessionTests {
    typealias F = TransportFixtures

    static let url = URL(string: "https://hub.example:8443/api/info")!

    static func request(method: String = "GET", headers: [String: String] = [:], body: Data? = nil, url: URL = url) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    /// The client tells "this session was replaced and sent nothing" from "this was cancelled":
    /// only after the first may a request be sent again.
    @Test func aRetiredSessionSaysItSentNothing() async throws {
        let session = PinnedSession(policy: .require(pin: F.pin("A")))
        #expect(!session.isDrained)                                     // open: it may still be given work
        session.retire()
        #expect(session.isDrained)
        await #expect(throws: PinnedSession.Retired.self) {
            _ = try await session.data(for: Self.request(), timeout: 2, maxResponseBytes: 1024)
        }
        await #expect(throws: PinnedSession.Retired.self) {
            for try await _ in session.bytes(for: Self.request(), idleTimeout: 2).events {}
        }

        // Invalidating it afterwards, as closing the client does, is final.
        session.invalidate()
        #expect(session.isDrained)
        #expect(await hubError { _ = try await session.data(for: Self.request(), timeout: 2, maxResponseBytes: 1024) } == .cancelled)
        #expect(await hubError { for try await _ in session.bytes(for: Self.request(), idleTimeout: 2).events {} } == .cancelled)
        session.retire()
        #expect(await hubError { _ = try await session.data(for: Self.request(), timeout: 2, maxResponseBytes: 1024) } == .cancelled)
    }
}

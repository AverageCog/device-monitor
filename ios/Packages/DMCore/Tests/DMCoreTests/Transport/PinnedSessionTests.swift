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

    /// A capture session has checked the server's key against nothing, so nothing that could be
    /// a credential may travel on it. Refused requests never reach the network, which is why
    /// this needs no server.
    @Test func aCaptureSessionCarriesNothingButABareGET() async throws {
        let capture = PinnedSession(policy: .capture)
        defer { capture.invalidate() }
        let enrolled = PinnedSession.Policy.require(pin: F.pin("A"))
        let refused: [(String, URLRequest)] = [
            ("the bearer", Self.request(headers: ["Authorization": "Bearer " + F.client])),
            ("an invitation code", Self.request(method: "POST", headers: ["Authorization": "Bearer " + F.code], body: Data("{}".utf8))),
            ("a header of any spelling", Self.request(headers: ["authorization": "Basic dTpw"])),
            ("a cookie", Self.request(headers: ["Cookie": "dm=" + F.client])),
            ("a header the hub does not know", Self.request(headers: ["X-Api-Key": F.client])),
            ("a body", Self.request(body: Data(#"{"client":"x"}"#.utf8))),
            ("a POST", Self.request(method: "POST")),
            ("a password in the address", Self.request(url: URL(string: "https://user:secret@hub.example:8443/api/info")!)),
            ("what the client sends once enrolled", try HubClient.makeRequest(origin: HubOrigin(F.origin), method: "GET", path: "/api/devices", query: [], bearer: F.client, body: nil)),
            ("what pairing sends to redeem", try HubClient.makeRequest(origin: HubOrigin(F.origin), method: "POST", path: HubPairing.redeemPath, query: [], bearer: F.code, body: Data("{}".utf8))),
        ]
        for (what, request) in refused {
            #expect(await hubError { _ = try await capture.data(for: request, timeout: 2, maxResponseBytes: 1024) } == .invalidRequest, "\(what)")
            let stream = capture.bytes(for: request, idleTimeout: 2)
            #expect(await hubError { for try await _ in stream.events {} } == .invalidRequest, "\(what)")
            // The same request is in order once the key it goes to must be the enrolled one.
            #expect(PinnedSession.prepared(request, idleTimeout: 2, policy: .capture) == nil, "\(what)")
            #expect(PinnedSession.prepared(request, idleTimeout: 2, policy: enrolled) != nil, "\(what)")
        }

        // The pairing probe is exactly such a bare GET.
        let probe = try HubClient.makeRequest(origin: HubOrigin(F.origin), method: "GET", path: "/api/info", query: [], bearer: nil, body: nil)
        let sent = try #require(PinnedSession.prepared(probe, idleTimeout: 8, policy: .capture))
        #expect(sent.url == Self.url && sent.httpMethod == "GET" && sent.timeoutInterval == 8)
        #expect(sent.allHTTPHeaderFields?.isEmpty ?? true)
        #expect(!sent.httpShouldHandleCookies && sent.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        // HTTPS only, whatever the policy.
        let plain = Self.request(url: URL(string: "http://hub.example:8443/api/info")!)
        #expect(PinnedSession.prepared(plain, idleTimeout: 2, policy: .capture) == nil)
        #expect(PinnedSession.prepared(plain, idleTimeout: 2, policy: enrolled) == nil)
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

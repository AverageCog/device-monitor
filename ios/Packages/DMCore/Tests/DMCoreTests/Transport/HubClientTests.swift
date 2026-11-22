import Foundation
import Testing
@testable import DMCore

@Suite struct HubClientTests {
    typealias F = TransportFixtures

    /// A client paired under pin A against a fake hub that currently serves `serving`.
    static func setUp(serving: String = F.pin("A")) throws -> (hub: FakeHub, store: InMemoryCredentialStore, client: HubClient) {
        let enrollment = try F.enrollment()
        let hub = FakeHub(servedPin: serving)
        let store = InMemoryCredentialStore(enrollment)
        return (hub, store, HubClient(enrollment: enrollment, store: store, connect: hub.connect))
    }

    /// Answers the proof like the real hub and everything else with `{"ok":true}`.
    static func honestHub(_ hub: FakeHub, proofDelay: Duration = .zero) {
        hub.onRequest { call in
            if call.path == F.proofPath {
                try await Task.sleep(for: proofDelay)
                return F.proofReply(to: call, signing: hub.servedPin)
            }
            return .json(200, #"{"ok":true}"#)
        }
    }

    // MARK: Requests

    @Test func sendsTheBearerOnAPinnedConnectionToTheEnrolledOrigin() async throws {
        let (hub, _, client) = try Self.setUp()
        hub.onRequest { _ in .json(200, #"[{"id":"ws"}]"#) }
        let (data, response) = try await client.request(path: "/api/devices")
        #expect(String(decoding: data, as: UTF8.self) == #"[{"id":"ws"}]"#)
        #expect(response.statusCode == 200)
        #expect(response.url?.absoluteString == "https://hub.example:8443/api/devices")

        let call = try #require(hub.calls.first)
        #expect(hub.calls.count == 1)
        #expect(call.policy == .require(pin: F.pin("A")))
        #expect(call.method == "GET" && call.path == "/api/devices" && call.query == nil)
        #expect(call.authorization == "Bearer " + F.client)
        #expect(call.contentType == nil && call.body == nil)
        #expect(call.timeout == 15)
        #expect(call.limit == 32 * 1024 * 1024)
        #expect(client.origin.string == F.origin)
        #expect(client.enrollmentID == F.id)
    }

    @Test func sendsJSONBodiesWithAContentType() async throws {
        let (hub, _, client) = try Self.setUp()
        _ = try await client.request(method: "PUT", path: "/api/order", body: Data(#"{"ids":["a","b"]}"#.utf8))
        _ = try await client.request(method: "DELETE", path: "/api/devices/ws")
        _ = try await client.request(method: "POST", path: "/api/alerts/test", timeout: 30)
        let calls = hub.calls
        #expect(calls.map(\.method) == ["PUT", "DELETE", "POST"])
        #expect(calls[0].contentType == "application/json")
        #expect(calls[0].body == Data(#"{"ids":["a","b"]}"#.utf8))
        #expect(calls[1].contentType == nil && calls[1].body == nil)
        #expect(calls[2].timeout == 30)
        #expect(calls.allSatisfy { $0.authorization == "Bearer " + F.client })
    }

    @Test func encodesTheQuery() async throws {
        let (hub, _, client) = try Self.setUp()
        _ = try await client.request(path: "/api/energy", query: [URLQueryItem(name: "bounds", value: "1700000000000,1700086400000")])
        _ = try await client.request(path: "/api/history/ws", query: [URLQueryItem(name: "range", value: "1h"), URLQueryItem(name: "points", value: "600")])
        _ = try await client.request(path: "/api/remote", query: [URLQueryItem(name: "fresh", value: nil)])
        _ = try await client.request(path: "/x", query: [URLQueryItem(name: "a b", value: "1+1=2&c #é/?")])
        #expect(hub.calls.map(\.query) == [
            "bounds=1700000000000,1700086400000", "range=1h&points=600", "fresh", "a%20b=1%2B1%3D2%26c%20%23%C3%A9%2F%3F",
        ])
        #expect(HubClient.pathComponent("aa:bb/cc dd?é") == "aa%3Abb%2Fcc%20dd%3F%C3%A9")
        #expect(HubClient.pathComponent("previously-paired_desktop.1~!*'()") == "previously-paired_desktop.1~!*'()")
    }

    @Test func refusesAnythingThatIsNotASingleSlashPath() async throws {
        let (hub, _, client) = try Self.setUp()
        let bad = [
            "", "api/devices", "//evil.example/api", "//", "/\\evil.example", "\\\\evil.example", "https://evil.example/api", "/api/devices?x=1",
            "/api/devices#x", "/a b", "/a\nb", "/a\u{0}", "/é", "/a\\b", "/<script>", "/a\"b", "/" + String(repeating: "a", count: 2048),
        ]
        for path in bad {
            #expect(await hubError { _ = try await client.request(path: path) } == .invalidRequest, "\(path.debugDescription)")
        }
        #expect(await hubError { _ = try await client.request(method: "TRACE", path: "/api/devices") } == .invalidRequest)
        #expect(await hubError { _ = try await client.request(method: "get", path: "/api/devices") } == .invalidRequest)
        #expect(await hubError { _ = try await client.request(method: "POST", path: "/api/order", body: Data(count: 1_000_001)) } == .invalidRequest)
        #expect(hub.calls.isEmpty)

        for path in ["/", "/api/devices/aa:bb.cc_dd-ee", "/api/devices/a%20b/action", "/a//b", "/a;b=c,d@e", "/~a/(b)*!'+$&"] {
            _ = try await client.request(path: path)
        }
        #expect(hub.calls.count == 6)
        #expect(hub.calls.map(\.path).first == "/")
    }

    @Test func capsResponsesLikeTheDesktopApp() async throws {
        let (hub, _, client) = try Self.setUp()
        for path in ["/api/info", "/api/update/windows", "/api/update/mac", "/api/devices", "/api/updates", "/api/energy"] {
            _ = try await client.request(path: path)
        }
        _ = try await client.request(path: "/api/devices", maxResponseBytes: 1234)
        #expect(hub.calls.map(\.limit) == [65536, 65536, 65536, 33_554_432, 33_554_432, 33_554_432, 1234])

        hub.onRequest { _ in FakeHub.Reply(status: 200, body: Data(count: 65537)) }
        #expect(await hubError { _ = try await client.request(path: "/api/info") } == .responseTooLarge)
        #expect(try await client.request(path: "/api/devices").0.count == 65537)
    }

    @Test func mapsHTTPFailures() async throws {
        let (hub, _, client) = try Self.setUp()
        func failure(_ status: Int, _ body: String, path: String = "/api/devices") async -> HubError? {
            hub.onRequest { _ in .json(status, body) }
            return await hubError { _ = try await client.request(path: path) }
        }
        #expect(await failure(404, #"{"error":"not found"}"#) == .http(status: 404, message: "not found"))
        #expect(await failure(400, #"{"error":"bad bounds"}"#) == .http(status: 400, message: "bad bounds"))
        #expect(await failure(409, #"{"error":"Workstation is offline."}"#) == .http(status: 409, message: "Workstation is offline."))
        #expect(await failure(500, "") == .http(status: 500, message: "HTTP 500"))
        #expect(await failure(502, "<html>Bad gateway</html>") == .http(status: 502, message: "HTTP 502"))
        #expect(await failure(421, "This hub only answers requests addressed to it by IP address or its own name.") == .http(status: 421, message: "HTTP 421"))
        #expect(await failure(500, #"{"error":42}"#) == .http(status: 500, message: "HTTP 500"))
        #expect(await failure(500, #"["error"]"#) == .http(status: 500, message: "HTTP 500"))
        #expect(await failure(500, #"{"error":""}"#) == .http(status: 500, message: "HTTP 500"))
        #expect(await failure(199, "{}") == .http(status: 199, message: "HTTP 199"))

        // The repair screen's signal: the hub does not know this credential any more.
        let revoked = await failure(401, #"{"error":"Open a fresh dashboard invitation."}"#)
        #expect(revoked == .unauthorized(status: 401, message: "Open a fresh dashboard invitation."))
        #expect(revoked?.isUnauthorized == true && revoked?.httpStatus == 401)
        #expect(await failure(401, "") == .unauthorized(status: 401, message: "HTTP 401"))
        // A 403 to an API call is the hub refusing that operation to a credential it accepts,
        // which must not send a healthy enrollment to the repair screen.
        let forbidden = await failure(403, #"{"error":"Create this invitation on the hub."}"#)
        #expect(forbidden == .http(status: 403, message: "Create this invitation on the hub."))
        #expect(forbidden?.isUnauthorized == false && forbidden?.httpStatus == 403)
        #expect(await failure(404, "{}")?.isUnauthorized == false)

        // The hub's text is cut to 240 UTF-16 units and stripped of control characters.
        let long = await failure(500, #"{"error":""# + String(repeating: "x", count: 500) + #""}"#)
        #expect(long == .http(status: 500, message: String(repeating: "x", count: 240)))
        let emoji = await failure(500, #"{"error":""# + String(repeating: "😀", count: 200) + #""}"#)
        #expect(emoji?.errorDescription?.utf16.count == 240)
        #expect(await failure(500, #"{"error":"line\nbreak\u0000"}"#) == .http(status: 500, message: "linebreak"))

        #expect(hub.calls.count == 17)
    }

    @Test func decodesJSON() async throws {
        struct Device: Decodable, Sendable, Equatable { let id: String; let online: Bool }
        struct Rename: Encodable, Sendable { let name: String }
        let (hub, _, client) = try Self.setUp()
        hub.onRequest { call in
            call.method == "PATCH" ? .json(200, #"{"id":"ws","online":true}"#) : .json(200, #"[{"id":"ws","online":true},{"id":"nas","online":false}]"#)
        }
        let devices: [Device] = try await client.json(path: "/api/devices")
        #expect(devices == [Device(id: "ws", online: true), Device(id: "nas", online: false)])
        let renamed = try await client.json(Device.self, method: "PATCH", path: "/api/devices/ws", encoding: Rename(name: "Desk \"1\""))
        #expect(renamed == Device(id: "ws", online: true))
        let sent = try #require(hub.calls.last)
        #expect(sent.contentType == "application/json")
        #expect(sent.json == ["name": "Desk \"1\""])

        hub.onRequest { _ in .json(200, "not json") }
        #expect(await hubError { _ = try await client.json([Device].self, path: "/api/devices") } == .invalidResponse)
        hub.onRequest { _ in .json(200, #"{"id":7}"#) }
        #expect(await hubError { _ = try await client.json(Device.self, path: "/api/devices/ws") } == .invalidResponse)
    }

    /// The hub cuts strings by UTF-16 length (`str()` in `security.js`), which can leave half an
    /// emoji at the end of a hostname or label; `JSON.stringify` writes that half as an escape
    /// Foundation refuses. Browsers show it as U+FFFD, and so does this client.
    @Test func decodesAStringTheHubCutInsideAnEmoji() async throws {
        struct Device: Decodable, Sendable, Equatable { let id: String; let hostname: String }
        let (hub, _, client) = try Self.setUp()
        let kept = String(repeating: "a", count: 63)                        // 63 letters + 😀, cut to 64 units
        hub.onRequest { call in
            call.path == "/api/gone"
                ? .json(404, #"{"error":"no device named aaa\ud83d"}"#)
                : .json(200, #"[{"id":"ws","hostname":""# + kept + #"\ud83d"},{"id":"nas","hostname":""# + "\\ud83d\\ude00" + #" intact"}]"#)
        }
        let devices: [Device] = try await client.json(path: "/api/devices")
        #expect(devices == [Device(id: "ws", hostname: kept + "\u{FFFD}"), Device(id: "nas", hostname: "😀 intact")])

        // Callers that decode `request`'s body themselves get the same text.
        let (data, _) = try await client.request(path: "/api/devices")
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(parsed.map { $0["hostname"] } == [kept + "\u{FFFD}", "😀 intact"])
        #expect(await hubError { _ = try await client.request(path: "/api/gone") } == .http(status: 404, message: "no device named aaa\u{FFFD}"))
    }

    @Test func neverReplaysAfterAnAmbiguousFailure() async throws {
        let (hub, store, client) = try Self.setUp()
        for failure in [HubError.unreachable("The connection to the hub was lost."), .responseTooLarge, .redirectRefused, .untrustedCertificate("x"), .cancelled] {
            let before = hub.calls.count
            hub.onRequest { _ in throw failure }
            #expect(await hubError { _ = try await client.request(method: "POST", path: "/api/devices/ws/action", body: Data(#"{"action":"wake"}"#.utf8)) } == failure)
            #expect(hub.calls.count == before + 1)
        }
        #expect(hub.calls(to: F.proofPath).isEmpty)
        #expect(hub.policies == [.require(pin: F.pin("A"))])
        #expect(try store.load()?.pin == F.pin("A"))
    }

    // MARK: TLS key rotation

    @Test func verifiesARotatedKeyThenRetriesOnce() async throws {
        let (hub, store, client) = try Self.setUp()
        Self.honestHub(hub)
        _ = try await client.request(path: "/api/devices")
        hub.servedPin = F.pin("B")

        let (data, _) = try await client.request(method: "PUT", path: "/api/order", body: Data(#"{"ids":[]}"#.utf8))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)

        // The handshake under the old pin was refused, so the PUT reached the hub exactly once.
        #expect(hub.refusedHandshakes == [.require(pin: F.pin("A"))])
        #expect(hub.calls.map(\.path) == ["/api/devices", F.proofPath, "/api/order"])
        let proof = hub.calls[1], retried = hub.calls[2]
        #expect(proof.method == "POST")
        #expect(proof.policy == .require(pin: F.pin("B")))          // only on a connection that presents the candidate key
        #expect(proof.authorization == nil)                           // and never with the bearer
        #expect(proof.contentType == "application/json")
        #expect(proof.timeout == 8 && proof.limit == 65536)
        #expect(Set(proof.json.keys) == ["lookup", "nonce", "challenge"])
        #expect(proof.json.values.allSatisfy(HubIdentity.isValidSecret))
        let sent = String(decoding: proof.body ?? Data(), as: UTF8.self)
        for secret in [F.client, F.proof, HubIdentity.credentialDigest(F.client), HubIdentity.credentialDigest(F.proof), F.id] {
            #expect(!sent.contains(secret))
        }
        #expect(retried.policy == .require(pin: F.pin("B")) && retried.authorization == "Bearer " + F.client)
        #expect(retried.body == Data(#"{"ids":[]}"#.utf8))

        // The new pin is persisted and used from now on, with no further proof.
        #expect(try store.load()?.pin == F.pin("B"))
        #expect(await client.enrollment.pin == F.pin("B"))
        #expect(try store.load() == F.enrollment(pin: F.pin("B")))
        _ = try await client.request(path: "/api/devices")
        #expect(hub.calls(to: F.proofPath).count == 1)
        #expect(hub.retired == [.require(pin: F.pin("A"))])
        #expect(hub.invalidated.isEmpty)

        // A client restarted from the store goes straight to the new pin.
        let restarted = HubClient(enrollment: try #require(try store.load()), store: store, connect: hub.connect)
        _ = try await restarted.request(path: "/api/devices")
        #expect(hub.calls(to: F.proofPath).count == 1)
    }

    @Test func eachProofUsesAFreshNonce() async throws {
        let (hub, _, client) = try Self.setUp()
        Self.honestHub(hub)
        hub.servedPin = F.pin("B")
        _ = try await client.request(path: "/api/devices")
        hub.servedPin = F.pin("C")
        _ = try await client.request(path: "/api/devices")
        let proofs = hub.calls(to: F.proofPath)
        #expect(proofs.count == 2)
        #expect(proofs[0].json["nonce"] != proofs[1].json["nonce"])
        #expect(proofs[0].json["challenge"] != proofs[1].json["challenge"])
        #expect(proofs[0].json["lookup"] == proofs[1].json["lookup"])
        #expect(await client.enrollment.pin == F.pin("C"))
    }

    @Test func concurrentRequestsShareOneProof() async throws {
        let (hub, store, client) = try Self.setUp()
        Self.honestHub(hub, proofDelay: .milliseconds(150))
        hub.servedPin = F.pin("B")
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask { (try? await client.request(method: "POST", path: "/api/n/\(index)", body: Data("{}".utf8))) != nil }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results == Array(repeating: true, count: 12))
        #expect(hub.calls(to: F.proofPath).count == 1)
        // Every operation reached the hub exactly once, on the new pin.
        let operations = hub.calls.filter { $0.path != F.proofPath }
        #expect(Set(operations.map(\.path)).count == 12 && operations.count == 12)
        #expect(operations.allSatisfy { $0.policy == .require(pin: F.pin("B")) })
        #expect(try store.load()?.pin == F.pin("B"))

        // A request that saw the stale pin after the proof finished does not start another.
        try await client.refresh(previous: F.pin("A"), candidate: F.pin("B"))
        #expect(hub.calls(to: F.proofPath).count == 1)
    }

    @Test func aFailedProofChangesNothingAndSendsNoBearer() async throws {
        typealias Scenario = (name: String, reply: @Sendable (FakeHub.Call) -> FakeHub.Reply)
        let scenarios: [Scenario] = [
            ("an unrelated hub refuses", { _ in .json(403, #"{"error":"Desktop proof refused"}"#) }),
            ("a relay obtains a proof for the real hub's key", { F.proofReply(to: $0, signing: F.pin("A")) }),
            ("a proof under different secrets", { F.proofReply(to: $0, signing: F.pin("B"), proof: String(F.proof.reversed())) }),
            ("no proof", { _ in .json(200, "{}") }),
            ("a proof of the wrong type", { _ in .json(200, #"{"proof":7}"#) }),
            ("not JSON", { _ in .json(200, "<html>") }),
            ("the hub cannot tell which key is served", { _ in .json(503, #"{"error":"Hub TLS identity is temporarily unavailable"}"#) }),
            ("rate limited", { _ in .json(429, #"{"error":"too many requests"}"#) }),
        ]
        for scenario in scenarios {
            let (hub, store, client) = try Self.setUp(serving: F.pin("B"))
            hub.onRequest { call in call.path == F.proofPath ? scenario.reply(call) : .json(200, "{}") }
            let failure = await hubError { _ = try await client.request(method: "POST", path: "/api/devices/ws/action", body: Data(#"{"action":"wake"}"#.utf8)) }
            #expect(failure == .identityProofFailed, "\(scenario.name)")
            #expect(hub.calls.map(\.path) == [F.proofPath], "\(scenario.name)")
            #expect(hub.calls.allSatisfy { $0.authorization == nil }, "\(scenario.name)")
            #expect(try store.load()?.pin == F.pin("A"), "\(scenario.name)")
            #expect(await client.enrollment.pin == F.pin("A"), "\(scenario.name)")
            // The candidate's connection is dropped; the enrolled one stays.
            #expect(hub.invalidated == [.require(pin: F.pin("B"))], "\(scenario.name)")
            #expect(hub.retired.isEmpty, "\(scenario.name)")
        }
    }

    @Test func aReplayedProofIsRefused() async throws {
        // Record a genuine proof for key B, then answer a later challenge with it.
        let (hub, _, client) = try Self.setUp(serving: F.pin("B"))
        Self.honestHub(hub)
        _ = try await client.request(path: "/api/devices")
        let recorded = F.proofReply(to: try #require(hub.calls(to: F.proofPath).first), signing: F.pin("B"))

        let (impostor, store, victim) = try Self.setUp(serving: F.pin("B"))
        impostor.onRequest { _ in recorded }
        #expect(await hubError { _ = try await victim.request(path: "/api/devices") } == .identityProofFailed)
        #expect(try store.load()?.pin == F.pin("A"))
        #expect(impostor.calls.allSatisfy { $0.authorization == nil })
    }

    @Test func transportFailuresDuringTheProofSurfaceAsThemselves() async throws {
        let (hub, store, client) = try Self.setUp(serving: F.pin("B"))
        hub.onRequest { _ in throw HubError.unreachable("Could not connect to the hub.") }
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .unreachable("Could not connect to the hub."))
        hub.onRequest { _ in throw HubError.untrustedCertificate("x") }
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .untrustedCertificate("x"))
        #expect(try store.load()?.pin == F.pin("A"))
        #expect(hub.calls.allSatisfy { $0.path == F.proofPath && $0.authorization == nil })
        // Nothing is cached about the failure: the next request tries again.
        Self.honestHub(hub)
        _ = try await client.request(path: "/api/devices")
        #expect(try store.load()?.pin == F.pin("B"))
    }

    @Test func aKeyThatChangesAgainDuringTheProofFailsClosed() async throws {
        let (hub, store, client) = try Self.setUp(serving: F.pin("B"))
        hub.onRequest { call in
            if call.path == F.proofPath {
                defer { hub.servedPin = F.pin("C") }            // rotates again right after proving B
                return F.proofReply(to: call, signing: F.pin("B"))
            }
            return .json(200, "{}")
        }
        // B was proven and saved, but the retry met C: one retry only, so the mismatch surfaces.
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .pinMismatch(peerPin: F.pin("C")))
        #expect(hub.calls.map(\.path) == [F.proofPath])
        #expect(try store.load()?.pin == F.pin("B"))
        #expect(HubError.pinMismatch(peerPin: F.pin("C")).isConnectivityFailure)

        // A candidate that is already stale when the proof connects is a failed proof.
        let (second, secondStore, other) = try Self.setUp(serving: F.pin("B"))
        #expect(await hubError { try await other.refresh(previous: F.pin("A"), candidate: F.pin("D")) } == .identityProofFailed)
        #expect(second.refusedHandshakes == [.require(pin: F.pin("D"))])
        #expect(await hubError { try await other.refresh(previous: F.pin("A"), candidate: "not a pin") } == .identityProofFailed)
        // A caller whose stale pin is not the current one has nothing to recover.
        try await other.refresh(previous: F.pin("Q"), candidate: F.pin("B"))
        #expect(second.calls.isEmpty)
        #expect(second.policies == [.require(pin: F.pin("A")), .require(pin: F.pin("D"))])
        #expect(try secondStore.load()?.pin == F.pin("A"))
    }

    @Test func keepsTheOldPinWhenSavingFails() async throws {
        let enrollment = try F.enrollment()
        let hub = FakeHub(servedPin: F.pin("B"))
        Self.honestHub(hub)
        let store = FailingStore(enrollment, failingSaves: 1)
        let client = HubClient(enrollment: enrollment, store: store, connect: hub.connect)

        let failure = await hubError { _ = try await client.request(method: "POST", path: "/api/alerts/test") }
        #expect(failure == .storage("The Keychain is unavailable (error -25308)."))
        #expect(failure?.errorDescription == "The hub's new identity could not be saved. The Keychain is unavailable (error -25308).")
        #expect(await client.enrollment.pin == F.pin("A"))
        #expect(try store.load()?.pin == F.pin("A"))
        #expect(hub.calls.map(\.path) == [F.proofPath])                 // the request itself was never sent
        #expect(hub.calls.allSatisfy { $0.authorization == nil })

        // Once the store works again the same rotation completes.
        _ = try await client.request(method: "POST", path: "/api/alerts/test")
        #expect(try store.load()?.pin == F.pin("B"))
        #expect(store.saves.count == 2)
        #expect(hub.calls.map(\.path) == [F.proofPath, F.proofPath, "/api/alerts/test"])
    }

    @Test func neverWritesThePinOverADifferentEnrollment() async throws {
        let enrollment = try F.enrollment()
        let other = try Enrollment(
            origin: HubOrigin("https://other.example"), id: "another-enrollment", client: String(F.client.reversed()),
            proof: String(F.proof.reversed()), pin: F.pin("Z"), name: "", pairedAt: Date())
        for stored in [other, nil] {
            let hub = FakeHub(servedPin: F.pin("B"))
            Self.honestHub(hub)
            let store = FailingStore(stored, failingSaves: 0)
            let client = HubClient(enrollment: enrollment, store: store, connect: hub.connect)
            let failure = await hubError { _ = try await client.request(path: "/api/devices") }
            #expect(failure == .storage("This enrollment is no longer the saved one."))
            #expect(store.saves.count == 0)
            #expect(try store.load() == stored)
            #expect(await client.enrollment.pin == F.pin("A"))
        }
    }

    // MARK: Lifetime

    @Test func closingCancelsWorkInFlight() async throws {
        let (hub, _, client) = try Self.setUp()
        let started = Counter()
        hub.onRequest { _ in
            started.increment()
            try await Task.sleep(for: .seconds(30))
            return .json(200, "{}")
        }
        async let first = hubError { _ = try await client.request(path: "/api/slow/1") }
        async let second = hubError { _ = try await client.request(path: "/api/slow/2") }
        while started.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock()
        let begun = clock.now
        await client.close()
        #expect(await first == .cancelled)
        #expect(await second == .cancelled)
        #expect(clock.now - begun < .seconds(5))
        #expect(hub.invalidated == [.require(pin: F.pin("A"))])

        // Closed for good, and closing twice is harmless.
        await client.close()
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .cancelled)
        #expect(await hubError { try await client.refresh(previous: F.pin("A"), candidate: F.pin("B")) } == .cancelled)
        #expect(hub.calls.count == 2)
        #expect(hub.invalidated.count == 1)
    }

    /// A front that renews its key in place keeps the connections it already has, so a request
    /// and the live stream can outlive the rotation on the transport the client has moved on from.
    @Test func closingReachesWorkLeftOnATransportRetiredByARotation() async throws {
        let (hub, store, client) = try Self.setUp()
        let started = Counter()
        hub.onRequest { call in
            if call.path == F.proofPath { return F.proofReply(to: call, signing: hub.servedPin) }
            if call.path == "/api/slow" {
                started.increment()
                try await Task.sleep(for: .seconds(8))
            }
            return .json(200, "{}")
        }
        hub.onStream { _ in
            EventStreamTests.Events { continuation in
                continuation.yield(EventStreamTests.head(200))
                continuation.yield(.data(Data("data: snapshot\n\n".utf8)))      // then the hub goes on forever
            }
        }
        async let slow = hubError { _ = try await client.request(path: "/api/slow") }
        let frames = Counter(), ended = Counter()
        let live = Task { () -> HubError? in
            defer { ended.increment() }
            return await hubError { for try await _ in client.events() { frames.increment() } }
        }
        #expect(await EventStreamTests.eventually { started.count == 1 && frames.count == 1 })

        hub.servedPin = F.pin("B")
        _ = try await client.request(path: "/api/devices")
        #expect(try store.load()?.pin == F.pin("B"))
        #expect(hub.retired == [.require(pin: F.pin("A"))] && hub.invalidated.isEmpty)
        #expect(ended.count == 0)                                           // the rotation disturbed neither

        let clock = ContinuousClock()
        let begun = clock.now
        await client.close()
        #expect(await slow == .cancelled)
        #expect(await EventStreamTests.eventually { ended.count == 1 })
        live.cancel()                                                       // only matters if the stream was left open
        #expect(await live.value == .cancelled)
        #expect(clock.now - begun < .seconds(4))
        #expect(Set(hub.invalidated) == [.require(pin: F.pin("A")), .require(pin: F.pin("B"))])
        #expect(hub.calls(to: "/api/slow").count == 1 && hub.calls(to: "/api/stream").count == 1)
    }

    @Test func keepsARetiredTransportOnlyWhileSomethingIsLeftOnIt() async throws {
        /// One request in flight under key A, then `rotations`; optionally the request is allowed
        /// to finish before the last of them. Returns how the request ended and what `close()`
        /// had to invalidate.
        func invalidatedOnClose(rotations: [Character], finishingBeforeTheLast: Bool) async throws -> (slow: HubError?, invalidated: Set<PinnedSession.Policy>) {
            let (hub, _, client) = try Self.setUp()
            let started = Counter(), release = Counter()
            hub.onRequest { call in
                if call.path == F.proofPath { return F.proofReply(to: call, signing: hub.servedPin) }
                if call.path == "/api/slow" {
                    started.increment()
                    // Answered when the test says so, or after a while if nothing ever cancels it.
                    for _ in 0..<2500 where release.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
                }
                return .json(200, "{}")
            }
            async let slow = hubError { _ = try await client.request(path: "/api/slow") }
            while started.count < 1 { try await Task.sleep(for: .milliseconds(2)) }
            for (index, letter) in rotations.enumerated() {
                if finishingBeforeTheLast, index == rotations.count - 1 {
                    release.increment()
                    #expect(await slow == nil)
                }
                hub.servedPin = F.pin(letter)
                _ = try await client.request(path: "/api/devices")
            }
            await client.close()
            let outcome = await slow
            let replaced: [PinnedSession.Policy] = (["A"] + rotations.dropLast()).map { .require(pin: F.pin($0)) }
            #expect(hub.retired == replaced)
            return (outcome, Set(hub.invalidated))
        }

        // Still busy after two rotations: A is kept, and B, idle when it was replaced, is not.
        let busy = try await invalidatedOnClose(rotations: ["B", "C"], finishingBeforeTheLast: false)
        #expect(busy.slow == .cancelled)
        #expect(busy.invalidated == [.require(pin: F.pin("A")), .require(pin: F.pin("C"))])

        // Once its request has finished, the next rotation lets go of A as well.
        let drained = try await invalidatedOnClose(rotations: ["B", "C"], finishingBeforeTheLast: true)
        #expect(drained.slow == nil)
        #expect(drained.invalidated == [.require(pin: F.pin("C"))])
    }

    /// `send` picks the transport on the actor and the request reaches it on another executor.
    /// A rotation adopted in between retires that transport before it was given the request.
    @Test func aRequestHandedTheOldTransportAsARotationIsAdoptedIsStillSent() async throws {
        let enrollment = try F.enrollment()
        let hub = FakeHub(servedPin: F.pin("B"))
        let held = Counter()
        hub.onRequest { call in
            guard call.path == F.proofPath else { return .json(200, #"{"ok":true}"#) }
            // The proof only completes once the late request is on its way to the old transport.
            while held.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
            return F.proofReply(to: call, signing: hub.servedPin)
        }
        let store = InMemoryCredentialStore(enrollment)
        let inner = hub.connect
        let client = HubClient(enrollment: enrollment, store: store) { policy in
            HeldTransport(inner(policy)) { request in
                guard request.url?.path == "/api/late", policy == .require(pin: F.pin("A")) else { return }
                held.increment()
                while hub.retired.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        async let first = hubError { _ = try await client.request(path: "/api/first") }
        let body = Data(#"{"ids":["a","b"]}"#.utf8)
        let late = await hubError { _ = try await client.request(method: "PUT", path: "/api/late", body: body) }
        #expect(late == nil)
        #expect(await first == nil)
        #expect(held.count == 1)

        // The retired transport sent nothing, so the PUT reached the hub exactly once, on the new key.
        let sent = hub.calls(to: "/api/late")
        #expect(sent.count == 1)
        #expect(sent.first?.policy == .require(pin: F.pin("B")) && sent.first?.body == body && sent.first?.timeout ?? 0 <= 15)
        #expect(hub.calls(to: F.proofPath).count == 1)
        #expect(hub.refusedHandshakes == [.require(pin: F.pin("A"))])
        #expect(try store.load()?.pin == F.pin("B"))
        await client.close()
    }

    @Test func closingCancelsAPendingProof() async throws {
        let (hub, store, client) = try Self.setUp(serving: F.pin("B"))
        let started = Counter()
        hub.onRequest { call in
            started.increment()
            try await Task.sleep(for: .seconds(30))
            return F.proofReply(to: call, signing: F.pin("B"))
        }
        async let pending = hubError { _ = try await client.request(path: "/api/devices") }
        while started.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await client.close()
        #expect(await pending == .cancelled)
        #expect(try store.load()?.pin == F.pin("A"))
        #expect(hub.calls.map(\.path) == [F.proofPath])
    }

    @Test func cancellingTheCallerCancelsTheRequest() async throws {
        let (hub, _, client) = try Self.setUp()
        let started = Counter()
        hub.onRequest { _ in
            started.increment()
            try await Task.sleep(for: .seconds(30))
            return .json(200, "{}")
        }
        let task = Task { await hubError { _ = try await client.request(path: "/api/slow") } }
        while started.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .cancelled)
        // The client itself is still usable.
        hub.onRequest { _ in .json(200, "{}") }
        _ = try await client.request(path: "/api/devices")
    }

    // MARK: Secrets

    @Test func errorsNeverContainSecrets() async throws {
        var errors: [HubError] = [
            .invalidOrigin, .invalidInvitation(.malformed), .invalidInvitation(.desktopInvitation), .invalidInvitation(.browserLink), .invalidRequest,
            .unreachable(HubError.Reason.timedOut), .untrustedCertificate(HubError.Reason.Certificate.untrustedIssuer),
            .pinMismatch(peerPin: F.pin("B")), .identityProofFailed, .redirectRefused, .responseTooLarge, .invalidResponse,
            .http(status: 500, message: "HTTP 500"), .unauthorized(status: 401, message: "Open a fresh dashboard invitation."),
            .notDeviceMonitorHub, .invalidEnrollmentResponse, .storage("x"), .cancelled,
        ]
        // Plus everything a client actually throws in the failure paths above.
        let (hub, _, client) = try Self.setUp(serving: F.pin("B"))
        hub.onRequest { _ in .json(403, #"{"error":"Desktop proof refused"}"#) }
        if let error = await hubError({ _ = try await client.request(path: "/api/devices") }) { errors.append(error) }
        if let error = await hubError({ _ = try await client.request(path: "//" + F.client) }) { errors.append(error) }
        hub.servedPin = F.pin("A")
        hub.onRequest { _ in .json(401, #"{"error":"Open a fresh dashboard invitation."}"#) }
        if let error = await hubError({ _ = try await client.request(path: "/api/devices") }) { errors.append(error) }
        #expect(errors.count == 21)

        for error in errors {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            for text in [description, error.localizedDescription, "\(error)", String(reflecting: error)] {
                for secret in [F.client, F.proof, F.code, HubIdentity.credentialDigest(F.client)] {
                    #expect(!text.contains(secret), "\(text)")
                }
            }
        }
        #expect(HubError.pinMismatch(peerPin: F.pin("B")).errorDescription == "Hub TLS identity changed.")
        #expect(HubError.identityProofFailed.errorDescription == "Hub identity proof failed.")
        #expect(HubError.notDeviceMonitorHub.errorDescription == "The address is not a verified Device Monitor hub.")
        #expect(HubError.invalidEnrollmentResponse.errorDescription == "Invalid enrollment response.")
        #expect(HubError.unauthorized(status: 401, message: "m").errorDescription == "m")
    }

    @Test func mapsURLLoadingErrorsToFixedSentences() {
        func mapped(_ code: Int) -> HubError {
            HubError.transport(NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://hub.example/api/devices?token=" + F.client,
                NSLocalizedDescriptionKey: "leaky " + F.client,
            ]))
        }
        #expect(mapped(NSURLErrorTimedOut) == .unreachable("The hub did not answer in time."))
        #expect(mapped(NSURLErrorCannotFindHost) == .unreachable("The hub's address could not be found."))
        #expect(mapped(NSURLErrorDNSLookupFailed) == .unreachable("The hub's address could not be found."))
        #expect(mapped(NSURLErrorCannotConnectToHost) == .unreachable("Could not connect to the hub."))
        #expect(mapped(NSURLErrorNetworkConnectionLost) == .unreachable("The connection to the hub was lost."))
        #expect(mapped(NSURLErrorNotConnectedToInternet) == .unreachable("This device is offline."))
        #expect(mapped(NSURLErrorSecureConnectionFailed) == .unreachable("A secure connection to the hub could not be established."))
        #expect(mapped(NSURLErrorServerCertificateUntrusted) == .unreachable("A secure connection to the hub could not be established."))
        #expect(mapped(NSURLErrorCancelled) == .cancelled)
        #expect(mapped(NSURLErrorBadServerResponse) == .unreachable("The hub could not be reached (network error -1011)."))
        #expect(HubError.transport(CancellationError()) == .unreachable("The hub could not be reached."))
        // What iOS reports for a LAN hub while local network access is denied.
        let denied = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            "_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, uses wifi",
        ])
        #expect(HubError.transport(denied).errorDescription?.contains("Settings → Privacy & Security → Local Network") == true)
        #expect(HubError.transport(denied).isConnectivityFailure)
        for code in [NSURLErrorTimedOut, NSURLErrorBadServerResponse, NSURLErrorUnknown, NSURLErrorHTTPTooManyRedirects] {
            #expect(mapped(code).errorDescription?.contains(F.client) == false)
            #expect(mapped(code).isConnectivityFailure || mapped(code) == .cancelled)
        }
    }
}

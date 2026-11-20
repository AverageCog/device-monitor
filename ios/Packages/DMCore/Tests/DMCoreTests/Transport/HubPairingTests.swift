import Foundation
import Testing
@testable import DMCore

@Suite struct HubPairingTests {
    typealias F = TransportFixtures

    static let info = #"{"app":"device-monitor","locked":true}"#
    static let member = #"{"id":"\#(F.id)","client":"\#(F.client)","proof":"\#(F.proof)","name":"Matt's iPhone"}"#
    static let now = Date(timeIntervalSince1970: 1_795_123_456.789)

    static func invitation() throws -> Invitation {
        try Invitation.parse("\(F.origin)/mobile#join=\(F.code)")
    }

    /// A hub that answers the probe and redeems the code once.
    static func hub(serving pin: String = F.pin("A"), info: String = info, member: String = member) -> FakeHub {
        let hub = FakeHub(servedPin: pin)
        hub.onRequest { call in
            switch (call.method, call.path) {
            case ("GET", "/api/info"): .json(200, info)
            case ("POST", "/api/mobile/pair"): .json(200, member)
            default: .json(404, #"{"error":"not found"}"#)
            }
        }
        return hub
    }

    static func pair(_ hub: FakeHub, name: String = "  Matt's iPhone\n", path: String = "/api/mobile/pair", secret: String = "proof") async throws -> Enrollment {
        try await HubPairing.pair(invitation: invitation(), name: name, redeemPath: path, secondSecret: secret, now: now, connect: hub.connect)
    }

    @Test func probesThenRedeemsOnThePinnedConnection() async throws {
        let hub = Self.hub()
        let enrollment = try await Self.pair(hub)
        #expect(enrollment == (try Enrollment(
            origin: HubOrigin(F.origin), id: F.id, client: F.client, proof: F.proof, pin: F.pin("A"), name: "Matt's iPhone", pairedAt: Self.now)))
        #expect(enrollment.pairedAt.timeIntervalSince1970 == 1_795_123_456.789)

        #expect(hub.calls.count == 2)
        let probe = hub.calls[0], redeem = hub.calls[1]
        // Nothing secret goes to a server that has only passed standard validation.
        #expect(probe.policy == .capture)
        #expect(probe.method == "GET" && probe.path == "/api/info")
        #expect(probe.authorization == nil && probe.body == nil)
        #expect(probe.limit == 65536)
        // The code is only sent to the key that answered the probe.
        #expect(redeem.policy == .require(pin: F.pin("A")))
        #expect(redeem.method == "POST" && redeem.path == "/api/mobile/pair" && redeem.query == nil)
        #expect(redeem.authorization == "Bearer " + F.code)
        #expect(redeem.contentType == "application/json")
        #expect(redeem.json == ["name": "Matt's iPhone"])
        #expect(redeem.limit == 65536)
        #expect(hub.policies == [.capture, .require(pin: F.pin("A"))])
        #expect(Set(hub.invalidated) == [.capture, .require(pin: F.pin("A"))])

        // What comes back works as an enrollment: the store and client accept it as is.
        let store = InMemoryCredentialStore()
        try store.save(enrollment)
        _ = HubClient(enrollment: enrollment, store: store, connect: hub.connect)
    }

    @Test func sendsNoNameWhenThereIsNone() async throws {
        let hub = Self.hub(member: #"{"id":"\#(F.id)","client":"\#(F.client)","proof":"\#(F.proof)","name":"iPhone / iPad"}"#)
        let enrollment = try await Self.pair(hub, name: " \n\t")
        #expect(hub.calls[1].body == Data("{}".utf8))
        #expect(enrollment.name == "iPhone / iPad")       // the hub's default label
    }

    @Test func cleansTheLabelLikeTheHub() async throws {
        let long = String(repeating: "x", count: 100)
        let hub = Self.hub(member: #"{"id":"\#(F.id)","client":"\#(F.client)","proof":"\#(F.proof)"}"#)
        let enrollment = try await Self.pair(hub, name: "bell\u{7}" + long)
        #expect(hub.calls[1].json["name"] == "bell" + String(repeating: "x", count: 56))
        // Without a name in the answer, the label that was sent is kept.
        #expect(enrollment.name == "bell" + String(repeating: "x", count: 56))

        let odd = Self.hub(member: #"{"id":"\#(F.id)","client":"\#(F.client)","proof":"\#(F.proof)","name":"  tab\there  "}"#)
        #expect(try await Self.pair(odd).name == "tabhere")
        let typed = Self.hub(member: #"{"id":"\#(F.id)","client":"\#(F.client)","proof":"\#(F.proof)","name":7}"#)
        #expect(try await Self.pair(typed).name == "Matt's iPhone")
    }

    @Test func refusesAnAddressThatIsNotAHub() async throws {
        let impostors: [(String, FakeHub.Reply)] = [
            ("another app", .json(200, #"{"app":"something-else"}"#)),
            ("no app", .json(200, "{}")),
            ("app of the wrong type", .json(200, #"{"app":["device-monitor"]}"#)),
            ("a web page", .json(200, "<!doctype html><title>Router</title>")),
            ("an array", .json(200, #"["device-monitor"]"#)),
            ("empty", .json(200, "")),
            ("a plain-text refusal", .json(421, "This hub only answers requests addressed to it by IP address or its own name.")),
            ("a bare 404", .json(404, "")),
            ("a 500 page", .json(500, "<html>")),
        ]
        for (name, reply) in impostors {
            let hub = FakeHub(servedPin: F.pin("A"))
            hub.onRequest { _ in reply }
            #expect(await hubError { _ = try await Self.pair(hub) } == .notDeviceMonitorHub, "\(name)")
            // The invitation code never left the phone.
            #expect(hub.calls.count == 1 && hub.calls[0].authorization == nil, "\(name)")
            #expect(hub.policies == [.capture], "\(name)")
        }
        #expect(HubError.notDeviceMonitorHub.errorDescription == "The address is not a verified Device Monitor hub.")
    }

    @Test func aHubsOwnRefusalOfTheProbeIsShown() async throws {
        let hub = FakeHub(servedPin: F.pin("A"))
        hub.onRequest { _ in .json(403, #"{"error":"Use the configured HTTPS hub address."}"#) }
        // `.http`, never `.unauthorized`: there is no enrollment to repair yet.
        #expect(await hubError { _ = try await Self.pair(hub) } == .http(status: 403, message: "Use the configured HTTPS hub address."))
        hub.onRequest { _ in .json(429, #"{"error":"too many requests"}"#) }
        #expect(await hubError { _ = try await Self.pair(hub) } == .http(status: 429, message: "too many requests"))
        #expect(hub.calls.allSatisfy { $0.authorization == nil })
    }

    @Test func requiresACapturedPin() async throws {
        let hub = Self.hub()
        hub.reportsPinOnCapture = false
        #expect(await hubError { _ = try await Self.pair(hub) } == .notDeviceMonitorHub)
        #expect(hub.calls.count == 1)
    }

    @Test func showsTheHubsWordsForASpentInvitation() async throws {
        let hub = FakeHub(servedPin: F.pin("A"))
        hub.onRequest { call in
            call.path == "/api/info" ? .json(200, Self.info) : .json(403, #"{"error":"Invitation is invalid, expired or already used."}"#)
        }
        let failure = await hubError { _ = try await Self.pair(hub) }
        #expect(failure == .http(status: 403, message: "Invitation is invalid, expired or already used."))
        #expect(failure?.errorDescription == "Invitation is invalid, expired or already used.")
        #expect(failure?.isUnauthorized == false)

        hub.onRequest { call in call.path == "/api/info" ? .json(200, Self.info) : .json(404, #"{"error":"not found"}"#) }
        #expect(await hubError { _ = try await Self.pair(hub) } == .http(status: 404, message: "not found"))
        hub.onRequest { call in call.path == "/api/info" ? .json(200, Self.info) : .json(500, #"{"error":"Too many enrolled devices"}"#) }
        #expect(await hubError { _ = try await Self.pair(hub) } == .http(status: 500, message: "Too many enrolled devices"))
    }

    @Test func validatesTheEnrollmentStrictly() async throws {
        let c = F.client, p = F.proof, id = F.id
        let bad = [
            "", "[]", "null", "<html>", "{}",
            #"{"id":"\#(id)","client":"\#(c)"}"#,                                         // no proof
            #"{"id":"\#(id)","proof":"\#(p)"}"#,                                          // no client
            #"{"client":"\#(c)","proof":"\#(p)"}"#,                                       // no id
            #"{"id":"\#(id)","client":"\#(c)","agent":"\#(p)"}"#,                         // a desktop answer
            #"{"id":"\#(id)","client":"\#(c.dropLast())","proof":"\#(p)"}"#,
            #"{"id":"\#(id)","client":"\#(c)","proof":"\#(p)x"}"#,
            #"{"id":"\#(id)","client":"\#(c.dropLast())+","proof":"\#(p)"}"#,
            #"{"id":"\#(id)","client":"\#(c)","proof":"\#(c)"}"#,                         // one secret used twice
            #"{"id":"../../etc","client":"\#(c)","proof":"\#(p)"}"#,
            #"{"id":"","client":"\#(c)","proof":"\#(p)"}"#,
            #"{"id":7,"client":"\#(c)","proof":"\#(p)"}"#,
            #"{"id":"\#(id)","client":null,"proof":"\#(p)"}"#,
            #"{"id":"\#(id)","client":["\#(c)"],"proof":"\#(p)"}"#,
        ]
        for member in bad {
            let hub = Self.hub(member: member)
            #expect(await hubError { _ = try await Self.pair(hub) } == .invalidEnrollmentResponse, "\(member)")
        }
        #expect(HubError.invalidEnrollmentResponse.errorDescription == "Invalid enrollment response.")
        // Unknown extra fields are ignored.
        let extra = Self.hub(member: #"{"id":"\#(id)","client":"\#(c)","proof":"\#(p)","name":"n","future":[1,2]}"#)
        #expect(try await Self.pair(extra).name == "n")
    }

    @Test func neverSendsTheCodeToADifferentKey() async throws {
        let hub = FakeHub(servedPin: F.pin("A"))
        hub.onRequest { call in
            if call.path == "/api/info" {
                defer { hub.servedPin = F.pin("M") }          // someone else answers the second connection
                return .json(200, Self.info)
            }
            return .json(200, Self.member)
        }
        #expect(await hubError { _ = try await Self.pair(hub) } == .pinMismatch(peerPin: F.pin("M")))
        #expect(hub.calls.map(\.path) == ["/api/info"])
        #expect(hub.refusedHandshakes == [.require(pin: F.pin("A"))])
        #expect(HubError.pinMismatch(peerPin: F.pin("M")).errorDescription == "Hub TLS identity changed.")
    }

    @Test func surfacesConnectivityFailures() async throws {
        let hub = FakeHub(servedPin: F.pin("A"))
        hub.onRequest { _ in throw HubError.unreachable("The hub's address could not be found.") }
        #expect(await hubError { _ = try await Self.pair(hub) } == .unreachable("The hub's address could not be found."))
        hub.onRequest { _ in throw HubError.untrustedCertificate("“hub.example” certificate is not trusted.") }
        #expect(await hubError { _ = try await Self.pair(hub) } == .untrustedCertificate("“hub.example” certificate is not trusted."))
        hub.onRequest { _ in .json(302, "") }
        #expect(await hubError { _ = try await Self.pair(hub) } == .redirectRefused)
        hub.onRequest { _ in FakeHub.Reply(status: 200, body: Data(count: 70000)) }
        #expect(await hubError { _ = try await Self.pair(hub) } == .responseTooLarge)
    }

    /// The desktop endpoint has the same shape with `agent` as the second secret; the end-to-end
    /// tests pair through it until a hub with `/api/mobile/pair` is available.
    @Test func theRedeemEndpointIsAParameterOfTheInternalEntryPoint() async throws {
        let hub = FakeHub(servedPin: F.pin("A"))
        hub.onRequest { call in
            call.path == "/api/info" ? .json(200, Self.info) : .json(200, #"{"id":"\#(F.id)","client":"\#(F.client)","agent":"\#(F.proof)"}"#)
        }
        let enrollment = try await Self.pair(hub, path: "/api/pair", secret: "agent")
        #expect(hub.calls.map(\.path) == ["/api/info", "/api/pair"])
        #expect(enrollment.proof == F.proof && enrollment.client == F.client)
        // Same derivation either way: the second secret's digest stands where the agent digest does.
        #expect(HubIdentity.proofKey(client: enrollment.client, proof: enrollment.proof).withUnsafeBytes { Array($0) }
            == HubIdentity.desktopKey(HubIdentity.credentialDigest(F.proof), HubIdentity.credentialDigest(F.client))?.withUnsafeBytes { Array($0) })
    }

    @Test func errorsNeverContainTheCode() async throws {
        let replies: [FakeHub.Reply] = [
            .json(403, #"{"error":"Invitation is invalid, expired or already used."}"#), .json(200, "{}"), .json(500, ""), .json(200, "<html>"),
        ]
        for reply in replies {
            let hub = FakeHub(servedPin: F.pin("A"))
            hub.onRequest { call in call.path == "/api/info" ? .json(200, Self.info) : reply }
            let failure = try #require(await hubError { _ = try await Self.pair(hub) })
            for text in [failure.errorDescription ?? "", "\(failure)", String(reflecting: failure)] {
                #expect(!text.contains(F.code) && !text.contains(F.client) && !text.contains(F.proof), "\(text)")
            }
        }
    }
}

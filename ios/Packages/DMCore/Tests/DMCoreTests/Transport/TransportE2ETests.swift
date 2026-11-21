// The helper is a child process, which only macOS can start.
#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import DMCore

/// The real hub (`server.js`) behind real TLS, driven through `Fixtures/transport/e2e-hub.cjs`.
/// Needs Node and openssl, so it only runs when `DM_HUB_E2E` names the repository root:
///
///     DM_HUB_E2E=/path/to/device-monitor swift test --filter TransportE2ETests
///
/// Against a hub with the mobile routes the suite pairs exactly as the app does
/// (`/mobile#join=` invitation, `/api/mobile/pair`, second secret `proof`). A hub that predates
/// them is paired through the desktop endpoint (`/api/pair`, second secret `agent`), which has
/// the same shape and the same proof key derivation.
@Suite(.enabled(if: E2EHub.repositoryRoot != nil, "set DM_HUB_E2E to the repository root"), .serialized, .timeLimit(.minutes(3)))
final class TransportE2ETests: Sendable {
    static let proofPath = "/api/desktop/tls-proof"
    /// A device for the hub to show; unrelated to the enrollment under test.
    static let device = "e2e-device"

    let hub: E2EHub

    init() throws {
        hub = try E2EHub()
    }

    /// Sessions that also trust the helper's throwaway CA.
    var connect: @Sendable (PinnedSession.Policy) -> any PinnedTransport {
        let anchor = hub.anchor
        return { PinnedSession(policy: $0, testingTrustAnchors: [anchor]) }
    }

    var redeemPath: String { hub.supportsMobile ? HubPairing.redeemPath : "/api/pair" }

    func redeem(_ code: String, name: String) async throws -> Enrollment {
        guard hub.supportsMobile else {
            return try await HubPairing.pair(invitation: Invitation(origin: hub.origin, code: code), name: name, redeemPath: "/api/pair", secondSecret: "agent", connect: connect)
        }
        // The text a person scans or pastes, and the production endpoint and field.
        let invitation = try Invitation.parse("\(hub.origin)\(DMCore.invitationPath)#join=\(code)")
        return try await HubPairing.pair(invitation: invitation, name: name, redeemPath: HubPairing.redeemPath, secondSecret: HubPairing.secondSecret, connect: connect)
    }

    func enroll(name: String = "E2E iPhone") async throws -> Enrollment {
        try await redeem(hub.invite(), name: name)
    }

    func pair() async throws -> (enrollment: Enrollment, store: InMemoryCredentialStore, client: HubClient) {
        let enrollment = try await enroll()
        let store = InMemoryCredentialStore(enrollment)
        return (enrollment, store, HubClient(enrollment: enrollment, store: store, connect: connect))
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func type(_ frame: Data) -> String? {
        (try? object(frame))?["type"] as? String
    }

    /// Reads frames until `stop` says so, then lets go of the stream.
    static func read(_ stream: AsyncThrowingStream<Data, any Error>, until stop: ([Data]) -> Bool) async -> (frames: [Data], failure: HubError?) {
        var frames: [Data] = []
        do {
            for try await frame in stream {
                frames.append(frame)
                if stop(frames) { break }
            }
            return (frames, nil)
        } catch let error as HubError {
            return (frames, error)
        } catch {
            return (frames, .unreachable("unexpected error type"))
        }
    }

    func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try condition()
    }

    // MARK: Pairing and the API

    @Test func pairsThenCallsThePinnedAPI() async throws {
        let code = try hub.invite()
        let enrollment = try await redeem(code, name: "E2E iPhone")
        #expect(enrollment.origin == hub.origin)
        #expect(enrollment.pin == hub.pins["a"])                    // SecTrust + SPKIPin agree with Node's publicKeyPin
        #expect(Enrollment.isValidID(enrollment.id))
        #expect(enrollment.name == "E2E iPhone")

        let pairing = try hub.calls()
        #expect(pairing.calls.map(\.path) == ["/api/info", redeemPath])
        #expect(pairing.calls[0].authorization == nil)
        #expect(pairing.calls[1].authorization == "Bearer " + code)
        #expect(pairing.calls[1].method == "POST" && pairing.calls[1].body == #"{"name":"E2E iPhone"}"#)

        // The invitation is single use, and the hub's own words reach the caller.
        let spent = await hubError { _ = try await self.redeem(code, name: "") }
        #expect(spent == .http(status: 403, message: "Invitation is invalid, expired or already used."))

        let store = InMemoryCredentialStore(enrollment)
        let client = HubClient(enrollment: enrollment, store: store, connect: connect)
        try hub.seed(id: Self.device, hostname: "paired-desktop")
        let mark = try hub.calls().total

        let (data, response) = try await client.request(path: "/api/devices")
        #expect(response.statusCode == 200)
        let devices = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(devices.count == 1 && devices[0]["id"] as? String == Self.device && devices[0]["hostname"] as? String == "paired-desktop")

        struct Info: Decodable, Sendable { let app: String; let canShare: Bool?; let canEnroll: Bool?; let locked: Bool?; let origin: String? }
        let info: Info = try await client.json(path: "/api/info")
        #expect(info.app == "device-monitor" && info.canShare == true && info.canEnroll == false && info.locked == nil)
        #expect(info.origin == hub.origin.string)

        struct Done: Decodable, Sendable { let ok: Bool }
        let reordered = try await client.json(Done.self, method: "PUT", path: "/api/order", encoding: ["ids": [Self.device]])
        #expect(reordered.ok)

        let (history, _) = try await client.request(
            path: "/api/history/" + HubClient.pathComponent(Self.device),
            query: [URLQueryItem(name: "range", value: "1h"), URLQueryItem(name: "points", value: "50")])
        #expect(try Self.object(history)["points"] is [Any])

        #expect(await hubError { _ = try await client.request(path: "/api/nope") } == .http(status: 404, message: "not found"))
        #expect(await hubError { _ = try await client.request(path: "/api/energy", query: [URLQueryItem(name: "bounds", value: "3,2,1")]) } == .http(status: 400, message: "bad bounds"))

        let api = try hub.calls(since: mark).calls
        #expect(api.map(\.path) == ["/api/devices", "/api/info", "/api/order", "/api/history/" + Self.device, "/api/nope", "/api/energy"])
        #expect(api.allSatisfy { $0.authorization == "Bearer " + enrollment.client && $0.cookie == nil })
        #expect(api[2].contentType == "application/json" && api[2].method == "PUT")
        #expect(api[3].query == "?range=1h&points=50" && api[5].query == "?bounds=3,2,1")
        #expect(api.allSatisfy { $0.path != Self.proofPath })
        await client.close()
    }

    @Test func refusesAnAddressThatIsNotAHub() async throws {
        try hub.mode("not-a-hub")
        #expect(await hubError { _ = try await self.enroll() } == .notDeviceMonitorHub)
        let calls = try hub.calls().calls
        #expect(calls.map(\.path) == ["/api/info"])                 // the code was never sent
        #expect(calls[0].authorization == nil)
    }

    // MARK: Trust policy

    @Test func sessionPoliciesAreEnforcedInTheHandshake() async throws {
        let request = URLRequest(url: try #require(hub.origin.url(path: "/api/info")))
        let pinA = try #require(hub.pins["a"]), pinB = try #require(hub.pins["b"])

        let capture = PinnedSession(policy: .capture, testingTrustAnchors: [hub.anchor])
        let probed = try await capture.data(for: request, timeout: 10, maxResponseBytes: 65536)
        #expect(probed.peerPin == pinA && probed.response.statusCode == 200)

        // A capture session has checked that key against nothing, so it will not carry a
        // credential to it: the request is refused here and never reaches the server.
        var mark = try hub.calls().total
        var secret = request
        secret.setValue("Bearer " + String(repeating: "s", count: 43), forHTTPHeaderField: "Authorization")
        #expect(await hubError { _ = try await capture.data(for: secret, timeout: 10, maxResponseBytes: 65536) } == .invalidRequest)
        let carried = await Self.read(capture.bytes(for: secret, idleTimeout: 10).events.compactMapToData(), until: { _ in false })
        #expect(carried.failure == .invalidRequest)
        #expect(try hub.calls(since: mark).calls.isEmpty)
        capture.invalidate()

        // A pinned session refuses the wrong key before the request, and so the bearer, is written.
        mark = try hub.calls().total
        let wrong = PinnedSession(policy: .require(pin: pinB), testingTrustAnchors: [hub.anchor])
        #expect(await hubError { _ = try await wrong.data(for: secret, timeout: 10, maxResponseBytes: 65536) } == .pinMismatch(peerPin: pinA))
        let refused = await Self.read(wrong.bytes(for: secret, idleTimeout: 10).events.compactMapToData(), until: { _ in false })
        #expect(refused.failure == .pinMismatch(peerPin: pinA))
        #expect(try hub.calls(since: mark).calls.isEmpty)

        let right = PinnedSession(policy: .require(pin: pinA), testingTrustAnchors: [hub.anchor])
        let pinned = try await right.data(for: secret, timeout: 10, maxResponseBytes: 65536)
        #expect(pinned.peerPin == pinA && pinned.response.statusCode == 200)
        #expect(try hub.calls(since: mark).calls.count == 1)

        // Without the test anchors the helper's CA is just an unknown issuer: the public
        // initializer trusts nothing beyond the system and user-installed roots.
        let strict = PinnedSession(policy: .capture)
        let untrusted = await hubError { _ = try await strict.data(for: request, timeout: 10, maxResponseBytes: 65536) }
        guard case .untrustedCertificate = untrusted else {
            Issue.record("expected an untrusted certificate, got \(String(describing: untrusted))")
            return
        }
        #expect(try hub.calls(since: mark).calls.count == 1)

        // HTTPS only, and nothing after invalidation.
        let plain = URLRequest(url: try #require(URL(string: "http://127.0.0.1:9/")))
        #expect(await hubError { _ = try await right.data(for: plain, timeout: 1, maxResponseBytes: 10) } == .invalidRequest)
        right.invalidate()
        #expect(await hubError { _ = try await right.data(for: request, timeout: 10, maxResponseBytes: 65536) } == .cancelled)
    }

    /// What `HubClient` relies on when a rotation replaces a session: the old one finishes what
    /// it had started, starts nothing new and says so, and can still be told to drop the rest.
    @Test func aRetiredSessionFinishesWhatItStartedAndStartsNothingNew() async throws {
        let pinA = try #require(hub.pins["a"])
        let info = URLRequest(url: try #require(hub.origin.url(path: "/api/info")))
        // The HTTP/2 stand-in answers this one after 2.5 s; the front never answers its own.
        let answered = URLRequest(url: try #require(hub.multiplexedOrigin.url(path: "/e2e/slow", query: "ms=2500")))
        let unanswered = URLRequest(url: try #require(hub.origin.url(path: "/e2e/slow")))

        let finishing = PinnedSession(policy: .require(pin: pinA), testingTrustAnchors: [hub.anchor])
        async let late = finishing.data(for: answered, timeout: 10, maxResponseBytes: 65536)
        #expect(try await eventually { try self.hub.calls().calls.contains { $0.path == "/e2e/slow" && $0.http == "2.0" } })
        finishing.retire()
        #expect(!finishing.isDrained)
        let mark = try hub.calls().total
        await #expect(throws: PinnedSession.Retired.self) {
            _ = try await finishing.data(for: info, timeout: 10, maxResponseBytes: 65536)
        }
        #expect(try hub.calls(since: mark).calls.isEmpty)                  // refused without a connection
        #expect(try await late.response.statusCode == 200)                 // while the request it had goes through
        #expect(try await eventually { finishing.isDrained })

        let dropped = PinnedSession(policy: .require(pin: pinA), testingTrustAnchors: [hub.anchor])
        async let pending = hubError { _ = try await dropped.data(for: unanswered, timeout: 30, maxResponseBytes: 65536) }
        #expect(try await eventually { try self.hub.calls().calls.contains { $0.path == "/e2e/slow" && $0.http == "1.1" } })
        dropped.retire()
        #expect(!dropped.isDrained)
        let clock = ContinuousClock()
        let begun = clock.now
        dropped.invalidate()
        #expect(await pending == .cancelled)
        #expect(clock.now - begun < .seconds(3))
        #expect(try await eventually { dropped.isDrained })
        #expect(await hubError { _ = try await dropped.data(for: info, timeout: 10, maxResponseBytes: 65536) } == .cancelled)
    }

    @Test func neverSendsTheBearerToAnImpostor() async throws {
        let (enrollment, store, client) = try await pair()
        _ = try await client.request(path: "/api/devices")
        let pinA = try #require(hub.pins["a"])
        var mark = try hub.calls().total

        func attempt() async -> (request: HubError?, stream: HubError?) {
            let request = await hubError { _ = try await client.request(method: "PUT", path: "/api/order", body: Data(#"{"ids":[]}"#.utf8)) }
            let stream = await Self.read(client.events(), until: { _ in true })
            #expect(stream.frames.isEmpty)
            return (request, stream.failure)
        }
        func isUntrusted(_ error: HubError?) -> Bool {
            if case .untrustedCertificate = error { true } else { false }
        }

        // 1. A certificate from an authority this device does not trust: nothing gets through.
        try hub.present("untrusted")
        var seen = await attempt()
        #expect(isUntrusted(seen.request) && isUntrusted(seen.stream), "\(seen)")
        #expect(try hub.calls(since: mark).calls.isEmpty)

        // 2. A trusted certificate for a different name.
        try hub.present("wrongName")
        seen = await attempt()
        #expect(isUntrusted(seen.request) && isUntrusted(seen.stream), "\(seen)")
        #expect(try hub.calls(since: mark).calls.isEmpty)

        // 3. A valid certificate for this name on a different hub, which cannot answer the challenge.
        try hub.mode("unrelated")
        try hub.present("c", proxy: "c")
        seen = await attempt()
        #expect(seen.request == .identityProofFailed && seen.stream == .identityProofFailed)

        // 4. The same certificate relaying the challenge to the real hub, which vouches only for
        //    the key it is itself served under.
        try hub.mode("normal")
        try hub.present("c", proxy: "a")
        seen = await attempt()
        #expect(seen.request == .identityProofFailed && seen.stream == .identityProofFailed)

        // All the impostors ever received were challenges: no bearer, no digest, no request.
        let received = try hub.calls(since: mark).calls
        #expect(received.count == 4)
        for call in received {
            #expect(call.path == Self.proofPath && call.authorization == nil && call.cookie == nil)
            #expect(Set(try Self.object(Data(call.body.utf8)).keys) == ["lookup", "nonce", "challenge"])
            for secret in [enrollment.client, enrollment.proof, enrollment.id, HubIdentity.credentialDigest(enrollment.client), HubIdentity.credentialDigest(enrollment.proof)] {
                #expect(!call.body.contains(secret))
            }
        }
        #expect(try store.load()?.pin == pinA)
        #expect(await client.enrollment.pin == pinA)

        // 5. The genuine key again: the same client carries on, with nothing to prove.
        try hub.present("a", proxy: "a")
        mark = try hub.calls().total
        _ = try await client.request(path: "/api/devices")
        #expect(try hub.calls(since: mark).calls.map(\.path) == ["/api/devices"])
        await client.close()
    }

    @Test func recoversWhenTheHubRotatesItsKey() async throws {
        let (enrollment, store, client) = try await pair()
        try hub.seed(id: Self.device, hostname: "before-rotation")
        _ = try await client.request(path: "/api/devices")
        let pinB = try #require(hub.pins["b"])
        let mark = try hub.calls().total

        try hub.present("b", proxy: "b")                         // an RSA key replacing an EC one
        // Three requests and the live stream meet the new key at the same time.
        async let devices = client.request(path: "/api/devices")
        async let order = client.request(method: "PUT", path: "/api/order", body: Data(#"{"ids":[]}"#.utf8))
        async let alerts = client.request(path: "/api/alerts")
        async let live = Self.read(client.events(), until: { _ in true })
        _ = try await (devices, order, alerts)
        let snapshot = await live
        #expect(snapshot.failure == nil && snapshot.frames.first.flatMap(Self.type) == "snapshot")

        let calls = try hub.calls(since: mark).calls
        let proofs = calls.filter { $0.path == Self.proofPath }
        #expect(proofs.count == 1)                                 // one proof for all four
        #expect(proofs[0].authorization == nil && proofs[0].method == "POST" && proofs[0].contentType == "application/json")
        #expect(Set(try Self.object(Data(proofs[0].body.utf8)).keys) == ["lookup", "nonce", "challenge"])
        for secret in [enrollment.client, enrollment.proof, enrollment.id] {
            #expect(!proofs[0].body.contains(secret))
        }
        let operations = calls.filter { $0.path != Self.proofPath }
        #expect(operations.map(\.path).sorted() == ["/api/alerts", "/api/devices", "/api/order", "/api/stream"])   // each exactly once
        #expect(operations.allSatisfy { $0.served == "b" && $0.authorization == "Bearer " + enrollment.client })

        #expect(try store.load()?.pin == pinB)
        #expect(await client.enrollment.pin == pinB)
        #expect(try store.load() == enrollment.withPin(pinB))

        // From here on the new pin is simply the pin.
        _ = try await client.request(path: "/api/devices")
        let restarted = HubClient(enrollment: try #require(try store.load()), store: store, connect: connect)
        _ = try await restarted.request(path: "/api/devices")
        #expect(try hub.calls(since: mark).calls.filter { $0.path == Self.proofPath }.count == 1)
        await restarted.close()
        await client.close()
    }

    /// A front that renews its certificate in place (tailscale serve, a reloaded nginx or caddy)
    /// goes on serving the connections it already has. The live stream then stays on a session
    /// the client has replaced, and closing the client must still end it.
    @Test func closingEndsAStreamThatOutlivedAKeyRotation() async throws {
        let (enrollment, store, client) = try await pair()
        let pinB = try #require(hub.pins["b"])
        let frames = Counter(), ended = Counter()
        let live = Task { () -> HubError? in
            defer { ended.increment() }
            return await hubError { for try await _ in client.events() { frames.increment() } }
        }
        #expect(try await eventually { frames.count >= 1 })
        #expect(try hub.openStreams() == 1)
        let mark = try hub.calls().total

        try hub.present("b", proxy: "b", keepConnections: true)
        // The stream holds the only connection, so these need new ones and meet the new key.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await client.request(path: "/api/devices") } }
            try await group.waitForAll()
        }
        #expect(try store.load()?.pin == pinB)
        let calls = try hub.calls(since: mark).calls
        #expect(calls.filter { $0.path == Self.proofPath }.count == 1)
        #expect(calls.filter { $0.path == "/api/devices" }.count == 4)
        #expect(calls.allSatisfy { $0.served == "b" && $0.path != "/api/stream" })

        // The rotation left the stream where it was, still delivering under the key it verified.
        let before = frames.count
        #expect(try await eventually { frames.count > before })
        #expect(ended.count == 0)
        #expect(try hub.openStreams() == 1)
        #expect(try hub.calls().calls.filter { $0.path == "/api/stream" }.map(\.authorization) == ["Bearer " + enrollment.client])

        let clock = ContinuousClock()
        let begun = clock.now
        await client.close()
        #expect(try await eventually { ended.count == 1 })
        #expect(clock.now - begun < .seconds(3))
        live.cancel()                                               // only matters if the stream was left open
        #expect(await live.value == .cancelled)
        #expect(try await eventually { try self.hub.openStreams() == 0 })
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .cancelled)
    }

    // MARK: Live stream

    @Test func streamsTheSnapshotThenLiveFrames() async throws {
        let (enrollment, _, client) = try await pair()
        try hub.seed(id: Self.device, hostname: "first-report")
        let hub = hub
        let result = await Self.read(client.events()) { frames in
            // After the snapshot, cause a report; stop once it and a heartbeat have both arrived.
            if frames.count == 1 { try? hub.seed(id: Self.device, hostname: "second-report") }
            let types = Set(frames.compactMap(Self.type))
            return types.isSuperset(of: ["report", "status"])
        }
        #expect(result.failure == nil)
        let first = try Self.object(try #require(result.frames.first))
        #expect(first["type"] as? String == "snapshot")
        let devices = try #require(first["devices"] as? [[String: Any]])
        #expect(devices.count == 1 && devices[0]["id"] as? String == Self.device)
        #expect((devices[0]["latest"] as? [String: Any])?["hostname"] as? String == "first-report")
        let report = try Self.object(try #require(result.frames.first { Self.type($0) == "report" }))
        #expect(((report["device"] as? [String: Any])?["latest"] as? [String: Any])?["hostname"] as? String == "second-report")
        let status = try Self.object(try #require(result.frames.first { Self.type($0) == "status" }))
        #expect((status["online"] as? [String: Bool])?[Self.device] == true)

        let stream = try #require(try hub.calls().calls.last { $0.path == "/api/stream" })
        #expect(stream.authorization == "Bearer " + enrollment.client && stream.method == "GET")
        // Leaving the loop was enough to close the connection on the hub's side.
        #expect(try await eventually { try hub.openStreams() == 0 })
        await client.close()
    }

    @Test func deliversAMultiMegabyteSnapshotIntact() async throws {
        let (_, _, client) = try await pair()
        let size = 20 * 1024 * 1024
        try hub.mode("big-stream", bytes: size)
        let clock = ContinuousClock()
        let started = clock.now
        let result = await Self.read(client.events()) { $0.count == 3 }
        let elapsed = clock.now - started
        #expect(result.failure == nil && result.frames.count == 3)
        let snapshot = try #require(result.frames.first)
        #expect(snapshot.count > size)
        // The server hashed exactly what it framed, multi-byte characters and all.
        let digest = try Self.object(result.frames[1])
        #expect(digest["bytes"] as? Int == snapshot.count)
        #expect(digest["sha256"] as? String == HubIdentity.hex(SHA256.hash(data: snapshot)))
        #expect(Self.type(result.frames[2]) == "status")
        #expect(elapsed < .seconds(20), "20 MiB took \(elapsed)")
        await client.close()
    }

    @Test func aSilentStreamEndsWithAnError() async throws {
        let (_, _, client) = try await pair()
        try hub.mode("stalled-stream")
        let clock = ContinuousClock()
        let started = clock.now
        let result = await Self.read(EventStream(client: client, idleTimeout: 2).frames()) { _ in false }
        let elapsed = clock.now - started
        #expect(result.frames.count == 1 && Self.type(result.frames[0]) == "snapshot")
        #expect(result.failure == .unreachable("The hub did not answer in time."))
        #expect(elapsed > .milliseconds(1500) && elapsed < .seconds(12), "\(elapsed)")
        #expect(try await eventually { try self.hub.openStreams() == 0 })
        await client.close()
    }

    @Test func aRevokedEnrollmentIsReportedAsUnauthorized() async throws {
        let (enrollment, _, client) = try await pair()
        try hub.seed(id: Self.device, hostname: "soon-revoked")
        let hub = hub
        // The hub cuts an open stream of a revoked client.
        let open = await Self.read(client.events()) { frames in
            if frames.count == 1 { try? hub.revoke(id: enrollment.id) }
            return false
        }
        #expect(open.frames.first.flatMap(Self.type) == "snapshot")
        if let failure = open.failure { #expect(failure.isConnectivityFailure, "\(failure)") }

        let refused = HubError.unauthorized(status: 401, message: "Open a fresh dashboard invitation.")
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == refused)
        let reconnect = await Self.read(client.events()) { _ in false }
        #expect(reconnect.frames.isEmpty && reconnect.failure == refused)
        #expect(reconnect.failure?.isUnauthorized == true)
        // The verified hub still describes itself; only the credential is gone.
        struct Info: Decodable, Sendable { let app: String; let locked: Bool? }
        let info: Info = try await client.json(path: "/api/info")
        #expect(info.app == "device-monitor" && info.locked == true)
        await client.close()
    }

    /// What only a mobile enrollment has: its own label, its entry in `GET /api/mobile`, and
    /// "Disconnect" (`DELETE /api/mobile/<id>`). Nothing to check on a hub without those routes.
    @Test func aMobileEnrollmentListsAndDisconnectsItself() async throws {
        guard hub.supportsMobile else { return }
        let enrollment = try await enroll(name: "  Zoë's iPhone 📱\n")
        #expect(enrollment.name == "Zoë's iPhone 📱")              // as the hub stored it
        let store = InMemoryCredentialStore(enrollment)
        let client = HubClient(enrollment: enrollment, store: store, connect: connect)

        struct Phone: Decodable, Sendable { let id: String; let name: String; let created: Double? }
        let phones: [Phone] = try await client.json(path: "/api/mobile")
        #expect(phones.map(\.id) == [enrollment.id] && phones.first?.name == enrollment.name)

        // The same rights as a paired desktop: it may share a browser link, not enroll devices.
        struct Invite: Decodable, Sendable { let code: String }
        let link = try await client.json(Invite.self, method: "POST", path: "/api/invites", encoding: ["kind": "browser", "origin": hub.origin.string])
        #expect(HubIdentity.isValidSecret(link.code))
        let desktop = await hubError { _ = try await client.json(Invite.self, method: "POST", path: "/api/invites", encoding: ["kind": "desktop", "origin": self.hub.origin.string]) }
        // A refusal of one operation, not of the enrollment: the app must not offer to pair again.
        #expect(desktop == .http(status: 403, message: "Create this invitation on the hub."))
        #expect(desktop?.isUnauthorized == false)

        // The proof secret is never a credential.
        let other = try Enrollment(origin: enrollment.origin, id: enrollment.id, client: enrollment.proof, proof: enrollment.client,
                                   pin: enrollment.pin, name: "", pairedAt: Date())
        let swapped = HubClient(enrollment: other, store: InMemoryCredentialStore(other), connect: connect)
        #expect(await hubError { _ = try await swapped.request(path: "/api/devices") }?.httpStatus == 401)
        await swapped.close()

        // The rotation proof is keyed by the phone's own two secrets.
        try hub.present("b", proxy: "b")
        _ = try await client.request(path: "/api/devices")
        #expect(try store.load()?.pin == hub.pins["b"])

        struct Done: Decodable, Sendable { let ok: Bool }
        #expect(try await client.json(Done.self, method: "DELETE", path: "/api/mobile/" + HubClient.pathComponent(client.enrollmentID)).ok)
        let refused = HubError.unauthorized(status: 401, message: "Open a fresh dashboard invitation.")
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == refused)
        #expect(await Self.read(client.events()) { _ in false }.failure == refused)
        await client.close()
    }

    /// A TLS terminator that renews its certificate in place (tailscale serve, a reloaded nginx)
    /// keeps redeeming the session tickets it issued under the old key. A resumed session shows
    /// no certificate, so the pin check must not depend on one being skipped: every connection
    /// here is a full handshake that the delegate sees.
    @Test func everyNewConnectionIsVerifiedEvenWhenTheServerKeepsItsSessionTickets() async throws {
        let request = URLRequest(url: try #require(hub.origin.url(path: "/api/info")))
        let pinA = try #require(hub.pins["a"]), pinB = try #require(hub.pins["b"])

        // One connection, two requests: only the request that opened it saw a handshake.
        let capture = PinnedSession(policy: .capture, testingTrustAnchors: [hub.anchor])
        #expect(try await capture.data(for: request, timeout: 10, maxResponseBytes: 65536).peerPin == pinA)
        #expect(try await capture.data(for: request, timeout: 10, maxResponseBytes: 65536).peerPin == nil)
        var calls = try hub.calls().calls
        #expect(calls.count == 2 && calls[0].connection == calls[1].connection)

        // The server drops its connections but keeps its tickets: the next one is still verified.
        try hub.present("a", keepTickets: true)
        #expect(try await capture.data(for: request, timeout: 10, maxResponseBytes: 65536).peerPin == pinA)

        let pinned = PinnedSession(policy: .require(pin: pinA), testingTrustAnchors: [hub.anchor])
        _ = try await pinned.data(for: request, timeout: 10, maxResponseBytes: 65536)
        let mark = try hub.calls().total
        try hub.present("b", proxy: "b", keepTickets: true)
        // Tickets from the old key are still good, yet the new key is noticed and refused...
        #expect(await hubError { _ = try await pinned.data(for: request, timeout: 10, maxResponseBytes: 65536) } == .pinMismatch(peerPin: pinB))
        #expect(await hubError { _ = try await pinned.data(for: request, timeout: 10, maxResponseBytes: 65536) } == .pinMismatch(peerPin: pinB))
        #expect(try hub.calls(since: mark).calls.isEmpty)
        // ...and a session for the new pin gets the new key, not a cached identity.
        let renewed = PinnedSession(policy: .require(pin: pinB), testingTrustAnchors: [hub.anchor])
        #expect(try await renewed.data(for: request, timeout: 10, maxResponseBytes: 65536).peerPin == pinB)
        calls = try hub.calls().calls
        #expect(calls.allSatisfy { !$0.resumed })
        #expect(calls.last?.served == "b")

        // The client's own recovery works the same against such a server.
        try hub.present("a", proxy: "a", keepTickets: true)
        let (_, store, client) = try await pair()
        try hub.present("b", proxy: "b", keepTickets: true)
        _ = try await client.request(path: "/api/devices")
        #expect(try store.load()?.pin == pinB)
        try hub.present("a", proxy: "a", keepTickets: true)
        _ = try await client.request(path: "/api/devices")
        #expect(try store.load()?.pin == pinA)
        await client.close()
    }

    /// Over HTTP/2 (what tailscale serve speaks) every request shares one connection, so one
    /// handshake stands for many requests. Each of them must still learn why it was refused.
    @Test func concurrentRequestsOverHTTP2AllSeeTheVerdictOfTheirHandshake() async throws {
        let pinA = try #require(hub.pins["a"]), pinB = try #require(hub.pins["b"])
        let origin = hub.multiplexedOrigin
        let anchor = hub.anchor
        /// Six requests at once; half of them take a while, so they overlap on the connection.
        @Sendable func burst(_ session: PinnedSession) async -> [Result<Int, HubError>] {
            await withTaskGroup(of: Result<Int, HubError>.self) { group in
                for index in 0..<6 {
                    group.addTask {
                        guard let url = origin.url(path: index % 2 == 0 ? "/api/info" : "/e2e/slow") else { return .failure(.invalidRequest) }
                        do {
                            return .success(try await session.data(for: URLRequest(url: url), timeout: 10, maxResponseBytes: 65536).response.statusCode)
                        } catch {
                            return .failure(error as? HubError ?? .invalidResponse)
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }

        let right = PinnedSession(policy: .require(pin: pinA), testingTrustAnchors: [anchor])
        #expect(await burst(right) == Array(repeating: .success(200), count: 6))
        #expect(await burst(right) == Array(repeating: .success(200), count: 6))
        let calls = try hub.calls().calls
        #expect(calls.count == 12 && calls.allSatisfy { $0.http == "2.0" })

        // The live stream and requests share the connection without disturbing each other.
        let enrollment = try Enrollment(
            origin: origin, id: "h2-test", client: String(repeating: "c", count: 43), proof: String(repeating: "p", count: 43),
            pin: pinA, name: "", pairedAt: Date())
        let client = HubClient(enrollment: enrollment, store: InMemoryCredentialStore(enrollment), connect: connect)
        async let live = Self.read(client.events()) { $0.count == 5 }
        for _ in 0..<5 { _ = try await client.request(path: "/api/info") }
        let frames = await live
        #expect(frames.failure == nil && frames.frames.compactMap(Self.type) == ["snapshot", "status", "status", "status", "status"])
        #expect(try await eventually { try self.hub.openStreams() == 0 })
        await client.close()

        // The wrong key: every one of the six is told so, and none of them was sent.
        var mark = try hub.calls().total
        let wrong = PinnedSession(policy: .require(pin: pinB), testingTrustAnchors: [anchor])
        #expect(await burst(wrong) == Array(repeating: .failure(.pinMismatch(peerPin: pinA)), count: 6))
        #expect(try hub.calls(since: mark).calls.isEmpty)

        // A key that changes under an established connection pool.
        try hub.presentMultiplexed("b")
        mark = try hub.calls().total
        #expect(await burst(right) == Array(repeating: .failure(.pinMismatch(peerPin: pinB)), count: 6))
        #expect(try hub.calls(since: mark).calls.isEmpty)
    }

    // MARK: Limits

    @Test func refusesRedirectsAndEnforcesLimits() async throws {
        let (_, _, client) = try await pair()
        var mark = try hub.calls().total

        #expect(await hubError { _ = try await client.request(path: "/e2e/redirect") } == .redirectRefused)
        #expect(try hub.calls(since: mark).calls.map(\.path) == ["/e2e/redirect"])     // the target was never requested

        func big(_ bytes: Int, chunked: Bool = false) async throws -> Int {
            let query = [URLQueryItem(name: "bytes", value: String(bytes))] + (chunked ? [URLQueryItem(name: "chunked", value: nil)] : [])
            return try await client.request(path: "/e2e/big", query: query, maxResponseBytes: 65536).0.count
        }
        #expect(try await big(65536) == 65536)
        #expect(try await big(65536, chunked: true) == 65536)
        #expect(await hubError { _ = try await big(65537) } == .responseTooLarge)
        #expect(await hubError { _ = try await big(300_000, chunked: true) } == .responseTooLarge)
        try hub.mode("big-info")
        #expect(await hubError { _ = try await client.request(path: "/api/info") } == .responseTooLarge)       // 64 KiB by default
        try hub.mode("normal")

        // The timeout bounds the whole exchange, not the gaps between packets.
        let clock = ContinuousClock()
        var started = clock.now
        #expect(await hubError { _ = try await client.request(path: "/e2e/slow", timeout: 1) } == .unreachable("The hub did not answer in time."))
        #expect(clock.now - started > .milliseconds(900) && clock.now - started < .seconds(6))

        // Cancelling the caller cancels the request.
        let waiting = Task { await hubError { _ = try await client.request(path: "/e2e/slow") } }
        try await Task.sleep(for: .milliseconds(300))
        started = clock.now
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        #expect(clock.now - started < .seconds(3))

        // No cookie jar.
        mark = try hub.calls().total
        _ = try await client.request(path: "/e2e/cookie")
        _ = try await client.request(path: "/e2e/cookie")
        let cookies = try hub.calls(since: mark).calls
        #expect(cookies.count == 2 && cookies.allSatisfy { $0.cookie == nil })

        // Closing the client cancels what is in flight and refuses what comes after.
        async let pending = hubError { _ = try await client.request(path: "/e2e/slow") }
        async let stream = Self.read(client.events()) { _ in false }
        try await Task.sleep(for: .milliseconds(500))
        started = clock.now
        await client.close()
        #expect(await pending == .cancelled)
        #expect(await stream.failure == .cancelled)
        #expect(clock.now - started < .seconds(3))
        #expect(await hubError { _ = try await client.request(path: "/api/devices") } == .cancelled)
        #expect(try await eventually { try self.hub.openStreams() == 0 })
    }
}

private extension AsyncThrowingStream where Element == PinnedSession.StreamEvent, Failure == any Error {
    /// The body chunks of a byte stream, for tests that only care how it ends.
    func compactMapToData() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    for try await event in self {
                        if case .data(let data) = event { continuation.yield(data) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The helper process and its line protocol.
final class E2EHub: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct ServerCall: Decodable {
        let mode: String
        let served: String
        let method: String
        let path: String
        let query: String
        let authorization: String?
        let contentType: String?
        let cookie: String?
        let body: String
        /// Whether this request's TLS session was resumed from a ticket rather than negotiated in full.
        let resumed: Bool
        /// Which TCP connection carried it.
        let connection: Int
        /// "1.1" or "2.0".
        let http: String
    }

    struct Calls: Decodable { let total: Int; let calls: [ServerCall] }
    private struct Ready: Decodable { let origin: String; let multiplexedOrigin: String; let mobile: Bool; let pins: [String: String]; let ca: String }
    private struct Invite: Decodable { let code: String }
    private struct Streams: Decodable { let open: Int }
    private struct Empty: Decodable {}
    private struct Reply<Result: Decodable>: Decodable { let seq: Int?; let ok: Bool; let result: Result?; let error: String? }
    private struct Header: Decodable { let seq: Int? }

    static var repositoryRoot: String? {
        ProcessInfo.processInfo.environment["DM_HUB_E2E"].flatMap { $0.isEmpty ? nil : $0 }
    }

    let origin: HubOrigin
    /// An HTTP/2 stand-in under the same certificates (the hub itself speaks HTTP/1.1).
    let multiplexedOrigin: HubOrigin
    /// Whether this hub has the mobile enrollment routes (`POST /api/mobile/pair` and friends).
    let supportsMobile: Bool
    let pins: [String: String]
    /// DER of the throwaway CA the helper's certificates chain to.
    let anchor: Data

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var buffer: Data
    private var sequence = 0

    init() throws {
        guard let root = Self.repositoryRoot else { throw Failure(description: "DM_HUB_E2E is not set") }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", Fixture.url("transport/e2e-hub.cjs").path, root]
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        var pending = Data()
        let ready: Ready
        do {
            ready = try JSONDecoder().decode(Ready.self, from: Self.line(from: stdout.fileHandleForReading, buffer: &pending))
            guard let anchor = Data(base64Encoded: ready.ca) else { throw Failure(description: "the helper sent no CA") }
            self.anchor = anchor
            origin = try HubOrigin(ready.origin)
            multiplexedOrigin = try HubOrigin(ready.multiplexedOrigin)
            supportsMobile = ready.mobile
        } catch {
            process.terminate()
            throw error
        }
        pins = ready.pins
        buffer = pending
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        self.process = process
    }

    deinit {
        // Closing stdin asks the helper to shut the hub down and remove its files.
        try? input.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }

    private static func line(from handle: FileHandle, buffer: inout Data) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
                return line
            }
            let more = handle.availableData
            guard !more.isEmpty else { throw Failure(description: "the hub helper exited; is node on PATH?") }
            buffer.append(more)
        }
    }

    private func send<Result: Decodable>(_ command: String, _ arguments: [String: Any] = [:], as: Result.Type = Result.self) throws -> Result {
        try lock.withLock {
            sequence += 1
            var message = arguments
            message["seq"] = sequence
            message["command"] = command
            try input.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([0x0A]))
            while true {
                let line = try Self.line(from: output, buffer: &buffer)
                guard try JSONDecoder().decode(Header.self, from: line).seq == sequence else { continue }
                let reply = try JSONDecoder().decode(Reply<Result>.self, from: line)
                guard reply.ok, let result = reply.result else { throw Failure(description: "\(command): \(reply.error ?? "no result")") }
                return result
            }
        }
    }

    /// A fresh invitation code: a mobile one where the hub issues them, else a desktop one.
    func invite() throws -> String { try send("invite", as: Invite.self).code }
    /// Makes a device with this id report once.
    func seed(id: String, hostname: String) throws { _ = try send("seed", ["id": id, "hostname": hostname], as: Empty.self) }
    func revoke(id: String) throws { _ = try send("revoke", ["id": id], as: Empty.self) }
    /// Swaps the certificate the front presents; `proxy` also tells the hub which one is served.
    /// `keepConnections` leaves the connections the front already has open, as a front that
    /// renews its certificate in place does.
    func present(_ certificate: String, proxy: String? = nil, keepTickets: Bool = false, keepConnections: Bool = false) throws {
        var arguments: [String: Any] = ["certificate": certificate, "keepTickets": keepTickets, "keepConnections": keepConnections]
        if let proxy { arguments["proxy"] = proxy }
        _ = try send("present", arguments, as: Empty.self)
    }
    func presentMultiplexed(_ certificate: String) throws { _ = try send("presentMultiplexed", ["certificate": certificate], as: Empty.self) }
    func mode(_ mode: String, bytes: Int = 0) throws { _ = try send("mode", ["mode": mode, "bytes": bytes], as: Empty.self) }
    /// Every request that got through TLS to the front, from index `since`.
    func calls(since: Int = 0) throws -> Calls { try send("calls", ["since": since]) }
    func openStreams() throws -> Int { try send("streams", as: Streams.self).open }
}
#endif

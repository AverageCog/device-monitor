import Foundation
import Testing
@testable import DMCore

/// `LiveHubAPI` over the scripted transport: which request each operation makes, and what it
/// makes of the hub's answers. The answers are the ones captured from a real hub.
@Suite struct LiveHubAPITests {
    typealias F = TransportFixtures
    typealias M = ModelFixture

    static func setUp() throws -> (hub: FakeHub, api: LiveHubAPI) {
        let enrollment = try F.enrollment()
        let hub = FakeHub(servedPin: F.pin("A"))
        let client = HubClient(enrollment: enrollment, store: InMemoryCredentialStore(enrollment), connect: hub.connect)
        return (hub, LiveHubAPI(client: client))
    }

    /// One member of a fixture that holds several captured answers.
    static func part(_ file: String, _ key: String) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: M.data(file)) as? [String: Any], let member = object[key] else { throw NoBody() }
        return try M.reencode(member)
    }

    static let phone = #"[{"id":"0b8f6a52-6c1e-4b7e-9a57-0d7a6d2c9f11","name":"Test iPhone","created":1795000000000,"lastSeen":null},{"unreadable":true}]"#

    /// What a hub answers on each route the app uses.
    static func routes() throws -> [String: FakeHub.Reply] {
        let ok = FakeHub.Reply.json(200, #"{"ok":true}"#)
        return [
            "GET /api/info": .init(body: try part("info.json", "client")),
            "GET /api/devices": .init(body: try M.data("devices.json")),
            "PATCH /api/devices/" + M.lab: .init(body: try M.data("device-patch.json")),
            "DELETE /api/devices/aa%3Abb%2Fcc%20dd%3F%C3%A9": ok,
            "PUT /api/order": ok,
            "GET /api/history/ws": .init(body: try M.data("history-24h.json")),
            "GET /api/energy": .init(body: try M.data("energy-7d-flat.json")),
            "GET /api/energy/settings": .init(body: try part("energy-settings.json", "get")),
            "PUT /api/energy/settings": .init(body: try part("energy-settings.json", "putFlat")),
            "GET /api/alerts": .init(body: try M.data("alerts.json")),
            "PUT /api/alerts": .init(body: try M.data("alerts-put.json")),
            "POST /api/alerts/test": .init(body: try M.data("alerts-test-delivery.json")),
            "DELETE /api/alerts/log": ok,
            "POST /api/devices/ws/action": ok,
            "POST /api/invites": .init(body: try M.data("invite-browser.json")),
            "GET /api/update/windows": .init(body: try part("update.json", "published")),
            "GET /api/update/mac": .init(status: 404, body: try part("update.json", "otherPlatform")),
            "GET /api/remote": .init(body: try M.data("remote.json")),
            "GET /api/mobile": .json(200, phone),
            "DELETE /api/mobile/" + F.id: ok,
        ]
    }

    struct NoBody: Error {}

    /// The JSON object a request carried.
    static func body(_ call: FakeHub.Call?) throws -> NSDictionary {
        guard let data = call?.body, let object = try JSONSerialization.jsonObject(with: data) as? NSDictionary else { throw NoBody() }
        return object
    }

    @Test func everyOperationMakesTheDashboardsRequest() async throws {
        let (hub, api) = try Self.setUp()
        let routes = try Self.routes()
        hub.onRequest { call in routes[call.method + " " + call.path] ?? .json(404, #"{"error":"not found"}"#) }

        let info = try await api.info()
        let devices = try await api.devices()
        let renamed = try await api.rename(device: M.lab, name: "Lab PC")
        try await api.remove(device: "aa:bb/cc dd?\u{E9}")
        try await api.setOrder(ids: ["b", "a", "off"])
        let series = try await api.history(device: "ws", range: .sixHours, points: 360)
        let window = try await api.history(device: "ws", from: 1_795_213_000_000.4, to: 1_795_213_600_000.5, points: 900)
        let energy = try await api.energy(bounds: [1_795_132_800_000, 1_795_219_200_000, 1_795_305_600_000])
        let price = try await api.energySettings()
        let stored = try await api.saveEnergySettings(EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        let alerts = try await api.alerts()
        let update = try await api.saveAlerts(alerts.settings)
        let delivery = try await api.testAlert()
        try await api.clearAlertLog()
        try await api.wake(device: "ws")
        let link = try await api.createBrowserInvitation()
        let windows = try await api.latestVersion(platform: .windows)
        let mac = try await api.latestVersion(platform: .mac)
        let remote = try await api.remoteStatus()
        let phones = try await api.mobileClients()
        try await api.unpairSelf()

        // Method, path and query, in the order asked.
        let calls = hub.calls
        #expect(calls.map { "\($0.method) \($0.path)" + ($0.query.map { "?" + $0 } ?? "") } == [
            "GET /api/info",
            "GET /api/devices",
            "PATCH /api/devices/" + M.lab,
            "DELETE /api/devices/aa%3Abb%2Fcc%20dd%3F%C3%A9",                       // encodeURIComponent(id)
            "PUT /api/order",
            "GET /api/history/ws?range=6h&points=360",
            "GET /api/history/ws?from=1795213000000&to=1795213600001&points=900",  // Math.round, as JavaScript rounds
            "GET /api/energy?bounds=1795132800000,1795219200000,1795305600000",
            "GET /api/energy/settings",
            "PUT /api/energy/settings",
            "GET /api/alerts",
            "PUT /api/alerts",
            "POST /api/alerts/test",
            "DELETE /api/alerts/log",
            "POST /api/devices/ws/action",
            "POST /api/invites",
            "GET /api/update/windows",
            "GET /api/update/mac",
            "GET /api/remote",
            "GET /api/mobile",
            "DELETE /api/mobile/" + F.id,
        ])
        #expect(calls.allSatisfy { $0.authorization == "Bearer " + F.client && !$0.isStream })

        // Bodies: JSON where the hub reads one, nothing where it does not.
        let sent = Dictionary(calls.map { ("\($0.method) \($0.path)", $0) }, uniquingKeysWith: { first, _ in first })
        let withBody = ["PATCH /api/devices/" + M.lab, "PUT /api/order", "PUT /api/energy/settings", "PUT /api/alerts", "POST /api/devices/ws/action", "POST /api/invites"]
        for call in calls {
            let expected = withBody.contains("\(call.method) \(call.path)")
            #expect((call.body != nil) == expected && (call.contentType == "application/json") == expected, "\(call.method) \(call.path)")
        }
        #expect(try Self.body(sent["PATCH /api/devices/" + M.lab]) == ["name": "Lab PC"])
        #expect(try Self.body(sent["PUT /api/order"]) == ["ids": ["b", "a", "off"]])
        #expect(try Self.body(sent["PUT /api/energy/settings"]) == ["region": "US-CA", "rate": 0.316, "currency": "USD"])
        #expect(try Self.body(sent["POST /api/devices/ws/action"]) == ["action": "wake"])
        // Asked for the origin this app is enrolled at, with no device id.
        #expect(try Self.body(sent["POST /api/invites"]) == ["kind": "browser", "origin": F.origin])
        // What GET answered goes back as it came: the stored webhook address is kept, not erased.
        let alertsBody = try Self.body(sent["PUT /api/alerts"])
        let alertsSettings = try M.json(alerts.settings)
        #expect(alertsBody == alertsSettings)
        #expect((alertsBody["channels"] as? NSDictionary)?["webhook"] as? NSDictionary == ["enabled": true, "keepUrl": true])

        // The whole exchange has fifteen seconds, the test alert thirty; info and updates are small.
        #expect(calls.filter { $0.path != "/api/alerts/test" }.allSatisfy { $0.timeout == 15 })
        #expect(sent["POST /api/alerts/test"]?.timeout == 30)
        #expect(sent["GET /api/info"]?.limit == 64 * 1024 && sent["GET /api/update/windows"]?.limit == 64 * 1024 && sent["GET /api/devices"]?.limit == 32 * 1024 * 1024)

        // And the answers come back as models.
        #expect(info.isDeviceMonitor && info.canShare && !info.canEnroll && info.origin == "https://hub.test")
        #expect(devices.count == 6 && devices.first?.id == M.workstation && devices.first?.history.isEmpty == false)
        #expect(renamed.id == M.lab && renamed.name == "Lab PC" && renamed.renamed)
        #expect(series.points.count == 22 && series.resolution == 3_600_000 && window == series)
        #expect(energy.bounds.count == 8 && energy.devices.count == 6 && energy.settings?.currency == "USD")
        #expect(price?.isTimeOfUse == true && stored == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        #expect(alerts.settings.rules.count == 9 && !alerts.events.isEmpty && update.settings.rules.count == alerts.settings.rules.count)
        #expect(delivery.ntfy == .init(ok: false, error: "Blocked alert destination") && delivery.webhook?.error == "ERR_INVALID_URL")
        #expect(link.absoluteString == F.origin + "/unlock#join=FIXTURE-invitation-code-0000000000000000000")
        #expect(windows == "1.2.33" && mac == nil)
        #expect(remote == RemoteStatus(installed: false, port: 38017, canConfigure: false, platform: "linux"))
        #expect(phones == [MobileClient(id: F.id, name: "Test iPhone", created: 1_795_000_000_000)])   // the entry it cannot read is dropped
    }

    @Test func aHubWithoutAPriceAnswersNull() async throws {
        let (hub, api) = try Self.setUp()
        hub.onRequest { _ in .json(200, "null") }
        #expect(try await api.energySettings() == nil)
    }

    @Test func refusalsKeepTheirMeaning() async throws {
        let (hub, api) = try Self.setUp()
        hub.onRequest { call in
            switch call.path {
            case "/api/devices": .json(401, #"{"error":"Open a fresh dashboard invitation."}"#)
            case "/api/devices/ws/action": .json(403, #"{"error":"Host integrations disabled"}"#)
            case "/api/invites": .json(403, #"{"error":"Create this invitation on the hub."}"#)
            case "/api/energy": .json(400, #"{"error":"bad bounds"}"#)
            case "/api/update/windows": .json(500, "<h1>oops</h1>")
            case "/api/update/mac": .json(401, #"{"error":"Open a fresh dashboard invitation."}"#)
            case "/api/remote": throw HubError.unreachable("Could not connect to the hub.")
            default: .json(404, #"{"error":"not found"}"#)
            }
        }
        // 401: the hub no longer knows this enrollment.
        let revoked = await hubError { _ = try await api.devices() }
        #expect(revoked == .unauthorized(status: 401, message: "Open a fresh dashboard invitation.") && revoked?.kind == .unauthorized)
        // 403: the hub refuses this one thing to a credential it accepts.
        let refused = await hubError { try await api.wake(device: "ws") }
        #expect(refused == .http(status: 403, message: "Host integrations disabled") && refused?.kind == .rejected && refused?.isUnauthorized == false)
        #expect(await hubError { _ = try await api.createBrowserInvitation() } == .http(status: 403, message: "Create this invitation on the hub."))
        #expect(await hubError { _ = try await api.energy(bounds: [3, 2]) } == .http(status: 400, message: "bad bounds"))
        #expect(await hubError { _ = try await api.history(device: "gone", range: .hour, points: 360) } == .http(status: 404, message: "not found"))
        // Only "nothing published" is an answer; any other failure of that route is a failure.
        #expect(await hubError { _ = try await api.latestVersion(platform: .windows) } == .http(status: 500, message: "HTTP 500"))
        #expect(await hubError { _ = try await api.latestVersion(platform: .mac) }?.isUnauthorized == true)
        let unreachable = await hubError { _ = try await api.remoteStatus() }
        #expect(unreachable == .unreachable("Could not connect to the hub.") && unreachable?.kind == .unreachable)
    }

    @Test func answersThatAreNotWhatWasAskedForAreInvalid() async throws {
        let (hub, api) = try Self.setUp()
        hub.onRequest { call in
            switch call.path {
            case "/api/devices", "/api/mobile": .json(200, #"{"not":"an array"}"#)
            case "/api/alerts": .json(200, "<html>")
            case "/api/update/windows": .json(200, #"{"file":"x.exe"}"#)
            case "/api/energy/settings": .json(200, #"{"region":"DE"}"#)
            default: .json(200, "[]")
            }
        }
        #expect(await hubError { _ = try await api.devices() } == .invalidResponse)
        #expect(await hubError { _ = try await api.mobileClients() } == .invalidResponse)
        #expect(await hubError { _ = try await api.alerts() } == .invalidResponse)
        #expect(await hubError { _ = try await api.latestVersion(platform: .windows) } == .invalidResponse)
        #expect(await hubError { _ = try await api.energySettings() } == .invalidResponse)
        #expect(await hubError { _ = try await api.info() } == .invalidResponse)
        #expect(HubError.invalidResponse.kind == .other)
        // Actions that only need the hub to agree do not read the body.
        try await api.clearAlertLog()
        try await api.setOrder(ids: [])
    }

    @Test func anInvitationCodeOfTheWrongShapeIsNotPutIntoALink() async throws {
        let (hub, api) = try Self.setUp()
        for code in ["", "short", String(repeating: "a", count: 42), String(repeating: "a", count: 44), String(repeating: "a", count: 42) + "/", String(repeating: "a", count: 42) + "#"] {
            hub.onRequest { _ in .init(body: try JSONSerialization.data(withJSONObject: ["code": code, "origin": F.origin, "expires": 1])) }
            #expect(await hubError { _ = try await api.createBrowserInvitation() } == .invalidResponse, "\(code.count) characters")
        }
        let good = String(repeating: "aZ0_-", count: 9).prefix(43)
        hub.onRequest { _ in .init(body: try JSONSerialization.data(withJSONObject: ["code": String(good), "origin": "https://elsewhere.example"])) }
        // The link is for the enrolled origin whatever the answer claims.
        #expect(try await api.createBrowserInvitation().absoluteString == F.origin + "/unlock#join=" + good)
    }

    @Test func aCancelledCallIsCancelled() async throws {
        let (hub, api) = try Self.setUp()
        hub.onRequest { _ in
            try await Task.sleep(for: .seconds(30))
            return .json(200, "[]")
        }
        let call = Task { await hubError { _ = try await api.devices() } }
        #expect(await EventStreamTests.eventually { hub.calls.count == 1 })
        call.cancel()
        let failure = await call.value
        #expect(failure == .cancelled && failure?.kind == .cancelled)
    }

    // MARK: Errors

    @Test func everyFailureHasAKind() {
        #expect(HubError.unauthorized(status: 403, message: "").kind == .unauthorized)
        #expect(HubError.http(status: 403, message: "").kind == .rejected && HubError.http(status: 500, message: "").kind == .rejected)
        let connectivity: [HubError] = [.unreachable(""), .untrustedCertificate(""), .pinMismatch(peerPin: ""), .identityProofFailed, .redirectRefused]
        #expect(connectivity.allSatisfy { $0.kind == .unreachable && $0.isConnectivityFailure })
        #expect(HubError.cancelled.kind == .cancelled)
        let rest: [HubError] = [.invalidOrigin, .invalidInvitation(.malformed), .invalidRequest, .responseTooLarge, .invalidResponse, .notDeviceMonitorHub, .invalidEnrollmentResponse, .storage("")]
        #expect(rest.allSatisfy { $0.kind == .other && !$0.isConnectivityFailure && !$0.isUnauthorized })
    }

    @Test func anyErrorBecomesAHubError() {
        struct Odd: Error {}
        #expect(HubError(HubError.http(status: 409, message: "x")) == .http(status: 409, message: "x"))
        #expect(HubError(CancellationError()) == .cancelled)
        #expect(HubError(URLError(.timedOut)) == .unreachable("The hub did not answer in time."))
        #expect(HubError(URLError(.cancelled)) == .cancelled)
        #expect(HubError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))) == .invalidResponse)
        #expect(HubError(EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: ""))) == .invalidRequest)
        #expect(HubError(Odd()) == .unreachable("The hub could not be reached."))
    }

    // MARK: The stream

    static func collect(_ stream: AsyncThrowingStream<HubEvent, any Error>) async -> (events: [HubEvent], failure: HubError?) {
        var events: [HubEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch let error as HubError {
            return (events, error)
        } catch {
            return (events, .invalidRequest)
        }
    }

    @Test func eventsDecodesFramesAndSkipsWhatItCannotRead() async throws {
        let (hub, api) = try Self.setUp()
        let frames = try M.frames()
        hub.onStream { _ in
            EventStreamTests.script(200, [
                "data: " + frames[0] + "\n\n",
                "data: not json at all\n\n",                           // garbage
                "data: {\"type\":\"report\",\"id\":\"ws\"}\n\n",         // a known type missing what it needs
                "data: {\"type\":\"mystery\",\"since\":\"2030\"}\n\n",   // something a newer hub says
                "data: " + frames[1] + "\n\ndata: " + frames[5] + "\n\n",
            ])
        }
        let result = await Self.collect(api.events())
        #expect(result.failure == nil)                                  // the hub ended the response
        #expect(result.events.map(\.type) == ["snapshot", "mystery", "report", "status"])
        #expect(result.events == [try HubEvent.decode(frames[0]), .unknown("mystery"), try HubEvent.decode(frames[1]), try HubEvent.decode(frames[5])])
        let call = try #require(hub.calls.first)
        #expect(hub.calls.count == 1 && call.isStream && call.method == "GET" && call.path == "/api/stream" && call.authorization == "Bearer " + F.client)
    }

    @Test func aRefusedStreamIsUnauthorisedWhateverTheStatus() async throws {
        let (hub, api) = try Self.setUp()
        for status in [401, 403] {
            hub.onStream { _ in EventStreamTests.script(status, [#"{"error":"Open a fresh dashboard invitation."}"#]) }
            let result = await Self.collect(api.events())
            #expect(result.events.isEmpty && result.failure == .unauthorized(status: status, message: "Open a fresh dashboard invitation."))
        }
        hub.onStream { _ in EventStreamTests.script(503, [#"{"error":"too many connections"}"#]) }
        #expect(await Self.collect(api.events()).failure == .http(status: 503, message: "too many connections"))
    }

    @Test func aBrokenConnectionEndsTheStreamWithItsError() async throws {
        let (hub, api) = try Self.setUp()
        let frames = try M.frames()
        hub.onStream { _ in EventStreamTests.script(200, ["data: " + frames[5] + "\n\n"], failure: .unreachable("The connection to the hub was lost.")) }
        let result = await Self.collect(api.events())
        #expect(result.events.map(\.type) == ["status"] && result.failure == .unreachable("The connection to the hub was lost."))
        // Each call is one attempt; reconnecting is calling again.
        _ = await Self.collect(api.events())
        #expect(hub.calls.count == 2 && hub.calls.allSatisfy(\.isStream))
    }

    @Test func lettingGoOfTheStreamClosesTheConnection() async throws {
        let (hub, api) = try Self.setUp()
        let frames = try M.frames()
        hub.onStream { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(EventStreamTests.head(200))
                continuation.yield(.data(Data(("data: " + frames[5] + "\n\n").utf8)))
                // …and then the connection stays open, as a live stream does.
            }
        }
        for try await event in api.events() {
            #expect(event.type == "status")
            break
        }
        #expect(await EventStreamTests.eventually { hub.streamCancels == 1 })

        // Cancelling the task that reads it does the same.
        let reader = Task { await Self.collect(api.events()) }
        #expect(await EventStreamTests.eventually { hub.calls.count == 2 })
        reader.cancel()
        let result = await reader.value
        #expect(result.events.count <= 1)
        #expect(await EventStreamTests.eventually { hub.streamCancels == 2 })
    }
}

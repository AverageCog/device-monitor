// The fixture hub is a child process, which only macOS can start.
#if os(macOS)
import Foundation
import Testing
@testable import DMCore

/// `LiveHubAPI` and `HubStore` against the real hub (`server.js`) behind real TLS, started through
/// `build/test/mobile-hub.js`: seven devices that report, a week of history, a saved price and
/// alerts. Needs Node and openssl, so it only runs when `DM_HUB_E2E` names the repository root:
///
///     DM_HUB_E2E=/path/to/device-monitor swift test --filter StoreE2ETests
@MainActor
@Suite(.enabled(if: E2EHub.repositoryRoot != nil, "set DM_HUB_E2E to the repository root"), .serialized, .timeLimit(.minutes(3)))
struct StoreE2ETests {
    @Test func aPairedStoreFollowsARealHub() async throws {
        let hub = try FixtureHub.start()
        let connect: @Sendable (PinnedSession.Policy) -> any PinnedTransport = { [anchor = hub.anchor] in
            PinnedSession(policy: $0, testingTrustAnchors: [anchor])
        }

        // Pair the way the app does: the invitation text, then POST /api/mobile/pair.
        let invitation = try Invitation.parse(hub.invitation)
        let enrollment = try await HubPairing.pair(
            invitation: invitation, name: "E2E Store", redeemPath: HubPairing.redeemPath, secondSecret: HubPairing.secondSecret, connect: connect)
        #expect(enrollment.pin == hub.pin && enrollment.origin.string == hub.origin && enrollment.name == "E2E Store")
        let credentials = InMemoryCredentialStore(enrollment)
        let client = HubClient(enrollment: enrollment, store: credentials, connect: connect)
        let api = LiveHubAPI(client: client)

        let notifier = NotifierProbe()
        let (preferences, _) = StoreFixtures.preferences()
        let store = HubStore(api: api, preferences: preferences, alertNotifier: notifier)
        store.start()
        try await eventually("the store is live", timeout: .seconds(15)) { store.connection == .live && store.hasSnapshot && store.activeTaskCount == 2 }

        // The fleet, in the order the fixture gave it.
        #expect(store.devices.map(\.id) == ["gaming", "spark", "mbp", "server", "studio", "nas", "htpc"])
        #expect(store.devices.map(\.displayName) == ["Gaming PC", "DGX Spark", "MacBook Pro", "Home Server", "Studio PC", "NAS", "Living Room PC"])
        #expect(store.offlineDevices.map(\.id) == ["htpc"] && store.counts == FleetCounts(online: 6, total: 7))
        #expect(store.device("studio")?.latest?.gpus.count == 2 && store.device("server")?.latest?.gpus.isEmpty == true && store.device("htpc")?.latest == nil)
        #expect(store.device("htpc")?.macs.isEmpty == false)
        #expect(store.versionLabel(for: try #require(store.device("studio"))) == "v1.2.30")       // the fixture publishes no update
        #expect(store.latestVersions.isEmpty)

        // What the stream does not carry was fetched alongside.
        #expect(store.info?.origin == hub.origin && store.info?.canShare == true && store.info?.canEnroll == false)
        #expect(store.energySettings == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD") && store.isEnergySettingsLoaded)
        #expect(store.alerts.isLoaded && store.alerts.priceSet && store.alerts.settings?.rules.map(\.type) == [.offline, .cpuTemp, .gpuTemp, .disk])

        // Samples arrive: the ten-minute series grows with every report, and the heartbeat ticks.
        let samples = store.series(for: "gaming").points.count
        try await eventually("reports and a heartbeat arrive", timeout: .seconds(10)) {
            store.series(for: "gaming").points.count >= samples + 2 && store.lastStatusAt != nil
        }
        #expect(store.series(for: "gaming").resolution == 2000 && store.series(for: "gaming").hasGPU && !store.series(for: "server").hasGPU)
        // The backup disk is over the default 90 % rule, and the living-room PC has been off for days.
        try await eventually("the alerts that fire at once are firing", timeout: .seconds(10)) {
            Set(store.alerts.active.map(\.device)).isSuperset(of: ["server", "htpc"])
        }
        #expect(store.alerts.active.first { $0.device == "server" }?.title == "Home Server: disk /mnt/backup is 95% full")

        // Rename: the hub announces it to everyone, this app included.
        let renamed = try await store.rename(device: "studio", name: "  Studio E2E  ")
        #expect(renamed?.name == "Studio E2E" && renamed?.renamed == true)
        try await eventually("the new name is announced") { store.device("studio")?.name == "Studio E2E" }

        // Reorder: at once here, then confirmed by the hub's own order event.
        let dragged = Array(store.onlineDevices.map(\.id).reversed())
        try await store.reorder(ids: dragged)
        #expect(store.devices.map(\.id) == dragged + ["htpc"])
        try await eventually("the hub has the order") { store.connection == .live }
        let stored = try await api.devices().sorted { ($0.order ?? 99) < ($1.order ?? 99) }.map(\.id)
        #expect(stored == dragged + ["htpc"])
        try await store.reorder(ids: dragged)                      // nothing moved: nothing asked

        // A card on a longer range is fed by the history endpoint.
        store.setRange(.hour, for: "gaming")
        try await eventually("the hour is in", timeout: .seconds(10)) { store.series(for: "gaming").resolution >= 10_000 && !store.series(for: "gaming").points.isEmpty }
        #expect(store.series(for: "gaming").points.count > 50 && store.range(for: "gaming") == .hour)

        // History and energy, as the other two screens ask for them.
        let now = Date().hubTime
        let history = try await store.loadHistory(device: "spark", from: now - 24 * 3600e3, to: now, points: 300)
        #expect(history.resolution == 288_000 && history.points.count > 200 && history.points.contains { $0.cpuMax != nil && $0.gpu != nil })
        #expect(await storeError { _ = try await store.loadHistory(device: "nobody", from: now - 1000, to: now, points: 10) } == .http(status: 404, message: "not found"))
        let bounds = (0...7).map { now - Double(7 - $0) * 86400e3 }
        let energy = try await store.loadEnergy(bounds: bounds)
        #expect(energy.bounds == bounds && energy.devices.count == 7 && energy.settings == store.energySettings)
        #expect((energy.devices.first { $0.id == "gaming" }?.wh ?? 0) > 1000 && energy.devices.first { $0.id == "gaming" }?.cost != nil)
        #expect(await storeError { _ = try await store.loadEnergy(bounds: [2, 1]) } == .http(status: 400, message: "bad bounds"))

        // A price saved elsewhere reaches the store as an energySettings event…
        let elsewhere = StreamListener(api)
        await elsewhere.wait(for: 1, "snapshot")
        let german = EnergySettings(region: "DE", rate: 0.39, currency: "EUR")
        #expect(try await api.saveEnergySettings(german) == german)
        try await eventually("the event is applied") { store.energySettings == german }
        await elsewhere.wait(for: 1, "energySettings")
        #expect(elsewhere.events("energySettings") == [.energySettings(german)])
        // …and one saved here is what the hub stored, time-of-use periods in order.
        let saved = try await store.saveEnergySettings(EnergySettings(
            region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 16, to: 21, rate: 0.42), TouPeriod(from: 0, to: 6.5, rate: 0.12346)]))
        #expect(saved.tou == [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)] && store.energySettings == saved)
        #expect(await storeError { _ = try await store.saveEnergySettings(EnergySettings(region: "nowhere", rate: 1, currency: "EUR")) } == .http(status: 400, message: "invalid settings"))

        // An alert fires on the hub and arrives here, with the hub's verdict that apps should announce it.
        let logged = store.alerts.events.count
        try hub.control("POST", "/alert?seconds=3")
        try await eventually("the alert arrives", timeout: .seconds(15)) { store.alerts.events.first?.title == "Gaming PC: disk D: is 97% full" }
        #expect(store.alerts.events.count == logged + 1 && store.alerts.active.contains { $0.device == "gaming" && $0.type == .disk })
        #expect(notifier.events.last?.title == "Gaming PC: disk D: is 97% full" && notifier.events.last?.state == .firing)
        try await eventually("the alert clears", timeout: .seconds(15)) { store.alerts.events.first?.state == .resolved }
        #expect(store.alerts.events.first?.title == "Gaming PC: disk space back under 90%" && !store.alerts.active.contains { $0.device == "gaming" })
        #expect(notifier.events.last?.state == .resolved && store.unseenAlertCount >= 2)

        // A test alert: the fixture hub delivers nowhere, but the apps are told.
        let announced = notifier.events.count
        #expect(try await store.sendTestAlert() == AlertTestResult())
        try await eventually("the test alert is announced") { notifier.events.count == announced + 1 }
        #expect(notifier.events.last?.test == true && store.alerts.events.first?.test == false)

        // Alert settings round-trip; an invalid rule is the hub's to refuse.
        var settings = try #require(store.alerts.settings)
        settings.notifyResolved = false
        settings.rules.append(AlertRule(type: .cpu, device: "gaming", threshold: 99, minutes: 30))
        try await store.saveAlerts(settings)
        #expect(store.alerts.settings?.rules.count == 5 && store.alerts.settings?.notifyResolved == false)
        settings.rules[0].minutes = 0
        #expect(await storeError { try await store.saveAlerts(settings) } == .http(status: 400, message: "invalid alert settings"))
        try await store.clearAlertLog()
        try await store.refreshAlerts()
        #expect(store.alerts.events.isEmpty && store.alerts.settings?.rules.count == 5)

        // What the hub refuses to do is an ordinary error, not a revocation.
        #expect(await storeError { try await store.wake(device: "htpc") } == .http(status: 403, message: "Host integrations disabled"))
        #expect(store.connection == .live)

        // Sharing, and who this app is to the hub.
        let link = try await store.createBrowserInvitation().absoluteString
        #expect(link.hasPrefix(hub.origin + "/unlock#join=") && HubIdentity.isValidSecret(String(link.dropFirst((hub.origin + "/unlock#join=").count))))
        let phones = try await store.loadMobileClients()
        #expect(phones.map(\.id) == [enrollment.id] && phones.first?.name == "E2E Store" && phones.first?.lastSeen != nil)
        #expect(try await store.loadRemoteStatus().installed == false)

        // Removing a device: the NAS stopped reporting long ago, so it stays gone.
        try await store.remove(device: "nas")
        try await eventually("the removal is announced") { store.device("nas") == nil && store.series["nas"] == nil }

        // Background and foreground.
        store.suspend()
        #expect(store.connection == .idle)
        try await eventually("nothing is left running") { store.activeTaskCount == 0 }
        store.resume()
        try await eventually("the store is live again", timeout: .seconds(15)) { store.connection == .live && store.devices.count == 6 }
        #expect(store.device("studio")?.name == "Studio E2E" && store.energySettings == saved)

        // Revoked on the hub: the stream is cut, the retry is refused, and the store stops for good.
        elsewhere.stop()
        try hub.control("POST", "/revoke-mobile")
        try await eventually("the store was refused", timeout: .seconds(20)) { store.connection == .unauthorized }
        #expect(!store.isRunning && store.lastError?.isUnauthorized == true)
        try await eventually("nothing is left running") { store.activeTaskCount == 0 }
        #expect(await storeError { _ = try await store.loadMobileClients() }?.isUnauthorized == true)
        await client.close()
    }
}

/// `build/test/mobile-hub.js` as a child process.
final class FixtureHub: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private struct Ready: Decodable { let origin: String; let ca: String; let invitation: String; let controlPort: Int; let pin: String }

    let origin: String
    /// A fresh iPhone / iPad invitation, as the hub shows it.
    let invitation: String
    let pin: String
    /// DER of the throwaway CA the hub's certificate chains to.
    let anchor: Data
    private let controlPort: Int
    private let process: Process

    /// Starts a hub on a port pair of its own in 8500–8599. Several engineers share the Mac, so
    /// a pair that is taken is skipped.
    static func start() throws -> FixtureHub {
        guard let root = E2EHub.repositoryRoot else { throw Failure(description: "DM_HUB_E2E is not set") }
        let first = Int(ProcessInfo.processInfo.processIdentifier) % 50
        var last: any Error = Failure(description: "no port tried")
        for attempt in 0..<6 {
            let port = 8500 + 2 * ((first + attempt * 7) % 50)
            do {
                return try FixtureHub(root: root, port: port)
            } catch {
                last = error
            }
        }
        throw last
    }

    private init(root: String, port: Int) throws {
        let process = Process(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root + "/build/test/mobile-hub.js", "--port", String(port), "--control", String(port + 1), "--interval", "1000"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            var line = Data()
            while !line.contains(0x0A) {
                let more = stdout.fileHandleForReading.availableData
                guard !more.isEmpty else { throw Failure(description: "the fixture hub did not start on port \(port); is node on PATH?") }
                line.append(more)
            }
            let ready = try JSONDecoder().decode(Ready.self, from: line.prefix { $0 != 0x0A })
            // ca.pem is one certificate.
            let pem = try String(contentsOfFile: ready.ca, encoding: .utf8)
            let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
            guard let anchor = Data(base64Encoded: base64) else { throw Failure(description: "the fixture hub's CA is unreadable") }
            self.anchor = anchor
            origin = ready.origin
            invitation = ready.invitation
            pin = ready.pin
            controlPort = ready.controlPort
        } catch {
            process.terminate()
            throw error
        }
        self.process = process
    }

    deinit {
        // SIGTERM is the hub's cue to stop and remove its temporary files.
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
    }

    /// Drives the fixture through its control endpoint on loopback.
    @discardableResult
    func control(_ method: String, _ path: String) throws -> String {
        let curl = Process(), output = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-sS", "--fail-with-body", "--max-time", "10", "-X", method, "http://127.0.0.1:\(controlPort)\(path)"]
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else { throw Failure(description: "\(method) \(path) failed: \(answer)") }
        return answer
    }
}
#endif

import Foundation
import Observation
import Testing
@testable import DMCore

/// The store over a scripted hub and a clock that only moves when the test moves it.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct HubStoreTests {
    typealias F = StoreFixtures

    static func isReconnecting(_ store: HubStore) -> Bool {
        if case .reconnecting = store.connection { true } else { false }
    }

    nonisolated static func history(_ points: [HistoryPoint], resolution: Double) -> HistoryResponse {
        HistoryResponse(from: 0, to: 1, resolution: resolution, points: points)
    }

    // MARK: Connecting

    @Test func startConnectsAndGoesLiveOnTheFirstEvent() async throws {
        let h = StoreHarness()
        #expect(h.store.connection == .idle && !h.store.isRunning && !h.store.hasSnapshot)
        h.store.start()
        #expect(h.store.connection == .connecting && h.store.isRunning)
        let connection = try await h.connection(0)
        await settle()
        #expect(h.store.connection == .connecting)                 // open, but nothing has arrived

        connection.send(.snapshot([
            F.device("b", name: "Beta", order: 1, online: false), F.device("a", name: "Alpha", order: 0), F.device("c", name: "Gamma", order: nil),
        ]))
        try await eventually("the store is live") { h.store.connection == .live }
        #expect(h.store.hasSnapshot && h.store.failedAttempts == 0 && h.store.lastError == nil && h.store.lastErrorText == nil)
        #expect(h.store.devices.map(\.id) == ["a", "b", "c"])
        #expect(h.store.onlineDevices.map(\.id) == ["a", "c"] && h.store.offlineDevices.map(\.id) == ["b"])
        #expect(h.store.counts == FleetCounts(online: 2, total: 3) && h.store.counts.text == "2 of 3 devices online")
        #expect(h.store.device("b")?.name == "Beta" && h.store.device("nobody") == nil)

        h.store.start()                                            // already running: nothing new
        await settle()
        #expect(h.hub.connections.count == 1)
        h.store.stop()
    }

    @Test func whatTheStreamDoesNotCarryIsAskedForAtTheStart() async throws {
        let h = StoreHarness()
        let rule = AlertRule(id: "0123456789ab", type: .offline, minutes: 10)
        let alerts = AlertsResponse(settings: AlertSettings(rules: [rule]), active: [ActiveAlert(ruleId: rule.id, type: .offline, device: "a")], events: [F.alert("e1", t: 1)], priceSet: true)
        h.hub.on {
            $0.latestVersion = { $0 == .windows ? "1.2.33" : nil }
            $0.energySettings = { EnergySettings(region: "DE", rate: 0.39, currency: "EUR") }
            $0.alerts = { alerts }
        }
        #expect(!h.store.isEnergySettingsLoaded && !h.store.alerts.isLoaded && h.store.info == nil)
        h.store.start()
        try await eventually("the extras are in") { h.store.activeTaskCount == 2 }
        // Before a single stream event: the dashboard asks as the page loads, too.
        #expect(h.store.connection == .connecting)
        #expect(h.hub.calls.sorted() == ["alerts", "energySettings", "info", "latestVersion mac", "latestVersion windows"])
        #expect(h.store.latestVersions == ["windows": "1.2.33"])                    // the 404 for mac leaves nothing
        #expect(h.store.energySettings?.region == "DE" && h.store.isEnergySettingsLoaded)
        #expect(h.store.alerts == AlertsState(alerts) && h.store.alerts.isLoaded && h.store.alerts.priceSet)
        #expect(h.store.info?.origin == "https://hub.test")

        // Going live on that same attempt asks for nothing twice.
        try await h.connection(0).send(.snapshot([]))
        try await eventually("the store is live") { h.store.connection == .live }
        await settle()
        #expect(h.hub.calls.count == 5)
        h.store.stop()
    }

    @Test func aRefusalWhileFetchingExtrasStopsTheStore() async throws {
        let h = StoreHarness()
        h.hub.on { $0.alerts = { throw F.refused(401, "Open a fresh dashboard invitation.") } }
        h.store.start()
        try await eventually("the store gave up") { h.store.connection == .unauthorized }
        #expect(h.store.lastError == .unauthorized(status: 401, message: "Open a fresh dashboard invitation.") && !h.store.isRunning)
        try await eventually("nothing is left running") { h.store.activeTaskCount == 0 }
    }

    // MARK: Reconnecting

    @Test func reconnectsThreeSecondsAfterTheStreamEnds() async throws {
        let h = StoreHarness()
        let first = try await h.goLive()
        first.finish()                                             // the hub ended the response
        try await eventually("the store noticed") { Self.isReconnecting(h.store) }
        #expect(h.store.connection == .reconnecting(since: F.now))
        #expect(h.store.lastError == .unreachable("The hub closed the live stream.") && h.store.lastErrorAt == F.now)
        #expect(h.store.lastErrorText == "The hub closed the live stream." && h.store.failedAttempts == 1)
        #expect(h.store.devices.count == 2 && h.store.hasSnapshot)   // what it knew stays on show

        await h.clock.waitForSleepers(2)                           // the wait, and the series timer
        h.clock.advance(by: 2999)
        await settle()
        #expect(h.hub.connections.count == 1)
        h.clock.advance(by: 1)
        let second = try await h.connection(1)
        #expect(h.store.connection == .reconnecting(since: F.now))  // until something arrives

        // This attempt cannot even connect.
        second.fail(.unreachable("Could not connect to the hub."))
        try await eventually("the second failure is counted") { h.store.failedAttempts == 2 }
        #expect(h.store.connection == .reconnecting(since: F.now))  // since the connection was lost, not since the last try
        #expect(h.store.lastError == .unreachable("Could not connect to the hub.") && h.store.lastErrorAt == F.now + 3000)
        #expect(h.store.lastError?.isConnectivityFailure == true)

        await h.clock.waitForSleepers(2)
        h.clock.advance(by: 3000)
        let third = try await h.connection(2)
        third.send(.snapshot([F.device("z")]))
        try await eventually("the store is live again") { h.store.connection == .live }
        #expect(h.store.failedAttempts == 0 && h.store.devices.map(\.id) == ["z"])
        #expect(h.store.lastError != nil)                          // kept for diagnostics
        h.store.stop()
    }

    @Test func extrasAreFetchedAgainOnceAReconnectIsLive() async throws {
        let h = StoreHarness()
        let first = try await h.goLive()
        #expect(h.hub.calls.count == 5)
        first.fail(.unreachable("The connection to the hub was lost."))
        try await eventually("the store noticed") { Self.isReconnecting(h.store) }
        await h.clock.waitForSleepers(2)
        h.clock.advance(by: 3000)
        let second = try await h.connection(1)
        await settle()
        #expect(h.hub.calls.count == 5)                            // not before the stream is back
        second.send(.status([:]))                                  // any event shows the stream is open
        try await eventually("the store is live") { h.store.connection == .live }
        #expect(h.store.lastStatusAt == F.now + 3000)
        try await eventually("everything was asked again") { h.hub.calls.count == 10 && h.store.activeTaskCount == 2 }
        #expect(h.hub.calls("alerts").count == 2 && h.hub.calls("energySettings").count == 2 && h.hub.calls("info").count == 2)
        #expect(h.hub.calls("latestVersion").count == 4)
        h.store.stop()
    }

    @Test func retryNowSkipsTheWait() async throws {
        let h = StoreHarness()
        let first = try await h.goLive()
        h.store.retryNow()                                         // live: nothing to retry
        await settle()
        #expect(h.hub.connections.count == 1 && !first.isClosed)

        first.finish()
        try await eventually("the store noticed") { Self.isReconnecting(h.store) }
        await h.clock.waitForSleepers(2)
        h.store.retryNow()
        let second = try await h.connection(1)                     // the clock has not moved
        #expect(h.clock.now == F.now && h.store.connection == .reconnecting(since: F.now))
        try await eventually("the old wait is gone") { h.clock.sleeperCount == 1 && h.store.activeTaskCount == 2 }
        second.send(.snapshot([]))
        try await eventually("the store is live") { h.store.connection == .live }
        h.store.stop()
    }

    // MARK: Unauthorised

    @Test func aRefusedStreamStopsTheStoreForGood() async throws {
        let h = StoreHarness()
        h.store.start()
        try await h.connection(0).fail(.unauthorized(status: 403, message: "Create this invitation on the hub."))
        try await eventually("the store gave up") { h.store.connection == .unauthorized }
        #expect(!h.store.isRunning && h.store.lastError?.isUnauthorized == true && h.store.lastErrorAt == F.now)
        try await eventually("nothing is left running") { h.store.activeTaskCount == 0 }
        #expect(h.clock.sleeperCount == 0)

        h.clock.advance(by: 60_000)
        h.store.retryNow()
        h.store.suspend()
        h.store.resume()
        await settle()
        #expect(h.hub.connections.count == 1 && h.store.connection == .unauthorized)

        // After pairing again, start() is the way back in.
        h.store.start()
        _ = try await h.connection(1)
        #expect(h.store.connection == .connecting && h.store.lastError == nil)
        h.store.stop()
    }

    @Test func anUnauthorisedAnswerToAnyRequestStopsTheStore() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        h.hub.on { $0.rename = { _, _ in throw F.refused(401, "Open a fresh dashboard invitation.") } }
        let error = await storeError { _ = try await h.store.rename(device: "a", name: "New") }
        #expect(error == .unauthorized(status: 401, message: "Open a fresh dashboard invitation."))
        #expect(h.store.connection == .unauthorized && !h.store.isRunning && h.store.lastError == error)
        try await eventually("the stream was closed") { connection.isClosed && h.store.activeTaskCount == 0 }
        #expect(h.clock.sleeperCount == 0)
    }

    @Test func aChartRequestThatIsRefusedStopsTheStoreToo() async throws {
        let h = StoreHarness()
        try await h.goLive()
        h.hub.on { $0.history = { _, _ in throw F.refused(401) } }
        h.store.setRange(.hour, for: "a")
        try await eventually("the store gave up") { h.store.connection == .unauthorized }
    }

    @Test func aRefusalOfOneOperationIsNotARevocation() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        h.hub.on { $0.wake = { _ in throw F.refused(403, "Host integrations disabled") } }
        #expect(await storeError { try await h.store.wake(device: "a") } == .http(status: 403, message: "Host integrations disabled"))
        #expect(h.store.connection == .live && h.store.isRunning && !connection.isClosed && h.store.lastError == nil)
        h.store.stop()
    }

    // MARK: Events

    @Test func everyCapturedEventReachesTheObservableState() async throws {
        let h = StoreHarness()
        let events = try ModelFixture.events()
        h.store.start()
        let connection = try await h.connection(0)
        try await eventually("the extras are in") { h.store.activeTaskCount == 2 }
        connection.send(events)
        try await eventually("all 33 frames are applied") { h.store.alerts.events.count == 9 && h.store.offlineDevices.map(\.id) == [ModelFixture.htpc] }

        #expect(h.store.devices.map(\.displayName) == ["dgx-station", "DESKTOP-7QK2M1P", "Sams-MacBook-Pro", "Lab PC", "nas", "htpc"])
        #expect(h.store.counts == FleetCounts(online: 5, total: 6))
        #expect(h.store.series(for: ModelFixture.removed) == .empty && h.store.series.count == 6)
        #expect(h.store.latestVersions == ["windows": "1.2.33"])
        #expect(h.store.versionLabel(for: try #require(h.store.device(ModelFixture.workstation))) == "v1.2.32 \u{2192} 1.2.33")
        #expect(h.store.energySettings?.currency == "EUR" && h.store.isEnergySettingsLoaded && h.store.alerts.priceSet)
        #expect(h.store.alerts.settings?.tempUnit == .fahrenheit && h.store.alerts.active.count == 4)
        #expect(h.store.lastStatusAt == F.now)
        #expect(h.notifier.events.map(\.id) == ["29c7b24da904", "6c4f538a06bb", "930c8515f336", "54eafba603c0", "33a0c5598368", "4b26e1060b39", "cd3c8d079a36", "f32790f355c1"])
        h.store.stop()
    }

    @Test func reportsAppendToTheSeriesAndOldSamplesFallOut() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive([F.device("a", order: 0, history: [F.point(F.now - 599_000), F.point(F.now - 2000)])])
        #expect(h.store.series(for: "a") == CardSeries(points: [F.point(F.now - 599_000), F.point(F.now - 2000)], resolution: 2000))
        #expect(h.store.series(for: "nobody") == .empty)

        h.clock.advance(by: 2000)
        connection.send(.report(id: "a", device: F.device("a", name: "Renamed meanwhile", order: 0), sample: F.point(F.now + 2000)))
        try await eventually("the sample is in") { h.store.series(for: "a").points.last?.t == F.now + 2000 }
        // The window is ten minutes back from the store's clock: the first sample has left it.
        #expect(h.store.series(for: "a").points.map(\.t) == [F.now - 2000, F.now + 2000])
        #expect(h.store.device("a")?.name == "Renamed meanwhile")
        h.store.stop()
    }

    @Test func statusEventsFlipOnlineFlagsAndMarkTheHeartbeat() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        #expect(h.store.lastStatusAt == nil)
        h.clock.advance(by: 3000)
        connection.send(.status(["a": false, "b": true]))
        try await eventually("a is offline") { h.store.offlineDevices.map(\.id) == ["a"] }
        #expect(h.store.onlineDevices.map(\.id) == ["b"] && h.store.counts == FleetCounts(online: 1, total: 2))
        #expect(h.store.lastStatusAt == F.now + 3000)
        h.store.stop()
    }

    @Test func onlyWhatChangedIsWritten() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive([F.device("a", order: 0), F.device("off", order: 1, online: false)])
        let online = Counter(), offline = Counter(), counts = Counter(), series = Counter(), heartbeat = Counter(), alerts = Counter()
        func watch() {
            withObservationTracking { _ = h.store.onlineDevices } onChange: { online.increment() }
            withObservationTracking { _ = h.store.offlineDevices } onChange: { offline.increment() }
            withObservationTracking { _ = h.store.counts } onChange: { counts.increment() }
            withObservationTracking { _ = h.store.series(for: "a") } onChange: { series.increment() }
            withObservationTracking { _ = h.store.lastStatusAt } onChange: { heartbeat.increment() }
            withObservationTracking { _ = h.store.alerts } onChange: { alerts.increment() }
        }
        watch()
        // A report from an online device concerns the cards, not the offline list or the summary.
        connection.send(.report(id: "a", device: F.device("a", name: "a", order: 0, appVersion: "1.2.33"), sample: F.point(F.now)))
        try await eventually("the report is applied") { h.store.series(for: "a").points.count == 1 }
        let afterTheReport: [Int] = [online.count, offline.count, counts.count, series.count, heartbeat.count, alerts.count]
        #expect(afterTheReport == [1, 0, 0, 1, 0, 0])

        withObservationTracking { _ = h.store.onlineDevices } onChange: { online.increment() }
        withObservationTracking { _ = h.store.series(for: "a") } onChange: { series.increment() }
        // A heartbeat that changes nobody's state only moves the heartbeat.
        connection.send(.status(["a": true, "off": false]))
        try await eventually("the status is applied") { h.store.lastStatusAt != nil }
        let afterTheHeartbeat: [Int] = [online.count, offline.count, counts.count, series.count, heartbeat.count, alerts.count]
        #expect(afterTheHeartbeat == [1, 0, 0, 1, 1, 0])
        h.store.stop()
    }

    // MARK: Card charts

    @Test func changingACardsRangeFetchesItsSeries() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive([F.device("a", order: 0, history: [F.point(F.now - 1000)])])
        #expect(h.hub.calls("history").isEmpty)                    // ten-minute cards are fed by the stream
        #expect(h.store.range(for: "a") == .tenMinutes)
        let answer = Gate<HistoryResponse>()
        h.hub.on { $0.history = { _, _ in try await answer.wait() } }

        h.store.setRange(.hour, for: "a")
        // Remembered and emptied at once; the request follows.
        #expect(h.store.range(for: "a") == .hour && h.preferences.cardRange(for: "a") == .hour)
        #expect(h.store.series(for: "a") == .empty)
        try await eventually("the series was asked for") { answer.arrivals == 1 }
        #expect(h.hub.calls("history") == ["history a 1h 360"])

        // A report that arrives meanwhile is drawn until the answer replaces it.
        connection.send(.report(id: "a", device: F.device("a", order: 0), sample: F.point(F.now)))
        try await eventually("the sample is in") { h.store.series(for: "a").points.count == 1 }
        answer.open(Self.history([F.point(1), F.point(2), F.point(3)], resolution: 10_000))
        try await eventually("the answer is in") { h.store.series(for: "a").points.count == 3 }
        #expect(h.store.series(for: "a").resolution == 10_000 && h.store.series(for: "a").gapInterval == 30_000)
        #expect(Preferences(defaults: h.defaults).cardRange(for: "a") == .hour)

        // Not a range a card can show.
        h.store.setRange(.week, for: "a")
        await settle()
        #expect(h.store.range(for: "a") == .hour && h.hub.calls("history").count == 1 && h.store.series(for: "a").points.count == 3)
        h.store.stop()
    }

    @Test func goingBackToTenMinutesAsksTheHubForTheRawSamples() async throws {
        let h = StoreHarness()
        h.preferences.setCardRange(.hour, for: "a")
        h.hub.on { $0.history = { _, range in Self.history([F.point(range == .hour ? 1 : 2)], resolution: range == .hour ? 10_000 : 2000) } }
        try await h.goLive([F.device("a", order: 0, history: [F.point(F.now - 1000)])])
        try await eventually("the hour is in") { h.store.series(for: "a").resolution == 10_000 }
        h.store.setRange(.tenMinutes, for: "a")
        try await eventually("ten minutes are in") { h.store.series(for: "a") == CardSeries(points: [F.point(2)], resolution: 2000) }
        #expect(h.hub.calls("history") == ["history a 1h 360", "history a 10m 360"])
        h.store.stop()
    }

    @Test func anAnswerForARangeTheCardHasLeftIsDropped() async throws {
        let h = StoreHarness()
        try await h.goLive()
        let hour = Gate<HistoryResponse>(), six = Gate<HistoryResponse>()
        h.hub.on { $0.history = { _, range in try await (range == .hour ? hour : six).wait() } }
        h.store.setRange(.hour, for: "a")
        try await eventually("the hour was asked for") { hour.arrivals == 1 }
        h.store.setRange(.sixHours, for: "a")
        try await eventually("six hours were asked for") { six.arrivals == 1 }

        hour.open(Self.history([F.point(1)], resolution: 10_000))   // `if (want !== rangeOf(id)) return`
        try await eventually("the late answer was dealt with") { h.store.activeTaskCount == 3 }
        #expect(h.store.series(for: "a") == .empty)
        six.open(Self.history([F.point(2)], resolution: 60_000))
        try await eventually("the right answer is in") { h.store.series(for: "a") == CardSeries(points: [F.point(2)], resolution: 60_000) }
        h.store.stop()
    }

    @Test func anAnswerOvertakenByANewerRequestIsDropped() async throws {
        let h = StoreHarness()
        try await h.goLive()
        let older = Gate<HistoryResponse>(), newer = Gate<HistoryResponse>(), asked = Counter()
        h.hub.on { $0.history = { _, _ in try await (asked.increment() == 1 ? older : newer).wait() } }
        h.store.setRange(.hour, for: "a")
        try await eventually("the first request is out") { older.arrivals == 1 }
        h.store.setRange(.hour, for: "a")                          // the same range, chosen again
        try await eventually("the second request is out") { newer.arrivals == 1 }

        newer.open(Self.history([F.point(2)], resolution: 10_000))
        try await eventually("the newer answer is in") { h.store.series(for: "a").points == [F.point(2)] }
        older.open(Self.history([F.point(1)], resolution: 10_000))
        try await h.idle()
        #expect(h.store.series(for: "a").points == [F.point(2)])
        h.store.stop()
    }

    @Test func anAnswerForARemovedDeviceIsDropped() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let answer = Gate<HistoryResponse>()
        h.hub.on { $0.history = { _, _ in try await answer.wait() } }
        h.store.setRange(.hour, for: "a")
        try await eventually("the series was asked for") { answer.arrivals == 1 }
        connection.send(.removed("a"))
        try await eventually("a is gone") { h.store.device("a") == nil }
        answer.open(Self.history([F.point(1)], resolution: 10_000))
        try await h.idle()
        #expect(h.store.series["a"] == nil && h.store.series.keys.sorted() == ["b"])
        h.store.stop()
    }

    @Test func aFailedChartRequestLeavesTheChartAlone() async throws {
        let h = StoreHarness()
        h.preferences.setCardRange(.hour, for: "a")
        h.hub.on { $0.history = { _, _ in Self.history([F.point(1)], resolution: 10_000) } }
        try await h.goLive()
        try await eventually("the hour is in") { h.store.series(for: "a").points == [F.point(1)] }

        // The refresh fails: loadSeries swallows it and the card keeps what it shows.
        h.hub.on { $0.history = { _, _ in throw HubError.unreachable("The hub did not answer in time.") } }
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: 120_000)
        try await eventually("the refresh was tried") { h.hub.calls("history").count == 2 }
        try await h.idle()
        #expect(h.store.series(for: "a").points == [F.point(1)] && h.store.connection == .live)
        h.store.stop()
    }

    @Test func longRangesAreFetchedAfterASnapshotAndEveryTwoMinutes() async throws {
        let h = StoreHarness()
        h.preferences.setCardRange(.sixHours, for: "b")
        h.hub.on { $0.history = { _, _ in Self.history([F.point(1)], resolution: 60_000) } }
        let fleet = [F.device("a", order: 0, history: [F.point(F.now - 4000)]), F.device("b", order: 1, history: [F.point(F.now - 4000)])]
        let first = try await h.goLive(fleet)
        // loadAllSeries(true): only the card that is not on ten minutes.
        try await eventually("b's series is in") { h.store.series(for: "b") == CardSeries(points: [F.point(1)], resolution: 60_000) }
        #expect(h.hub.calls("history") == ["history b 6h 360"])
        #expect(h.store.series(for: "a") == CardSeries(points: [F.point(F.now - 4000)], resolution: 2000))   // from the snapshot

        await h.clock.waitForSleepers(1)
        h.clock.advance(by: 119_999)
        await settle()
        #expect(h.hub.calls("history").count == 1)
        h.clock.advance(by: 1)
        try await eventually("the refresh came") { h.hub.calls("history") == ["history b 6h 360", "history b 6h 360"] }
        try await h.idle()

        // Not while the stream is down…
        first.finish()
        try await eventually("the store noticed") { Self.isReconnecting(h.store) }
        await h.clock.waitForSleepers(2)
        h.clock.advance(by: 120_000)
        let second = try await h.connection(1)
        await settle()
        #expect(h.hub.calls("history").count == 2)
        // …because the snapshot that ends the outage brings it anyway.
        second.send(.snapshot(fleet))
        try await eventually("the series was fetched again") { h.hub.calls("history").count == 3 }
        h.store.stop()
    }

    // MARK: Actions

    @Test func reorderAppliesAtOnceAndTellsTheHubOnlyWhenSomethingMoved() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive([
            F.device("a", name: "A", order: 0), F.device("b", name: "B", order: 1), F.device("off", name: "Off", order: 2, online: false),
            F.device("c", name: "C", order: 3),
        ])
        let sent = Gate<Bool>()
        h.hub.on { $0.setOrder = { _ in _ = try await sent.wait() } }
        let reorder = Task { try await h.store.reorder(ids: ["c", "a", "b"]) }
        try await eventually("the hub was told") { sent.arrivals == 1 }
        // Before the hub has answered: the new order is already on show.
        #expect(h.store.devices.map(\.id) == ["c", "a", "b", "off"] && h.store.devices.map(\.order) == [0, 1, 2, 3])
        #expect(h.store.onlineDevices.map(\.id) == ["c", "a", "b"])
        // The offline device has no card to drag; it goes after the visible ones.
        #expect(h.hub.calls("order") == ["order c,a,b,off"])
        sent.open(true)
        try await reorder.value

        try await h.store.reorder(ids: ["c", "a", "b"])            // nothing moved: `if (changed)`
        #expect(h.hub.calls("order").count == 1)

        // A failure is the caller's to show; the order stays as the user left it.
        h.hub.on { $0.setOrder = { _ in throw HubError.unreachable("The hub did not answer in time.") } }
        #expect(await storeError { try await h.store.reorder(ids: ["b", "c", "a"]) } == .unreachable("The hub did not answer in time."))
        #expect(h.store.devices.map(\.id) == ["b", "c", "a", "off"] && h.store.connection == .live)

        // The hub's word is final.
        connection.send(.order(["a": 0, "b": 1, "c": 2, "off": 3]))
        try await eventually("the hub's order is applied") { h.store.devices.map(\.id) == ["a", "b", "c", "off"] }
        h.store.stop()
    }

    @Test func actionsCallTheHubAndLeaveTheOutcomeToTheStream() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let renamed = try await h.store.rename(device: "a", name: "Office")
        #expect(renamed?.name == "Office")
        #expect(h.store.device("a")?.name == "a")                  // until the hub announces it, as on any dashboard
        connection.send(.device(F.device("a", name: "Office", order: 0)))
        try await eventually("the new name is announced") { h.store.device("a")?.name == "Office" }
        #expect(try await h.store.rename(device: "a", name: "") == nil)   // `if (name)`: not sent

        try await h.store.remove(device: "b")
        #expect(h.store.device("b") != nil)
        connection.send(.removed("b"))
        try await eventually("b is gone") { h.store.devices.map(\.id) == ["a"] }

        try await h.store.wake(device: "a")
        #expect(try await h.store.createBrowserInvitation().absoluteString == "https://hub.test/unlock#join=" + String(repeating: "c", count: 43))
        #expect(try await h.store.loadHistory(device: "a", from: 1000, to: 5000, points: 300) == HistoryResponse(from: 1000, to: 5000))
        _ = try await h.store.loadRemoteStatus()
        _ = try await h.store.loadMobileClients()
        #expect(Array(h.hub.calls.suffix(7)) == ["rename a Office", "remove b", "wake a", "invitation", "window a 1000 5000 300", "remoteStatus", "mobileClients"])
        h.store.stop()
    }

    @Test func everyActionThrowsAHubError() async throws {
        let h = StoreHarness()
        try await h.goLive()
        let refused = HubError.http(status: 409, message: "no")
        h.hub.on {
            $0.rename = { _, _ in throw refused }
            $0.remove = { _ in throw refused }
            $0.setOrder = { _ in throw refused }
            $0.wake = { _ in throw refused }
            $0.invitation = { throw refused }
            $0.window = { _, _, _, _ in throw refused }
            $0.energy = { _ in throw refused }
            $0.energySettings = { throw refused }
            $0.saveEnergySettings = { _ in throw refused }
            $0.alerts = { throw refused }
            $0.saveAlerts = { _ in throw refused }
            $0.testAlert = { throw refused }
            $0.clearAlertLog = { throw refused }
            $0.remoteStatus = { throw refused }
            $0.mobileClients = { throw refused }
            $0.info = { throw refused }
            $0.latestVersion = { _ in throw refused }
        }
        let store = h.store
        let failures: [HubError?] = [
            await storeError { _ = try await store.rename(device: "a", name: "x") }, await storeError { try await store.remove(device: "a") },
            await storeError { try await store.reorder(ids: ["b", "a"]) }, await storeError { try await store.wake(device: "a") },
            await storeError { _ = try await store.createBrowserInvitation() }, await storeError { _ = try await store.loadHistory(device: "a", from: 0, to: 1, points: 10) },
            await storeError { _ = try await store.loadEnergy(bounds: [0, 1]) }, await storeError { try await store.refreshEnergySettings() },
            await storeError { _ = try await store.saveEnergySettings(EnergySettings(region: "DE", rate: 1, currency: "EUR")) },
            await storeError { try await store.refreshAlerts() }, await storeError { try await store.saveAlerts(AlertSettings()) },
            await storeError { _ = try await store.sendTestAlert() }, await storeError { try await store.clearAlertLog() },
            await storeError { _ = try await store.loadRemoteStatus() }, await storeError { _ = try await store.loadMobileClients() },
            await storeError { _ = try await store.refreshInfo() }, await storeError { try await store.refreshLatestVersions() },
        ]
        #expect(failures == Array(repeating: Optional(refused), count: 17))
        #expect(store.connection == .live)

        // Whatever an implementation throws comes out as a HubError.
        h.hub.on {
            $0.wake = { _ in throw URLError(.timedOut) }
            $0.remove = { _ in throw CancellationError() }
        }
        #expect(await storeError { try await store.wake(device: "a") } == .unreachable("The hub did not answer in time."))
        #expect(await storeError { try await store.remove(device: "a") } == .cancelled)
        store.stop()
    }

    @Test func versionLabelsFollowWhatTheHubPublished() async throws {
        let h = StoreHarness()
        h.hub.on { $0.latestVersion = { $0 == .mac ? "1.2.33" : nil } }
        let connection = try await h.goLive([
            F.device("mac", order: 0, platform: "macos", appVersion: "1.2.30"), F.device("win", order: 1, platform: "windows", appVersion: "1.2.32"),
            F.device("linux", order: 2, platform: "linux"),
        ])
        let label = { (id: String) in h.store.device(id).flatMap(h.store.versionLabel(for:)) }
        #expect(h.store.latestVersions == ["mac": "1.2.33"])
        #expect(label("mac") == "v1.2.30 \u{2192} 1.2.33" && label("win") == "v1.2.32" && label("linux") == nil)
        connection.send(.update(platform: "windows", version: "1.2.33"))
        try await eventually("the update is announced") { label("win") == "v1.2.32 \u{2192} 1.2.33" }
        h.store.stop()
    }

    // MARK: Energy

    @Test func theSavedPriceFollowsLoadsSavesAndEvents() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        #expect(h.store.energySettings == nil && h.store.isEnergySettingsLoaded)   // asked at the start: none saved

        let german = EnergySettings(region: "DE", rate: 0.39, currency: "EUR")
        h.hub.on { $0.energy = { EnergyResponse(bounds: $0, settings: german, devices: [UsageSummary(id: "a", wh: 12)]) } }
        let response = try await h.store.loadEnergy(bounds: [1000, 2000, 3000])
        #expect(response.devices.first?.wh == 12 && h.hub.calls("energy") == ["energy 1000,2000,3000"])
        #expect(h.store.energySettings == german && h.store.alerts.priceSet)        // loadAdv: energy.saved = r.settings

        // A save shows what the hub stored, which may be rounded.
        h.hub.on { $0.saveEnergySettings = { EnergySettings(region: $0.region, rate: 0.3, currency: $0.currency) } }
        let saved = try await h.store.saveEnergySettings(EnergySettings(region: "custom", rate: 0.29999, currency: "EUR"))
        #expect(saved.rate == 0.3 && h.store.energySettings == saved)

        connection.send(.energySettings(EnergySettings(region: "US-CA", rate: 0.316, currency: "USD")))
        try await eventually("the event is applied") { h.store.energySettings?.region == "US-CA" }

        h.hub.on { $0.energy = { EnergyResponse(bounds: $0) } }
        _ = try await h.store.loadEnergy(bounds: [1, 2])
        #expect(h.store.energySettings == nil && !h.store.alerts.priceSet)

        h.hub.on { $0.saveEnergySettings = { _ in throw HubError.http(status: 400, message: "invalid settings") } }
        #expect(await storeError { _ = try await h.store.saveEnergySettings(german) } == .http(status: 400, message: "invalid settings"))
        #expect(h.store.energySettings == nil)
        h.store.stop()
    }

    @Test func anEnergyAnswerDoesNotPutAnOlderPriceBack() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let answer = Gate<EnergyResponse>()
        h.hub.on { $0.energy = { _ in try await answer.wait() } }
        let load = Task { try await h.store.loadEnergy(bounds: [1, 2]) }
        try await eventually("the request is out") { answer.arrivals == 1 }
        let newer = EnergySettings(region: "DE", rate: 0.39, currency: "EUR")
        connection.send(.energySettings(newer))
        try await eventually("the event is applied") { h.store.energySettings == newer }
        answer.open(EnergyResponse(bounds: [1, 2], settings: nil))  // what the hub had before the save
        #expect(try await load.value.settings == nil)
        #expect(h.store.energySettings == newer)
        h.store.stop()
    }

    // MARK: Alerts

    @Test func alertsAreLoadedKeptCurrentAndHandedToTheNotifier() async throws {
        let h = StoreHarness()
        let rule = AlertRule(id: "0123456789ab", type: .cpu, threshold: 90, minutes: 0)
        let loaded = AlertsResponse(
            settings: AlertSettings(rules: [rule]), active: [ActiveAlert(ruleId: rule.id, type: .cpu, device: "a")],
            events: [F.alert("e2", t: 2000), F.alert("e1", t: 1000)])
        h.hub.on { $0.alerts = { loaded } }
        let connection = try await h.goLive()
        #expect(h.store.alerts == AlertsState(loaded) && h.store.unseenAlertCount == 2)

        // Fired, and the hub wants it announced.
        let fired = F.alert("e3", t: 3000)
        connection.send(.alert(event: fired, notify: true, active: []))
        try await eventually("the alert is logged") { h.store.alerts.events.first?.id == "e3" }
        #expect(h.store.alerts.active.isEmpty && h.notifier.events == [fired] && h.store.unseenAlertCount == 3)

        // Resolved, and the hub was told not to announce those; then a test alert, announced but not logged.
        let test = F.alert("t1", t: 4500, test: true)
        connection.send([.alert(event: F.alert("e4", t: 4000, firing: false), notify: false, active: []), .alert(event: test, notify: true, active: [])])
        try await eventually("the test alert is announced") { h.notifier.events.count == 2 }
        #expect(h.notifier.events.last == test && h.store.alerts.events.map(\.id) == ["e4", "e3", "e2", "e1"])

        h.store.markAlertsSeen()
        #expect(h.store.unseenAlertCount == 0 && h.preferences.lastSeenAlertID == "e4" && h.preferences.lastSeenAlertTime == 4000)
        connection.send(.alert(event: F.alert("e5", t: 5000), notify: false, active: []))
        try await eventually("the next alert is logged") { h.store.alerts.events.count == 5 }
        #expect(h.store.unseenAlertCount == 1)

        connection.send(.alerts(settings: AlertSettings(rules: [], tempUnit: .fahrenheit), active: [ActiveAlert(ruleId: rule.id, type: .cpu, device: "b")]))
        try await eventually("the settings are announced") { h.store.alerts.settings?.tempUnit == .fahrenheit }
        #expect(h.store.alerts.active.map(\.device) == ["b"] && h.store.alerts.events.count == 5)

        // Saving shows what the hub stored and what fires under it.
        h.hub.on { $0.saveAlerts = { AlertsUpdate(settings: $0, active: [ActiveAlert(ruleId: "feedfacecafe", type: .disk, device: "c")]) } }
        try await h.store.saveAlerts(AlertSettings(rules: [rule], notifyResolved: false))
        #expect(h.store.alerts.settings == AlertSettings(rules: [rule], notifyResolved: false) && h.store.alerts.active.map(\.device) == ["c"])
        h.hub.on { $0.saveAlerts = { _ in throw HubError.http(status: 400, message: "invalid alert settings") } }
        #expect(await storeError { try await h.store.saveAlerts(AlertSettings()) } == .http(status: 400, message: "invalid alert settings"))
        #expect(h.store.alerts.settings?.rules == [rule])

        h.hub.on { $0.testAlert = { AlertTestResult(ntfy: .init(ok: false, error: "HTTP 404")) } }
        #expect(try await h.store.sendTestAlert() == AlertTestResult(ntfy: .init(ok: false, error: "HTTP 404")))

        try await h.store.clearAlertLog()
        #expect(h.store.alerts.events.isEmpty && h.store.unseenAlertCount == 0 && h.store.alerts.settings != nil)

        // The entry last seen is no longer in the log: what is newer than it counts.
        h.hub.on { $0.alerts = { AlertsResponse(events: [F.alert("e9", t: 9000), F.alert("e3", t: 3000)]) } }
        try await h.store.refreshAlerts()
        #expect(h.store.alerts.events.map(\.id) == ["e9", "e3"] && h.store.unseenAlertCount == 1)

        // The notifier can be installed later, or taken away.
        let late = NotifierProbe()
        h.store.alertNotifier = late
        connection.send(.alert(event: F.alert("e10", t: 10_000), notify: true, active: []))
        try await eventually("the new notifier is used") { late.events.map(\.id) == ["e10"] }
        #expect(h.notifier.events.count == 2)
        h.store.stop()
    }

    @Test func nothingHasBeenSeenUntilTheUserLooks() async throws {
        let h = StoreHarness()
        h.hub.on { $0.alerts = { AlertsResponse(events: [F.alert("b", t: 2), F.alert("a", t: 1)]) } }
        try await h.goLive()
        #expect(h.store.unseenAlertCount == 2)
        h.store.markAlertsSeen()
        #expect(h.store.unseenAlertCount == 0)
        // A store without alerts has nothing to mark.
        let empty = StoreHarness()
        empty.store.markAlertsSeen()
        #expect(empty.preferences.lastSeenAlertID == nil && empty.store.unseenAlertCount == 0)
        h.store.stop()
    }

    @Test func anAlertThatArrivesDuringARefreshIsNotLost() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let stale = Gate<AlertsResponse>(), asked = Counter()
        let live = F.alert("live", t: 9)
        h.hub.on {
            $0.alerts = {
                if asked.increment() == 1 { return try await stale.wait() }
                return AlertsResponse(events: [live])
            }
        }
        let refresh = Task { try await h.store.refreshAlerts() }
        try await eventually("the request is out") { stale.arrivals == 1 }
        connection.send(.alert(event: live, notify: false, active: []))
        try await eventually("the alert is logged") { h.store.alerts.events == [live] }
        stale.open(AlertsResponse())                               // put together before the alert fired
        try await refresh.value
        // The store asked again rather than show a log without it.
        #expect(asked.count == 2 && h.store.alerts.events == [live] && h.store.alerts.isLoaded)
        h.store.stop()
    }

    // MARK: Stopping, suspending, going away

    @Test func stopEndsEverythingTheStoreHadRunning() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let pending = Gate<HistoryResponse>()
        h.hub.on { $0.history = { _, _ in try await pending.wait() } }
        h.store.setRange(.hour, for: "a")
        try await eventually("a request is in flight") { pending.arrivals == 1 }
        #expect(h.store.activeTaskCount == 3 && h.clock.sleeperCount == 1)

        h.store.stop()
        #expect(h.store.connection == .idle && !h.store.isRunning)
        try await eventually("nothing is left running") { h.store.activeTaskCount == 0 && connection.isClosed }
        #expect(h.clock.sleeperCount == 0)
        #expect(h.store.devices.count == 2)                        // what it knew stays readable

        h.clock.advance(by: 600_000)
        await settle()
        #expect(h.hub.connections.count == 1 && h.hub.calls("history").count == 1)

        // And it starts again.
        h.store.start()
        try await h.connection(1).send(.snapshot([]))
        try await eventually("the store is live again") { h.store.connection == .live && h.store.devices.isEmpty }
        h.store.stop()
        h.store.stop()
        try await eventually("nothing is left running") { h.store.activeTaskCount == 0 }
    }

    @Test func stoppingWhileWaitingToReconnectCancelsTheWait() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        connection.fail(.unreachable("The connection to the hub was lost."))
        try await eventually("the store noticed") { Self.isReconnecting(h.store) }
        await h.clock.waitForSleepers(2)
        h.store.stop()
        try await eventually("nothing is left running") { h.store.activeTaskCount == 0 }
        #expect(h.clock.sleeperCount == 0 && h.store.connection == .idle)
        h.clock.advance(by: 10_000)
        await settle()
        #expect(h.hub.connections.count == 1)
    }

    @Test func suspendClosesTheStreamAndResumeReconnectsAtOnce() async throws {
        let h = StoreHarness()
        let first = try await h.goLive()
        h.store.suspend()
        #expect(h.store.connection == .idle && h.store.isRunning && h.store.isSuspended)
        try await eventually("nothing is left running") { first.isClosed && h.store.activeTaskCount == 0 }
        #expect(h.clock.sleeperCount == 0)

        h.clock.advance(by: 3_600_000)                             // an hour in the background
        h.store.suspend()
        h.store.retryNow()
        await settle()
        #expect(h.hub.connections.count == 1)

        h.store.resume()
        #expect(h.store.connection == .reconnecting(since: F.now + 3_600_000) && !h.store.isSuspended)
        let second = try await h.connection(1)                     // no three-second wait
        second.send(.snapshot([F.device("a")]))
        try await eventually("the store is live") { h.store.connection == .live }
        // Alerts may have fired meanwhile, a price may have been saved.
        try await eventually("the extras were asked again") { h.hub.calls("alerts").count == 2 && h.hub.calls("energySettings").count == 2 }

        h.store.resume()                                           // not suspended: nothing
        await settle()
        #expect(h.hub.connections.count == 2)
        h.store.stop()
    }

    @Test func resumingBeforeAnythingEverArrivedIsStillConnecting() async throws {
        let h = StoreHarness()
        h.store.suspend()
        h.store.resume()                                           // not running: nothing
        #expect(h.store.connection == .idle && !h.store.isSuspended && h.hub.connections.isEmpty)
        h.store.start()
        _ = try await h.connection(0)
        h.store.suspend()
        h.store.resume()
        #expect(h.store.connection == .connecting)
        _ = try await h.connection(1)
        h.store.stop()
        #expect(!h.store.isSuspended)
    }

    @Test func aStoreThatIsDroppedTakesItsConnectionWithIt() async throws {
        let hub = ScriptedHub(), clock = ManualHubClock(now: F.now)
        var store: HubStore? = HubStore(api: hub, preferences: F.preferences().0, clock: clock)
        let dropped = WeakReference(store)
        store?.start()
        try await eventually("the stream is open") { hub.connections.count == 1 }
        hub.connections[0].send(.snapshot([F.device("a")]))
        try await eventually("the store is live") { store?.connection == .live && store?.activeTaskCount == 2 }
        #expect(clock.sleeperCount == 1)

        store = nil                                                // without stop()
        try await eventually("the store is gone") { dropped.object == nil }
        try await eventually("its stream and its timer went with it") { hub.connections[0].isClosed && clock.sleeperCount == 0 }
    }

    // MARK: Unpairing

    @Test func unpairStopsFirstAndStaysStopped() async throws {
        let h = StoreHarness()
        let connection = try await h.goLive()
        let answer = Gate<Bool>()
        h.hub.on { $0.unpairSelf = { _ = try await answer.wait() } }
        let unpair = Task { try await h.store.unpair() }
        try await eventually("the hub is being told") { answer.arrivals == 1 }
        // Its own stream is closed before the hub can close it and make that look like an outage.
        #expect(h.store.connection == .idle && !h.store.isRunning)
        try await eventually("the stream is closed") { connection.isClosed }
        answer.open(true)
        try await unpair.value
        #expect(h.store.connection == .idle && !h.store.isRunning && h.hub.calls("unpairSelf").count == 1)
        await settle()
        #expect(h.hub.connections.count == 1)
    }

    @Test func aFailedUnpairLeavesTheStoreRunning() async throws {
        let h = StoreHarness()
        try await h.goLive()
        h.hub.on { $0.unpairSelf = { throw HubError.unreachable("Could not connect to the hub.") } }
        #expect(await storeError { try await h.store.unpair() } == .unreachable("Could not connect to the hub."))
        #expect(h.store.isRunning && h.store.connection == .connecting)
        try await h.connection(1).send(.snapshot([]))
        try await eventually("the store is live again") { h.store.connection == .live }

        // A hub that has already forgotten this phone: that is what was asked for.
        h.hub.on { $0.unpairSelf = { throw F.refused(401) } }
        try await h.store.unpair()
        #expect(h.store.connection == .idle && !h.store.isRunning)

        // A store that was never started stays stopped when the hub cannot be told.
        let idle = StoreHarness()
        idle.hub.on { $0.unpairSelf = { throw HubError.unreachable("Could not connect to the hub.") } }
        #expect(await storeError { try await idle.store.unpair() } != nil)
        #expect(idle.store.connection == .idle && idle.hub.connections.isEmpty)
    }
}

import Foundation
import Testing
@testable import DMCore

/// The event reducer against the frames captured from a real hub (`Fixtures/models/sse-frames.json`).
@Suite struct HubStateTests {
    typealias M = ModelFixture

    static let tenMinutes: @Sendable (String) -> HistoryRange = { _ in .tenMinutes }
    /// Shortly after the last sample of the captured snapshot.
    static let snapshotTime: Double = 1_795_213_882_000

    /// The state after the captured snapshot.
    static func snapshot(range: (String) -> HistoryRange = tenMinutes) throws -> (state: HubState, events: [HubEvent]) {
        let events = try M.events()
        var state = HubState()
        state.apply(events[0], now: snapshotTime, range: range)
        return (state, events)
    }

    static func event(_ events: [HubEvent], _ index: Int, is type: String, sourceLocation: SourceLocation = #_sourceLocation) -> HubEvent {
        #expect(events[index].type == type, sourceLocation: sourceLocation)
        return events[index]
    }

    // MARK: snapshot

    @Test func snapshotReplacesDevicesAndSeedsTenMinuteSeries() throws {
        let events = try M.events()
        var state = HubState(
            devices: [StoreFixtures.device("stale")], series: ["stale": CardSeries(points: [StoreFixtures.point(1)])],
            latestVersions: ["windows": "1.2.33"], energySettings: EnergySettings(region: "DE", rate: 0.39, currency: "EUR"))
        // One card is on a longer range: its samples come from a request, not from the snapshot.
        let effects = state.apply(Self.event(events, 0, is: "snapshot"), now: Self.snapshotTime) { $0 == M.dgx ? .hour : .tenMinutes }

        #expect(effects == [.reloadLongSeries])
        #expect(state.devices.map(\.id) == [M.workstation, M.dgx, M.macbook, M.nas, M.lab, M.htpc, M.removed])
        #expect(state.device("stale") == nil && state.series["stale"] == nil)
        #expect(state.series.keys.sorted() == [M.workstation, M.macbook, M.nas, M.lab, M.htpc, M.removed].sorted())
        let series = try #require(state.series[M.workstation])
        #expect(series.resolution == 2000)
        #expect(series.points.map(\.t) == stride(from: 1_795_213_867_000 as Double, through: 1_795_213_881_000, by: 2000).map { $0 })
        #expect(state.series[M.htpc]?.points.count == 1)
        // Samples live in `series` alone.
        #expect(state.devices.allSatisfy { $0.history.isEmpty })
        #expect(state.device(M.workstation)?.latest?.cpu.usage != nil)
        // A snapshot says nothing about versions, prices or alerts.
        #expect(state.latestVersions == ["windows": "1.2.33"])
        #expect(state.energySettings?.region == "DE")
    }

    @Test func aLaterSnapshotStartsOver() throws {
        var (state, _) = try Self.snapshot()
        let effects = state.apply(.snapshot([StoreFixtures.device("only", history: [StoreFixtures.point(5)])]), now: 10, range: Self.tenMinutes)
        #expect(effects == [.reloadLongSeries])
        #expect(state.devices.map(\.id) == ["only"])
        #expect(state.series == ["only": CardSeries(points: [StoreFixtures.point(5)], resolution: 2000)])
    }

    @Test func aSnapshotNamingADeviceTwiceKeepsTheLastWord() {
        var state = HubState()
        state.apply(.snapshot([StoreFixtures.device("a", name: "first"), StoreFixtures.device("b"), StoreFixtures.device("a", name: "second")]), now: 0, range: Self.tenMinutes)
        #expect(state.devices.map(\.id) == ["a", "b"])
        #expect(state.device("a")?.name == "second")
    }

    // MARK: report

    @Test func reportAppendsTheSampleAndReplacesTheDevice() throws {
        var (state, events) = try Self.snapshot()
        let report = Self.event(events, 1, is: "report")
        guard case .report(let id, let device, let sample) = report else { return }
        #expect(id == M.workstation && device.history.isEmpty && sample.t == 1_795_213_883_000)
        let before = try #require(state.device(M.workstation))

        let effects = state.apply(report, now: sample.t + 300, range: Self.tenMinutes)
        #expect(effects.isEmpty)
        let series = try #require(state.series[M.workstation])
        #expect(series.points.count == 9 && series.points.last == sample && series.resolution == 2000)
        let after = try #require(state.device(M.workstation))
        #expect(after == device)
        #expect(after.latest != before.latest && after.lastSeen == 1_795_213_883_000)
        // It keeps its place among the others, and nobody else's samples move.
        #expect(state.devices.map(\.id) == [M.workstation, M.dgx, M.macbook, M.nas, M.lab, M.htpc, M.removed])
        #expect(state.series[M.dgx]?.points.count == 8)
    }

    @Test func reportTrimsTheSeriesToTheCardsWindow() throws {
        let (snapshot, events) = try Self.snapshot()
        let report = events[1]
        guard case .report(_, _, let sample) = report else { return }

        // Ten minutes after the fourth sample, the first three have left a ten-minute window.
        var state = snapshot
        state.apply(report, now: 1_795_213_873_000 + 600_000, range: Self.tenMinutes)
        #expect(state.series[M.workstation]?.points.map(\.t) == [1_795_213_873_000, 1_795_213_875_000, 1_795_213_877_000, 1_795_213_879_000, 1_795_213_881_000, sample.t])

        // The same moment on a card that shows an hour: nothing is old enough to go.
        state = snapshot
        state.apply(report, now: 1_795_213_873_000 + 600_000) { _ in .hour }
        #expect(state.series[M.workstation]?.points.count == 9)

        // A sample exactly on the edge of the window stays (`points[0].t < cutoff` goes).
        state = snapshot
        state.apply(report, now: 1_795_213_871_000 + 600_000, range: Self.tenMinutes)
        #expect(state.series[M.workstation]?.points.first?.t == 1_795_213_871_000)

        // A clock far ahead of the hub's: everything is older than the window, the new sample too.
        state = snapshot
        state.apply(report, now: sample.t + 601_000, range: Self.tenMinutes)
        #expect(state.series[M.workstation]?.points.isEmpty == true)
    }

    @Test func reportFromAnUnknownDeviceAddsItLast() throws {
        var state = HubState()
        state.apply(.snapshot([StoreFixtures.device("a")]), now: 0, range: Self.tenMinutes)
        let sample = StoreFixtures.point(1000)
        // The key is the event's id, as in `devices.set(m.id, m.device)`.
        state.apply(.report(id: "new", device: StoreFixtures.device("other-id"), sample: sample), now: 1500, range: Self.tenMinutes)
        #expect(state.devices.map(\.id) == ["a", "new"])
        #expect(state.series["new"] == CardSeries(points: [sample], resolution: 2000))
    }

    @Test func reportOnALongRangeIsAppendedToWhateverIsThere() {
        // appendSample does not ask which range a card is on.
        var state = HubState(devices: [StoreFixtures.device("a")], series: ["a": CardSeries(points: [StoreFixtures.point(60_000)], resolution: 60_000)])
        state.apply(.report(id: "a", device: StoreFixtures.device("a"), sample: StoreFixtures.point(125_000)), now: 126_000) { _ in .sixHours }
        #expect(state.series["a"] == CardSeries(points: [StoreFixtures.point(60_000), StoreFixtures.point(125_000)], resolution: 60_000))
    }

    // MARK: device, removed

    @Test func deviceEventReplacesTheDeviceAndLeavesItsSamples() throws {
        var (state, events) = try Self.snapshot()
        let series = state.series
        let effects = state.apply(Self.event(events, 6, is: "device"), now: Self.snapshotTime, range: Self.tenMinutes)
        #expect(effects.isEmpty)
        let lab = try #require(state.device(M.lab))
        #expect(lab.name == "Lab PC" && lab.renamed && lab.history.isEmpty)
        #expect(state.series == series)
        #expect(state.devices.count == 7)
    }

    @Test func removedDeletesTheDeviceItsSamplesAndItsAlerts() throws {
        var (state, events) = try Self.snapshot()
        state.alerts.active = [
            ActiveAlert(ruleId: "0123456789ab", type: .offline, device: M.removed), ActiveAlert(ruleId: "0123456789ab", type: .offline, device: M.htpc),
        ]
        let effects = state.apply(Self.event(events, 8, is: "removed"), now: Self.snapshotTime, range: Self.tenMinutes)
        #expect(effects.isEmpty)
        #expect(state.device(M.removed) == nil && state.series[M.removed] == nil)
        #expect(state.devices.count == 6 && state.series.count == 6)
        #expect(state.alerts.active.map(\.device) == [M.htpc])
        // Removing what is not there is not an error.
        state.apply(.removed("never-seen"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.count == 6)
    }

    // MARK: update, energySettings, order, status

    @Test func updateRecordsTheLatestVersion() throws {
        var (state, events) = try Self.snapshot()
        #expect(state.latestVersions.isEmpty)
        #expect(state.apply(Self.event(events, 27, is: "update"), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state.latestVersions == ["windows": "1.2.33"])
        state.apply(.update(platform: "mac", version: "1.2.31"), now: 0, range: Self.tenMinutes)
        #expect(state.latestVersions == ["windows": "1.2.33", "mac": "1.2.31"])

        // versionLabel: the workstation runs 1.2.32 on Windows, the MacBook 1.2.30.
        let label = { (id: String) in state.device(id).flatMap { HubState.versionLabel(for: $0, latestVersions: state.latestVersions) } }
        #expect(label(M.workstation) == "v1.2.32 \u{2192} 1.2.33")
        #expect(label(M.macbook) == "v1.2.30 \u{2192} 1.2.31")
        #expect(label(M.dgx) == nil)                                  // no desktop app on it
        state.apply(.update(platform: "mac", version: "1.2.30"), now: 0, range: Self.tenMinutes)
        #expect(label(M.macbook) == "v1.2.30")
        #expect(HubState.versionLabel(for: StoreFixtures.device("x", platform: "linux", appVersion: "1.0.0"), latestVersions: ["windows": "9.9.9", "mac": "9.9.9"]) == "v1.0.0")
    }

    @Test func energySettingsReplacesTheSavedPrice() throws {
        var (state, events) = try Self.snapshot()
        #expect(state.energySettings == nil && !state.alerts.priceSet)
        state.apply(Self.event(events, 10, is: "energySettings"), now: 0, range: Self.tenMinutes)
        #expect(state.energySettings == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        #expect(state.alerts.priceSet)
        state.apply(Self.event(events, 12, is: "energySettings"), now: 0, range: Self.tenMinutes)
        #expect(state.energySettings == EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)]))
        state.apply(.energySettings(nil), now: 0, range: Self.tenMinutes)
        #expect(state.energySettings == nil && !state.alerts.priceSet)
    }

    @Test func orderAppliesThePositions() throws {
        var (state, events) = try Self.snapshot()
        #expect(state.apply(Self.event(events, 7, is: "order"), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state.device(M.dgx)?.order == 0 && state.device(M.workstation)?.order == 1 && state.device(M.nas)?.order == 4 && state.device(M.lab)?.order == 3)
        #expect(state.sortedDevices().map(\.id) == [M.dgx, M.workstation, M.macbook, M.lab, M.nas, M.htpc, M.removed])
        // The map order they were mentioned in does not change.
        #expect(state.devices.map(\.id).first == M.workstation)
        // Positions for devices this app has not heard of are dropped.
        state.apply(.order(["ghost": 0, M.htpc: 9]), now: 0, range: Self.tenMinutes)
        #expect(state.device(M.htpc)?.order == 9 && state.devices.count == 7)
    }

    @Test func statusFlipsOnlineFlags() throws {
        var (state, events) = try Self.snapshot()
        #expect(state.devices.filter { !$0.online }.isEmpty)
        state.apply(Self.event(events, 5, is: "status"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.filter { !$0.online }.isEmpty)
        state.apply(Self.event(events, 18, is: "status"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.filter { !$0.online }.map(\.id) == [M.htpc])
        state.apply(Self.event(events, 21, is: "status"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.filter { !$0.online }.map(\.id) == [M.nas, M.htpc])
        // A device the status does not mention keeps its flag (frame 21 no longer lists the removed box).
        #expect(state.device(M.removed)?.online == true)
        state.apply(Self.event(events, 28, is: "status"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.filter(\.online).map(\.id) == [M.removed])
        state.apply(Self.event(events, 32, is: "status"), now: 0, range: Self.tenMinutes)
        #expect(state.devices.filter { !$0.online }.map(\.id) == [M.htpc])
        // Nothing but the flag changes, and an unknown id adds nothing.
        let before = state
        #expect(state.apply(.status(["ghost": true, M.htpc: false]), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state == before)
    }

    // MARK: alerts

    @Test func alertsEventReplacesSettingsAndActive() throws {
        var (state, events) = try Self.snapshot()
        #expect(state.alerts.settings == nil)
        #expect(state.apply(Self.event(events, 13, is: "alerts"), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state.alerts.settings?.rules.count == 9 && state.alerts.settings?.tempUnit == .celsius)
        #expect(state.alerts.settings?.channels.webhook == AlertChannels.Webhook(enabled: true, url: "", keepUrl: true))
        #expect(state.alerts.active.map(\.id) == ["32b4c55dfa3c|" + M.lab])
        state.apply(Self.event(events, 20, is: "alerts"), now: 0, range: Self.tenMinutes)
        #expect(state.alerts.settings?.tempUnit == .fahrenheit)
        #expect(state.alerts.active.map(\.id) == ["feedfacecafe|" + M.dgx, "32b4c55dfa3c|" + M.lab])
        // The log is not part of that event.
        #expect(state.alerts.events.isEmpty && !state.alerts.isLoaded)
    }

    @Test func alertEventLogsTheEventReplacesActiveAndAsksForANotification() throws {
        var (state, events) = try Self.snapshot()
        let fired = Self.event(events, 15, is: "alert")
        guard case .alert(let first, let notify, let active) = fired else { return }
        #expect(notify && first.title == "DESKTOP-7QK2M1P: CPU load 97%")
        #expect(state.apply(fired, now: 0, range: Self.tenMinutes) == [.notify(first)])
        #expect(state.alerts.events == [first] && state.alerts.active == active && active.count == 2)

        state.apply(Self.event(events, 16, is: "alert"), now: 0, range: Self.tenMinutes)
        #expect(state.alerts.events.map(\.id) == ["6c4f538a06bb", "29c7b24da904"])        // newest first
        #expect(state.alerts.active.count == 3)

        // A test alert is announced but never logged.
        let test = Self.event(events, 17, is: "alert")
        guard case .alert(let testEvent, _, _) = test else { return }
        #expect(testEvent.test)
        #expect(state.apply(test, now: 0, range: Self.tenMinutes) == [.notify(testEvent)])
        #expect(state.alerts.events.map(\.id) == ["6c4f538a06bb", "29c7b24da904"])

        // A resolved alert the hub does not want announced: logged, active updated, no effect.
        for index in [19, 22, 23] { state.apply(Self.event(events, index, is: "alert"), now: 0, range: Self.tenMinutes) }
        let quiet = Self.event(events, 25, is: "alert")
        guard case .alert(let resolved, let wanted, let left) = quiet else { return }
        #expect(!wanted && resolved.state == .resolved)
        #expect(state.apply(quiet, now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state.alerts.events.first == resolved && state.alerts.events.count == 6)
        #expect(state.alerts.active == left && left.map(\.device) == [M.htpc, M.dgx, M.lab])
    }

    @Test func theLogKeepsTheNewestHundredAndFiftyAndNoDuplicates() {
        var state = HubState()
        for n in 0..<160 { state.apply(.alert(event: StoreFixtures.alert("e\(n)", t: Double(n)), notify: false, active: []), now: 0, range: Self.tenMinutes) }
        #expect(state.alerts.events.count == 150)
        #expect(state.alerts.events.first?.id == "e159" && state.alerts.events.last?.id == "e10")
        // The same event again (a refresh raced the stream) moves to the front rather than doubling.
        state.apply(.alert(event: StoreFixtures.alert("e100", t: 100), notify: false, active: []), now: 0, range: Self.tenMinutes)
        #expect(state.alerts.events.count == 150 && state.alerts.events.first?.id == "e100")
        #expect(state.alerts.events.filter { $0.id == "e100" }.count == 1)
    }

    // MARK: everything else

    @Test func actionResultsAndUnknownEventsChangeNothing() throws {
        var (state, events) = try Self.snapshot()
        let before = state
        #expect(state.apply(Self.event(events, 9, is: "actionResult"), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state.apply(.unknown("somethingNew"), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(try state.apply(HubEvent.decode(#"{"type":"processes","id":"x","list":[1,2,3]}"#), now: 0, range: Self.tenMinutes).isEmpty)
        #expect(state == before)
    }

    @Test func theWholeCapturedStreamInOrder() throws {
        let events = try M.events()
        #expect(Set(events.map(\.type)) == ["snapshot", "report", "device", "removed", "update", "energySettings", "order", "status", "alert", "alerts", "actionResult"])
        var state = HubState()
        var notified: [String] = []
        var reloads = 0
        for event in events {
            for effect in state.apply(event, now: Self.snapshotTime + 60_000, range: Self.tenMinutes) {
                switch effect {
                case .reloadLongSeries: reloads += 1
                case .notify(let event): notified.append(event.id)
                }
            }
        }
        #expect(reloads == 1)
        #expect(state.sortedDevices().map(\.displayName) == ["dgx-station", "DESKTOP-7QK2M1P", "Sams-MacBook-Pro", "Lab PC", "nas", "htpc"])
        #expect(state.devices.filter { !$0.online }.map(\.id) == [M.htpc])
        #expect(state.series[M.workstation]?.points.count == 9 && state.series[M.nas]?.points.last?.t == 1_795_213_949_000)
        #expect(state.series[M.removed] == nil)
        #expect(state.latestVersions == ["windows": "1.2.33"])
        #expect(state.energySettings?.currency == "EUR" && state.energySettings?.isTimeOfUse == true)
        #expect(state.alerts.priceSet)
        #expect(state.alerts.settings?.tempUnit == .fahrenheit)
        #expect(state.alerts.events.map(\.id) == ["50a357f38e02", "f32790f355c1", "cd3c8d079a36", "a3c6e0cfeb16", "4b26e1060b39", "33a0c5598368", "54eafba603c0", "6c4f538a06bb", "29c7b24da904"])
        #expect(state.alerts.active.map(\.id) == ["deadbeef0001|*", "138ac9e65858|" + M.htpc, "feedfacecafe|" + M.dgx, "32b4c55dfa3c|" + M.lab])
        // Everything but the two quiet "back online" events, the test alert included.
        #expect(notified == ["29c7b24da904", "6c4f538a06bb", "930c8515f336", "54eafba603c0", "33a0c5598368", "4b26e1060b39", "cd3c8d079a36", "f32790f355c1"])
    }

    // MARK: ordering

    static let english = Locale(identifier: "en_US")

    /// The devices in the order the store lists them, mentioned by the hub in the order given.
    static func sorted(_ devices: [Device], locale: Locale) -> [Device] {
        HubState(devices: devices).sortedDevices(locale: locale)
    }

    @Test func devicesSortByPositionThenByName() {
        // Position first; a device without one goes after every device with one.
        #expect(Self.sorted([d("c", "Alpha", nil), d("b", "Zulu", 1), d("a", "Mike", 0)], locale: Self.english).map(\.id) == ["a", "b", "c"])
        // Equal positions: by name, the way people sort (case and accents are not byte order).
        let tied = [d("1", "banana", 2), d("2", "Cherry", 2), d("3", "apple", 2), d("4", "\u{C9}clair", 2), d("5", "Date", 2)]
        #expect(Self.sorted(tied, locale: Self.english).map(\.name) == ["apple", "banana", "Cherry", "Date", "\u{C9}clair"])
        // Unordered devices sort among themselves by name too.
        #expect(Self.sorted([d("x", "b", nil), d("y", "a", nil), d("z", "c", 5)], locale: Self.english).map(\.id) == ["z", "y", "x"])
        // Zero is a position, not a missing one.
        #expect(Self.sorted([d("x", "a", 1), d("y", "b", 0)], locale: Self.english).map(\.id) == ["y", "x"])
    }

    @Test func tiesOnPositionAndNameKeepTheHubsOrder() {
        let twins = [StoreFixtures.device("second", name: "PC", order: 3), StoreFixtures.device("first", name: "PC", order: 3), StoreFixtures.device("third", name: "PC", order: 3)]
        #expect(Self.sorted(twins, locale: Self.english).map(\.id) == ["second", "first", "third"])
        // A missing name sorts as the empty string: first.
        var nameless = StoreFixtures.device("n", order: 3)
        nameless.name = nil
        #expect(Self.sorted(twins + [nameless], locale: Self.english).map(\.id) == ["n", "second", "first", "third"])
    }

    @Test func nameOrderFollowsTheLocale() {
        let names = ["Zebra", "\u{C4}rger", "Apfel"].enumerated().map { StoreFixtures.device("\($0)", name: $1, order: 0) }
        // German files Ä with A; Swedish puts it after Z.
        #expect(Self.sorted(names, locale: Locale(identifier: "de_DE")).map(\.name) == ["Apfel", "\u{C4}rger", "Zebra"])
        #expect(Self.sorted(names, locale: Locale(identifier: "sv_SE")).map(\.name) == ["Apfel", "Zebra", "\u{C4}rger"])
    }

    @Test func aReorderSendsTheVisibleCardsThenEveryOtherDevice() {
        var state = HubState(devices: [d("a", "A", 0), d("b", "B", 1), d("off2", "Zed", 3, false), d("c", "C", 2), d("off1", "Ann", 3, false), d("new", "New", nil, false)])
        // The user dragged c to the front; offline devices have no card and follow in display order.
        let ids = state.completeOrder(ids: ["c", "a", "b"], locale: Self.english)
        #expect(ids == ["c", "a", "b", "off1", "off2", "new"])
        // Unknown and repeated ids are dropped.
        #expect(state.completeOrder(ids: ["c", "ghost", "c", "a"], locale: Self.english) == ["c", "a", "b", "off1", "off2", "new"])

        let moved = state.setOrder(ids: ids)
        #expect(moved)
        #expect(state.sortedDevices(locale: Self.english).map(\.id) == ids)
        #expect(ids.map { state.device($0)?.order } == [0, 1, 2, 3, 4, 5])
        // The same order again moves nothing, so the hub is not told.
        let again = state.setOrder(ids: ids), viaTheCards = state.setOrder(ids: state.completeOrder(ids: ["c", "a", "b"], locale: Self.english))
        #expect(!again && !viaTheCards)
    }

    @Test func cardSeriesKnowsItsGapAndItsGPU() {
        #expect(CardSeries.empty == CardSeries(points: [], resolution: 2000))
        #expect(CardSeries().gapInterval == 10_000)                              // Math.max(10000, 2000 * 3)
        #expect(CardSeries(resolution: 60_000).gapInterval == 180_000)
        #expect(!CardSeries(points: [StoreFixtures.point(1)]).hasGPU)
        #expect(CardSeries(points: [StoreFixtures.point(1), StoreFixtures.point(2, gpu: 0)]).hasGPU)
    }

    @Test func fleetCountsReadLikeTheDashboard() {
        #expect(FleetCounts().text == "" && FleetCounts().shortText == "")
        #expect(FleetCounts(online: 1, total: 1).text == "1 of 1 device online")
        #expect(FleetCounts(online: 3, total: 4).text == "3 of 4 devices online")
        #expect(FleetCounts(online: 0, total: 2).text == "0 of 2 devices online")
        #expect(FleetCounts(online: 3, total: 4).shortText == "3/4 online" && FleetCounts(online: 3, total: 4).offline == 1)
        #expect(FleetCounts.reconnectingText == "Reconnecting to hub\u{2026}")
    }
}

/// Positional shorthand for the ordering tests.
private func d(_ id: String, _ name: String, _ order: Int?, _ online: Bool = true) -> Device {
    StoreFixtures.device(id, name: name, order: order, online: online)
}

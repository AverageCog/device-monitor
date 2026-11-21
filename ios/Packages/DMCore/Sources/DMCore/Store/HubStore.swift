import Foundation
import Observation
import os

/// What the app knows about its hub, kept current by the live stream: the one object the SwiftUI
/// screens observe. It does what the script in public/index.html does with `devices`, `series`,
/// `latestVersions` and `energy.saved`, and what `HubEvents` in public/session.js does to stay
/// connected.
///
/// ```swift
/// let store = HubStore(api: LiveHubAPI(client: client), preferences: preferences)
/// store.start()                       // connects, and reconnects every 3 s until stop()
/// ...
/// ForEach(store.onlineDevices) { device in
///     DeviceCard(device: device, series: store.series(for: device.id), range: store.range(for: device.id))
/// }
/// ```
///
/// Every action throws `HubError`. One that fails because the hub no longer knows this enrollment
/// also moves `connection` to `.unauthorized`, wherever it was called from.
@MainActor
@Observable
public final class HubStore {
    public enum ConnectionState: Sendable, Equatable {
        /// Not connected and not trying: before `start()`, after `stop()`, and while suspended.
        case idle
        /// The first connection since `start()` is being made; nothing has arrived yet.
        case connecting
        /// The stream is open and events are arriving.
        case live
        /// The stream ended or could not be opened, at `since` (ms since 1970). The store tries
        /// again every three seconds for as long as it takes. What it knew stays on show; the
        /// dashboard replaces its summary with `FleetCounts.reconnectingText` meanwhile.
        case reconnecting(since: Double)
        /// The verified hub no longer accepts this enrollment. The store has stopped; the user
        /// has to pair again.
        case unauthorized
    }

    /// `setTimeout(() => this.read(), 3000)` in public/session.js.
    public nonisolated static let reconnectDelay: Double = 3000
    /// `setInterval(() => loadAllSeries(true), 2 * 60e3)`.
    public nonisolated static let seriesRefreshInterval: Double = 2 * 60e3
    /// `&points=360` in loadSeries.
    public nonisolated static let seriesPoints = 360

    // MARK: Connection

    public private(set) var connection: ConnectionState = .idle
    /// Why the stream last ended or could not be opened; nil since `start()` until that happens.
    /// For diagnostics and for telling "unreachable" (`isConnectivityFailure`) from the rest.
    public private(set) var lastError: HubError?
    /// When `lastError` happened (ms since 1970).
    public private(set) var lastErrorAt: Double?
    /// How many times in a row the stream has ended or failed to open; zero while live.
    public private(set) var failedAttempts = 0
    /// Whether a snapshot has arrived since the store was created, i.e. whether `devices` is
    /// what a hub said rather than empty for lack of news.
    public private(set) var hasSnapshot = false
    /// When the last `status` event arrived (ms since 1970). The hub sends one every three
    /// seconds; the dashboard redraws every chart then, to keep the time axis sliding, and
    /// refreshes the "last seen" texts.
    public private(set) var lastStatusAt: Double?
    /// True from `start()` until `stop()` or until the hub refuses this enrollment.
    public private(set) var isRunning = false
    /// True between `suspend()` and `resume()`.
    public private(set) var isSuspended = false

    /// `lastError` in words.
    public var lastErrorText: String? { lastError?.errorDescription }

    public var isLive: Bool { connection == .live }

    /// The line under the title: "3 of 4 devices online", or "Reconnecting to hub…" from the
    /// moment the stream is lost until it is back (`#summaryText`).
    public var summaryText: String {
        if case .reconnecting = connection { FleetCounts.reconnectingText } else { counts.text }
    }

    /// The same for narrow layouts: "3/4 online", and nothing while reconnecting (`#summaryShort`).
    public var summaryShortText: String {
        if case .reconnecting = connection { "" } else { counts.shortText }
    }

    // MARK: Devices

    /// Every device, in the dashboard's order (`renderGrid`): by position, then by name.
    public private(set) var devices: [Device] = []
    /// The devices that get a card.
    public private(set) var onlineDevices: [Device] = []
    /// The devices in the "offline" list.
    public private(set) var offlineDevices: [Device] = []
    public private(set) var counts = FleetCounts()
    /// Chart samples by device id; `series(for:)` is the usual way in.
    public private(set) var series: [String: CardSeries] = [:]
    /// The newest published desktop app by platform, "windows" or "mac".
    public private(set) var latestVersions: [String: String] = [:]

    // MARK: Energy, alerts, hub

    /// The electricity price saved on the hub and shared by every dashboard; nil when nobody
    /// has saved one (the dashboard then guesses a rate from the time zone).
    public private(set) var energySettings: EnergySettings?
    /// False until the hub has answered once, so "no price saved" can be told from "not asked yet".
    public private(set) var isEnergySettingsLoaded = false
    public private(set) var alerts = AlertsState()
    /// `GET /api/info`, nil until it has answered.
    public private(set) var info: HubInfo?

    public let preferences: Preferences
    /// The store's time. Charts and "last seen" texts should measure against `clock.now` rather
    /// than `Date()`, so that a demo or a test on a clock of its own stays consistent.
    public let clock: any HubClock
    /// Receives the alert events the hub wants announced. See `AlertNotifier`.
    @ObservationIgnored public var alertNotifier: (any AlertNotifier)?

    @ObservationIgnored private let api: any HubAPI
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let tasks = TaskBag()

    /// The reducer's value; the observable properties above are copies, written only when they change.
    @ObservationIgnored private var state = HubState()
    /// Bumped whenever everything running is torn down, so a task that outlived that knows.
    @ObservationIgnored private var epoch = 0
    /// Bumped whenever the connection loop is replaced.
    @ObservationIgnored private var streamToken = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// Connection attempts so far; names the attempt the extra state was last fetched for.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var fetchedForAttempt = 0
    /// The newest series request per device; an answer to an older one is dropped.
    @ObservationIgnored private var seriesRequests: [String: Int] = [:]
    /// Bumped whenever the stream brings news of the value and whenever a save or a clear is
    /// answered. An answer that finds its number changed was overtaken, and may be the older.
    @ObservationIgnored private var energyRevision = 0
    @ObservationIgnored private var alertsRevision = 0

    /// - Parameters:
    ///   - api: the hub, real (`LiveHubAPI`) or not (`DemoHubAPI`).
    ///   - preferences: where each card's range is kept, and what was last seen of the alert log.
    ///   - clock: the time source of the reconnect delay, the series refresh and every timestamp.
    ///   - alertNotifier: may also be set later.
    ///   - locale: decides how names sort (`localeCompare`).
    public init(
        api: any HubAPI, preferences: Preferences, clock: any HubClock = SystemHubClock(),
        alertNotifier: (any AlertNotifier)? = nil, locale: Locale = .current
    ) {
        self.api = api
        self.preferences = preferences
        self.clock = clock
        self.alertNotifier = alertNotifier
        self.locale = locale
    }

    // MARK: - Lifecycle

    /// Connects and stays connected: consumes the live stream, and whenever it ends or cannot be
    /// opened, waits three seconds and tries again, until `stop()`. Also asks the hub for what
    /// the stream does not carry at first (published versions, the saved price, alerts, hub info).
    /// Does nothing when already running.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isSuspended = false
        connection = .connecting
        lastError = nil
        lastErrorAt = nil
        failedAttempts = 0
        launch()
        // The page asks for these as it loads, alongside the stream.
        fetchExtras(for: attempt + 1)
    }

    /// Ends the connection and everything else the store had running. What it knew stays readable.
    public func stop() {
        isRunning = false
        isSuspended = false
        teardown()
        connection = .idle
    }

    /// The app went to the background: closes the stream and stops the timers, without forgetting
    /// that the store is meant to be running.
    public func suspend() {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        teardown()
        connection = .idle
    }

    /// The app is in the foreground again: reconnects at once.
    public func resume() {
        guard isRunning, isSuspended else { return }
        isSuspended = false
        connection = hasSnapshot ? .reconnecting(since: clock.now) : .connecting
        launch()
    }

    /// Skips what is left of the three-second wait and connects now. For a "Retry" button; does
    /// nothing while live, idle or unauthorized.
    public func retryNow() {
        guard isRunning, !isSuspended else { return }
        switch connection {
        case .connecting, .reconnecting: launchStream()
        case .idle, .live, .unauthorized: break
        }
    }

    private func launch() {
        epoch += 1
        launchStream()
        let epoch = epoch
        tasks.run { [weak self, clock] in
            while true {
                do { try await clock.sleep(milliseconds: HubStore.seriesRefreshInterval) } catch { return }
                guard let self, self.epoch == epoch else { return }
                // While the stream is down the answer could not be kept current anyway, and the
                // snapshot that ends the outage reloads every long series.
                if self.connection == .live { self.loadAllSeries(longOnly: true) }
            }
        }
    }

    private func teardown() {
        epoch += 1
        streamToken += 1
        streamTask = nil
        // Requests for the extras are cancelled with everything else, so they count as not made.
        fetchedForAttempt = 0
        tasks.cancelAll()
    }

    // MARK: - The live stream

    /// `HubEvents.read()` in public/session.js, forever.
    private func launchStream() {
        streamToken += 1
        let token = streamToken
        streamTask?.cancel()
        streamTask = tasks.run { [weak self, api, clock] in
            while !Task.isCancelled {
                guard let attempt = self?.beginAttempt(token) else { return }
                var failure: HubError?
                do {
                    for try await event in api.events() {
                        // Bound for one event at a time: the store is not kept alive by its own loop.
                        guard let self, self.streamToken == token else { return }
                        self.receive(event, attempt: attempt)
                    }
                } catch {
                    failure = HubError(error)
                }
                guard self?.connectionEnded(failure, token) == true else { return }
                do { try await clock.sleep(milliseconds: HubStore.reconnectDelay) } catch { return }
            }
        }
    }

    private func beginAttempt(_ token: Int) -> Int? {
        guard streamToken == token else { return nil }
        attempt += 1
        return attempt
    }

    private func receive(_ event: HubEvent, attempt: Int) {
        if connection != .live {
            connection = .live
            failedAttempts = 0
            // Whatever changed while there was no stream was not announced to this app.
            fetchExtras(for: attempt)
        }
        let now = clock.now
        let before = state
        let effects = state.apply(event, now: now) { preferences.cardRange(for: $0) }
        switch event {
        case .snapshot:
            hasSnapshot = true
            // Every chart starts over from the snapshot: an answer still on its way is older.
            seriesRequests = seriesRequests.mapValues { $0 + 1 }
        case .status: lastStatusAt = now
        case .energySettings:
            energyRevision += 1
            isEnergySettingsLoaded = true
            // It also decides `alerts.priceSet`.
            alertsRevision += 1
        // A removal takes what was firing for the device with it, on the hub as well.
        case .alert, .alerts, .removed: alertsRevision += 1
        default: break
        }
        publish(since: before)
        for effect in effects {
            switch effect {
            case .reloadLongSeries: loadAllSeries(longOnly: true)
            case .notify(let event): alertNotifier?.notify(event)
            }
        }
    }

    /// Whether to wait and try again.
    private func connectionEnded(_ failure: HubError?, _ token: Int) -> Bool {
        guard streamToken == token, !Task.isCancelled else { return false }
        let error = failure ?? .unreachable("The hub closed the live stream.")
        if error.isUnauthorized {
            becomeUnauthorized(error)
            return false
        }
        let now = clock.now
        lastError = error
        lastErrorAt = now
        failedAttempts += 1
        if case .reconnecting = connection {} else { connection = .reconnecting(since: now) }
        return true
    }

    /// The hub answered 401, or refused the stream: `offlineFor(e, true)` in main.js, the
    /// "repair" page of app/offline.js. Retrying cannot help, so everything stops.
    private func becomeUnauthorized(_ error: HubError) {
        lastError = error
        lastErrorAt = clock.now
        isRunning = false
        isSuspended = false
        teardown()
        connection = .unauthorized
    }

    /// Turns whatever an API call threw into the `HubError` the caller gets, and acts on the one
    /// failure that concerns the whole store.
    private func failed(_ error: any Error) -> HubError {
        let failure = HubError(error)
        if failure.isUnauthorized, connection != .unauthorized { becomeUnauthorized(failure) }
        return failure
    }

    /// Copies what changed in `state` to the observable properties. An unchanged property is not
    /// written, so nothing that only reads it is invalidated.
    private func publish(since before: HubState) {
        if state.devices != before.devices {
            let sorted = state.sortedDevices(locale: locale)
            let online = sorted.filter(\.online), offline = sorted.filter { !$0.online }
            let total = FleetCounts(online: online.count, total: sorted.count)
            if devices != sorted { devices = sorted }
            if onlineDevices != online { onlineDevices = online }
            if offlineDevices != offline { offlineDevices = offline }
            if counts != total { counts = total }
        }
        if state.series != before.series { series = state.series }
        if state.latestVersions != before.latestVersions { latestVersions = state.latestVersions }
        if state.energySettings != before.energySettings { energySettings = state.energySettings }
        if state.alerts != before.alerts { alerts = state.alerts }
    }

    private func change(_ body: (inout HubState) -> Void) {
        let before = state
        body(&state)
        publish(since: before)
    }

    // MARK: - What the stream does not carry

    /// Published versions, the saved price, alerts and hub info, once per connection attempt:
    /// asked for alongside the first, and again whenever a later one goes live.
    private func fetchExtras(for attempt: Int) {
        guard fetchedForAttempt != attempt else { return }
        fetchedForAttempt = attempt
        let store = Unretained(store: self)
        tasks.run { [api] in _ = try? await HubStore.refreshLatestVersions(of: store, from: api) }
        tasks.run { [api] in _ = try? await HubStore.refreshEnergySettings(of: store, from: api) }
        tasks.run { [api] in _ = try? await HubStore.refreshAlerts(of: store, from: api) }
        tasks.run { [api] in _ = try? await HubStore.refreshInfo(of: store, from: api) }
    }

    /// A store, referred to without keeping it alive. The store's own tasks ask the hub through
    /// one: when nobody called `stop()`, the stream and the timer are only cancelled by the
    /// store going away, and a task that held the store for the length of a request would put
    /// that off until the hub had answered. A request looks the store up before asking and
    /// again with the answer, and holds nothing in between.
    private struct Unretained: Sendable {
        weak var store: HubStore?
    }

    /// `loadLatestVersions`: asks for each platform's newest desktop app. A platform without a
    /// published update keeps what was known. Throws the first failure after trying both.
    public func refreshLatestVersions() async throws(HubError) {
        try await HubStore.refreshLatestVersions(of: Unretained(store: self), from: api)
    }

    private static func refreshLatestVersions(of reference: Unretained, from api: any HubAPI) async throws(HubError) {
        var first: HubError?
        for platform in UpdatePlatform.allCases {
            let key = platform.rawValue
            guard let known = reference.store.map({ $0.state.latestVersions[key] }) else { return }
            do {
                let version = try await api.latestVersion(platform: platform)
                guard let store = reference.store else { return }
                // An `update` event that arrived meanwhile is newer than this answer.
                if let version, store.state.latestVersions[key] == known { store.change { $0.latestVersions[key] = version } }
            } catch {
                guard let store = reference.store else { return }
                let failure = store.failed(error)
                first = first ?? failure
            }
        }
        if let first { throw first }
    }

    /// "v1.2.30", or "v1.2.30 → 1.2.33" when the hub has a newer desktop app for the device's
    /// platform; nil for a device that is not running the app (`versionLabel`).
    public func versionLabel(for device: Device) -> String? {
        HubState.versionLabel(for: device, latestVersions: latestVersions)
    }

    @discardableResult
    public func refreshInfo() async throws(HubError) -> HubInfo {
        try await HubStore.refreshInfo(of: Unretained(store: self), from: api)
    }

    @discardableResult
    private static func refreshInfo(of reference: Unretained, from api: any HubAPI) async throws(HubError) -> HubInfo {
        do {
            let answer = try await api.info()
            reference.store?.info = answer
            return answer
        } catch {
            throw reference.store?.failed(error) ?? HubError(error)
        }
    }

    // MARK: - Devices

    public func device(_ id: String) -> Device? {
        // From the observable list, so that a view reading one device follows its changes.
        devices.first { $0.id == id }
    }

    /// Renames a device. The hub keeps 60 characters and ignores a name that is empty once
    /// cleaned; an empty `name` is not sent at all (the dashboard's `if (name)`). The new name
    /// shows when the hub announces it, as on every other dashboard.
    @discardableResult
    public func rename(device id: String, name: String) async throws(HubError) -> Device? {
        guard !name.isEmpty else { return nil }
        do {
            return try await api.rename(device: id, name: name)
        } catch {
            throw failed(error)
        }
    }

    /// Removes a device from the hub with its history. It goes from `devices` when the hub
    /// announces the removal; if its agent is still running it will be back with its next report.
    public func remove(device id: String) async throws(HubError) {
        do {
            try await api.remove(device: id)
        } catch {
            throw failed(error)
        }
    }

    /// Puts the devices in a new order. `ids` are the cards the user arranged, first to last
    /// (normally `onlineDevices` in their new order); every other device follows in its present
    /// order, as at the end of a drag on the dashboard. The new positions apply here at once,
    /// and the hub is told only when something moved. A failure is thrown but not undone: the
    /// next snapshot brings the hub's order back.
    public func reorder(ids: [String]) async throws(HubError) {
        let all = state.completeOrder(ids: ids, locale: locale)
        var moved = false
        change { moved = $0.setOrder(ids: all) }
        guard moved else { return }
        do {
            try await api.setOrder(ids: all)
        } catch {
            throw failed(error)
        }
    }

    /// Asks the hub to send a Wake-on-LAN signal to a device that reported a network card address
    /// (`!device.macs.isEmpty`).
    public func wake(device id: String) async throws(HubError) {
        do {
            try await api.wake(device: id)
        } catch {
            throw failed(error)
        }
    }

    // MARK: - Card charts

    /// The samples of a device's card chart, for the range the card is on. Empty until loaded.
    public func series(for id: String) -> CardSeries {
        series[id] ?? .empty
    }

    /// The range a device's card is on (`rangeOf`).
    public func range(for id: String) -> HistoryRange {
        preferences.cardRange(for: id)
    }

    /// `setRange(id, r)`: remembers the range, empties the chart and fetches the new series.
    /// Ignores anything but `HistoryRange.cardRanges`.
    public func setRange(_ range: HistoryRange, for id: String) {
        guard HistoryRange.cardRanges.contains(range) else { return }
        preferences.setCardRange(range, for: id)
        change { $0.series[id] = nil }
        loadSeries(id)
    }

    /// `loadAllSeries(longOnly)`. Cards on ten minutes are fed by the stream.
    private func loadAllSeries(longOnly: Bool) {
        for device in state.devices where !longOnly || range(for: device.id) != .tenMinutes {
            loadSeries(device.id)
        }
    }

    /// `loadSeries(id)`.
    private func loadSeries(_ id: String) {
        let wanted = range(for: id)
        let request = (seriesRequests[id] ?? 0) + 1
        seriesRequests[id] = request
        let epoch = epoch
        tasks.run { [weak self, api] in
            let answer: Result<HistoryResponse, HubError>
            do {
                answer = .success(try await api.history(device: id, range: wanted, points: HubStore.seriesPoints))
            } catch {
                answer = .failure(HubError(error))
            }
            guard let self, self.epoch == epoch else { return }
            switch answer {
            case .success(let response):
                // `if (want !== rangeOf(id)) return`, and likewise for an answer that a newer
                // request for the same card has overtaken, or whose device has gone.
                guard self.seriesRequests[id] == request, self.range(for: id) == wanted, self.state.device(id) != nil else { return }
                self.change { $0.setSeries(response, for: id) }
            case .failure(let failure):
                // loadSeries swallows failures; the chart keeps what it had.
                _ = self.failed(failure)
            }
        }
    }

    // MARK: - History and energy

    /// The history page's data (`loadHistory`): an explicit window in at most about `points` points.
    public func loadHistory(device id: String, from: Double, to: Double, points: Int) async throws(HubError) -> HistoryResponse {
        do {
            return try await api.history(device: id, from: from, to: to, points: points)
        } catch {
            throw failed(error)
        }
    }

    /// The advanced page's data (`loadAdv`): totals per device over the buckets between `bounds`.
    /// The answer carries the saved price, which becomes `energySettings`.
    public func loadEnergy(bounds: [Double]) async throws(HubError) -> EnergyResponse {
        let revision = energyRevision
        do {
            let response = try await api.energy(bounds: bounds)
            if revision == energyRevision { setEnergySettings(response.settings) }
            return response
        } catch {
            throw failed(error)
        }
    }

    public func refreshEnergySettings() async throws(HubError) {
        try await HubStore.refreshEnergySettings(of: Unretained(store: self), from: api)
    }

    private static func refreshEnergySettings(of reference: Unretained, from api: any HubAPI) async throws(HubError) {
        guard let revision = reference.store?.energyRevision else { return }
        do {
            let saved = try await api.energySettings()
            if let store = reference.store, revision == store.energyRevision { store.setEnergySettings(saved) }
        } catch {
            throw reference.store?.failed(error) ?? HubError(error)
        }
    }

    /// Saves the electricity price on the hub, for every dashboard, and returns what the hub
    /// stored (it rounds rates and sorts time-of-use periods). `energySettings` becomes that too,
    /// unless the stream brought other news of the price while the hub was answering: then it is
    /// whatever the hub has now, which may already be someone else's later save.
    @discardableResult
    public func saveEnergySettings(_ settings: EnergySettings) async throws(HubError) -> EnergySettings {
        let revision = energyRevision
        let saved: EnergySettings
        do {
            saved = try await api.saveEnergySettings(settings)
        } catch {
            throw failed(error)
        }
        let overtaken = revision != energyRevision
        // Whatever was asked before now may predate the save.
        energyRevision += 1
        if !overtaken {
            setEnergySettings(saved)
        } else if state.energySettings != saved {
            // Other news of the price got here while the hub was answering, and it is not what
            // was saved: either the announcement of this save is still on its way, or a later
            // save has replaced it already. Only the hub can say which. The save itself went
            // through, so failing to ask is not the caller's failure.
            _ = try? await refreshEnergySettings()
        }
        return saved
    }

    private func setEnergySettings(_ settings: EnergySettings?) {
        isEnergySettingsLoaded = true
        change {
            $0.energySettings = settings
            $0.alerts.priceSet = settings != nil
        }
    }

    // MARK: - Alerts

    /// Fetches settings, what is firing and the log.
    public func refreshAlerts() async throws(HubError) {
        try await HubStore.refreshAlerts(of: Unretained(store: self), from: api)
    }

    private static func refreshAlerts(of reference: Unretained, from api: any HubAPI) async throws(HubError) {
        do {
            // An alert that arrives while the answer is on its way may or may not be in it.
            for last in [false, false, true] {
                guard let revision = reference.store?.alertsRevision else { return }
                let response = try await api.alerts()
                guard let store = reference.store else { return }
                if revision == store.alertsRevision || last {
                    store.change { $0.alerts = AlertsState(response) }
                    return
                }
            }
        } catch {
            throw reference.store?.failed(error) ?? HubError(error)
        }
    }

    /// Saves rules and channels. `alerts.settings` becomes what the hub stored, and
    /// `alerts.active` what fires under it, unless the stream brought other news of the alerts
    /// while the hub was answering: then both are whatever the hub has now.
    public func saveAlerts(_ settings: AlertSettings) async throws(HubError) {
        let revision = alertsRevision
        let update: AlertsUpdate
        do {
            update = try await api.saveAlerts(settings)
        } catch {
            throw failed(error)
        }
        let overtaken = revision != alertsRevision
        // Whatever was asked before now may predate the save.
        alertsRevision += 1
        if !overtaken {
            change {
                $0.alerts.settings = update.settings
                $0.alerts.active = update.active
            }
        } else if state.alerts.settings != update.settings || state.alerts.active != update.active {
            // Other news of the alerts got here while the hub was answering, and it is not what
            // the answer says: an alert that fired or cleared since, a device removed, someone
            // else's rules, or just the hub's announcements still arriving. Only the hub can
            // say which. The save itself went through, so failing to ask is not the caller's
            // failure.
            _ = try? await refreshAlerts()
        }
    }

    /// Has the hub send a test alert through every channel that is on. The test also arrives on
    /// the stream and reaches `alertNotifier` when the "apps" channel is on.
    public func sendTestAlert() async throws(HubError) -> AlertTestResult {
        do {
            return try await api.testAlert()
        } catch {
            throw failed(error)
        }
    }

    /// Empties the hub's alert log, and `alerts.events` with it. An entry that reached the store
    /// while the hub was answering stays if the hub logged it after emptying the log.
    public func clearAlertLog() async throws(HubError) {
        let known = Set(state.alerts.events.map(\.id))
        do {
            try await api.clearAlertLog()
        } catch {
            throw failed(error)
        }
        // Whatever was asked before now may still hold the old log.
        alertsRevision += 1
        // What the store had when it asked is gone for certain.
        change { $0.alerts.events.removeAll { known.contains($0.id) } }
        // What arrived since was logged just before the hub emptied its log or just after, and
        // only the hub can say which. The log was cleared either way, so failing to ask is not
        // the caller's failure; the entries in doubt then stay on show.
        if !state.alerts.events.isEmpty { _ = try? await refreshAlerts() }
    }

    /// Log entries newer than the one the user last looked at.
    public var unseenAlertCount: Int {
        let events = alerts.events
        if let id = preferences.lastSeenAlertID, let index = events.firstIndex(where: { $0.id == id }) { return index }
        guard let time = preferences.lastSeenAlertTime else { return events.count }
        return events.prefix { $0.t > time }.count
    }

    /// The user has looked at the log.
    public func markAlertsSeen() {
        if let newest = alerts.events.first { preferences.markAlertSeen(newest) }
    }

    // MARK: - Sharing and the enrollment

    /// A single-use link that opens the dashboard in a browser, for ten minutes. It lets whoever
    /// has it in: hand it to the share sheet and nowhere else.
    public func createBrowserInvitation() async throws(HubError) -> URL {
        do {
            return try await api.createBrowserInvitation()
        } catch {
            throw failed(error)
        }
    }

    public func loadRemoteStatus() async throws(HubError) -> RemoteStatus {
        do {
            return try await api.remoteStatus()
        } catch {
            throw failed(error)
        }
    }

    /// The hub's entry for this phone.
    public func loadMobileClients() async throws(HubError) -> [MobileClient] {
        do {
            return try await api.mobileClients()
        } catch {
            throw failed(error)
        }
    }

    // Disconnecting is `SessionController.disconnect()`, not an action of the store: the stored
    // credentials have to go with the enrollment, and only the session holds those.

    /// Tasks the store started that have not finished. Zero some moments after `stop()`.
    var activeTaskCount: Int { tasks.count }
}

/// The tasks a store has running. They are cancelled when the store stops, and when it goes away
/// without having been stopped, which it can only do if none of them holds it while it waits.
private final class TaskBag: Sendable {
    private struct State: Sendable {
        var nextID: UInt64 = 0
        var tasks: [UInt64: Task<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit {
        cancelAll()
    }

    var count: Int { state.withLock { $0.tasks.count } }

    @discardableResult
    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        state.withLock { state in
            state.nextID += 1
            let id = state.nextID
            // Started under the lock, so its own removal cannot come before it is entered.
            let task = Task { @MainActor [weak self] in
                await operation()
                self?.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
            }
            state.tasks[id] = task
            return task
        }
    }

    func cancelAll() {
        state.withLock { Array($0.tasks.values) }.forEach { $0.cancel() }
    }
}

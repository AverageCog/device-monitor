import Foundation

/// The samples behind one device card's chart (`series` in public/index.html).
public struct CardSeries: Sendable, Equatable {
    /// Width of a raw sample: agents report every two seconds.
    public static let liveResolution: Double = 2000
    /// What `drawChart` draws for a card without samples: `{ points: [], resolution: 2000 }`.
    public static let empty = CardSeries()

    /// Oldest first.
    public var points: [HistoryPoint]
    /// Width of one point in milliseconds: 2000 for raw samples, more for averaged ones.
    public var resolution: Double

    public init(points: [HistoryPoint] = [], resolution: Double = CardSeries.liveResolution) {
        self.points = points
        self.resolution = resolution
    }

    /// Two points further apart than this are not joined by a line: the device was off in
    /// between (`const gap = Math.max(10000, ser.resolution * 3)` in drawChart).
    public var gapInterval: Double { max(10_000, resolution * 3) }

    /// Whether the GPU line is drawn at all (`hist.some(s => s.gpu != null)`).
    public var hasGPU: Bool { points.contains { $0.gpu != nil } }
}

/// What the hub last said about alerts: `GET /api/alerts`, kept current by `alert` and `alerts`
/// events.
public struct AlertsState: Sendable, Equatable {
    /// The hub answers with the newest 150 log entries, and the store keeps as many.
    public static let maxEvents = 150

    /// nil until the hub has been asked or has announced them.
    public var settings: AlertSettings?
    /// Everything firing now, most recent first.
    public var active: [ActiveAlert]
    /// The log, newest first. Test alerts are never part of it.
    public var events: [AlertEvent]
    /// Whether an electricity price is saved; without one a daily-cost rule never fires.
    public var priceSet: Bool
    /// False until `GET /api/alerts` has answered once.
    public var isLoaded: Bool

    public init(
        settings: AlertSettings? = nil, active: [ActiveAlert] = [], events: [AlertEvent] = [], priceSet: Bool = false,
        isLoaded: Bool = false
    ) {
        self.settings = settings
        self.active = active
        self.events = events
        self.priceSet = priceSet
        self.isLoaded = isLoaded
    }

    public init(_ response: AlertsResponse) {
        self.init(settings: response.settings, active: response.active, events: response.events, priceSet: response.priceSet, isLoaded: true)
    }
}

/// How many devices there are and how many are online, with the dashboard's wording.
public struct FleetCounts: Sendable, Hashable {
    public var online: Int
    public var total: Int

    public init(online: Int = 0, total: Int = 0) {
        self.online = online
        self.total = total
    }

    public var offline: Int { total - online }

    /// "3 of 4 devices online"; empty without devices (`#summaryText` in renderGrid).
    public var text: String {
        total == 0 ? "" : "\(online) of \(total) device\(total == 1 ? "" : "s") online"
    }

    /// "3/4 online", for narrow layouts (`#summaryShort`).
    public var shortText: String {
        total == 0 ? "" : "\(online)/\(total) online"
    }

    /// What replaces the summary while the live stream is down (`es.onerror` in connect()).
    public static let reconnectingText = "Reconnecting to hub\u{2026}"
}

/// Everything the live stream keeps current, and the one function that changes it. A port of the
/// message handler in `connect()` (public/index.html), free of timers, networking and UI so it
/// can be tested event by event.
public struct HubState: Sendable, Equatable {
    /// Something the caller has to do after an event, because the reducer itself does nothing
    /// but change values.
    public enum Effect: Sendable, Equatable {
        /// `loadAllSeries(true)`: fetch the series of every card that is not on ten minutes.
        case reloadLongSeries
        /// The hub wants apps to show a notification for this alert event.
        case notify(AlertEvent)
    }

    /// Devices in the order the hub first mentioned them, which is what the dashboard's `Map`
    /// iterates in and what breaks ties when sorting. Their `history` is always empty: samples
    /// live in `series`.
    public private(set) var devices: [Device]
    /// Chart samples by device id.
    public var series: [String: CardSeries]
    /// The newest published desktop app by platform, "windows" or "mac" (`latestVersions`).
    public var latestVersions: [String: String]
    /// The electricity price saved on the hub (`energy.saved`), nil when there is none.
    public var energySettings: EnergySettings?
    public var alerts: AlertsState

    public init(
        devices: [Device] = [], series: [String: CardSeries] = [:], latestVersions: [String: String] = [:],
        energySettings: EnergySettings? = nil, alerts: AlertsState = AlertsState()
    ) {
        self.devices = []
        self.series = series
        self.latestVersions = latestVersions
        self.energySettings = energySettings
        self.alerts = alerts
        for device in devices { set(device) }
    }

    public func device(_ id: String) -> Device? {
        devices.first { $0.id == id }
    }

    // MARK: Events

    /// Applies one stream event. `now` is the time of arrival (`Date.now()`), and `range` tells
    /// which range a device's card is on (`rangeOf`).
    @discardableResult
    public mutating func apply(_ event: HubEvent, now: Double, range: (String) -> HistoryRange) -> [Effect] {
        switch event {
        case .snapshot(let snapshot):
            devices = []
            series = [:]
            for device in snapshot {
                set(device)
                // Cards on 10 min get raw samples live; longer ranges are fetched.
                if range(device.id) == .tenMinutes {
                    series[device.id] = CardSeries(points: device.history, resolution: CardSeries.liveResolution)
                }
            }
            return [.reloadLongSeries]

        case .report(let id, var device, let sample):
            append(sample, to: id, now: now, range: range(id))
            device.id = id
            set(device)

        case .device(let device):
            set(device)

        case .removed(let id):
            devices.removeAll { $0.id == id }
            series[id] = nil
            // The hub forgets what was firing for the device (`removeDevice` in alerts.js)
            // without announcing it.
            alerts.active.removeAll { $0.device == id }

        case .update(let platform, let version):
            latestVersions[platform] = version

        case .energySettings(let settings):
            energySettings = settings
            alerts.priceSet = settings != nil

        case .order(let order):
            for index in devices.indices {
                if let position = order[devices[index].id] { devices[index].order = position }
            }

        case .status(let online):
            for index in devices.indices {
                if let isOnline = online[devices[index].id], devices[index].online != isOnline { devices[index].online = isOnline }
            }

        case .alert(let event, let notify, let active):
            alerts.active = active
            if !event.test {
                alerts.events.removeAll { $0.id == event.id }
                alerts.events.insert(event, at: 0)
                if alerts.events.count > AlertsState.maxEvents { alerts.events.removeLast(alerts.events.count - AlertsState.maxEvents) }
            }
            return notify ? [.notify(event)] : []

        case .alerts(let settings, let active):
            alerts.settings = settings
            alerts.active = active

        case .actionResult, .unknown:
            // connect() has no branch for either.
            break
        }
        return []
    }

    /// `devices.set(id, device)`: a known device keeps its place, a new one goes last.
    private mutating func set(_ device: Device) {
        var device = device
        device.history = []
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    /// `appendSample`: the new point goes on the end and whatever fell out of the card's window
    /// comes off the front.
    private mutating func append(_ sample: HistoryPoint, to id: String, now: Double, range: HistoryRange) {
        var current = series[id] ?? CardSeries()
        current.points.append(sample)
        let cutoff = now - range.milliseconds
        if let keep = current.points.firstIndex(where: { $0.t >= cutoff }) {
            current.points.removeFirst(keep)
        } else {
            current.points.removeAll()
        }
        series[id] = current
    }

    // MARK: Local changes

    /// A fetched series (`loadSeries`).
    public mutating func setSeries(_ response: HistoryResponse, for id: String) {
        series[id] = CardSeries(points: response.points, resolution: response.resolution)
    }

    /// Display positions for `ids`, first to last, as the end of a drag sets them. Returns whether
    /// any device actually moved, which is when the dashboard tells the hub.
    public mutating func setOrder(ids: [String]) -> Bool {
        var changed = false
        for (position, id) in ids.enumerated() {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { continue }
            if devices[index].order != position { changed = true }
            devices[index].order = position
        }
        return changed
    }

    // MARK: Derived

    /// The devices as the dashboard lists them (`renderGrid`): by `order` with unordered ones
    /// last, then by name the way people in `locale` sort text. Devices that tie on both keep the
    /// order the hub mentioned them in. It is `DashboardOrder.sorted`, so the grid, its moves and
    /// the offline list cannot disagree.
    public func sortedDevices(locale: Locale = DashboardOrder.readingLocale) -> [Device] {
        DashboardOrder.sorted(devices, locale: locale)
    }

    /// The full id list a reorder sends: `ids` as given (the cards the user can see, in their new
    /// order), followed by every other device in display order. In the dashboard the others are
    /// the offline devices, which have no card to drag (the end of `startDrag`).
    public func completeOrder(ids: [String], locale: Locale = DashboardOrder.readingLocale) -> [String] {
        var seen = Set<String>()
        let known = Set(devices.map(\.id))
        let visible = ids.filter { known.contains($0) && seen.insert($0).inserted }
        return visible + sortedDevices(locale: locale).map(\.id).filter { !seen.contains($0) }
    }

    /// "v1.2.30" for a device running the desktop app, "v1.2.30 → 1.2.33" when the hub has a
    /// newer one for its platform, nil for a device without the app (`versionLabel`).
    public static func versionLabel(for device: Device, latestVersions: [String: String]) -> String? {
        guard let version = device.latest?.appVersion, !version.isEmpty else { return nil }
        let wanted = UpdatePlatform(devicePlatform: device.platform).flatMap { latestVersions[$0.rawValue] }
        if let wanted, !wanted.isEmpty, wanted != version { return "v\(version) \u{2192} \(wanted)" }
        return "v\(version)"
    }
}

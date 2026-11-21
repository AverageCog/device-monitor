import Foundation

/// The line at the top of the dashboard and what the grid says when it has no card to show
/// (renderGrid and the stream's error handler in public/index.html).
public struct DashboardSummaryModel: Sendable, Equatable {
    /// What the summary says while the live stream is down, until the next snapshot arrives.
    public static let reconnectingText = "Reconnecting to hub\u{2026}"
    /// What the dashboard says about its summary line once a device is offline: tapping it opens
    /// the offline list.
    public static let offlineListHint = "Show offline devices"

    public let total: Int
    public let online: Int
    /// "3 of 4 devices online", "1 of 1 device online", "Reconnecting to hub…"; empty without devices.
    public let text: String
    /// "3/4 online"; empty without devices and while reconnecting.
    public let shortText: String
    /// What a narrow window shows: the short form, except that "Reconnecting to hub…" is never
    /// shortened away.
    public let compactText: String
    /// Whether there is an offline list to open.
    public let hasOfflineDevices: Bool
    public let isReconnecting: Bool
    /// What takes the place of the cards when none is shown.
    public let emptyState: DashboardEmptyState?

    public init(devices: [Device], isReconnecting: Bool = false) {
        self.init(total: devices.count, online: devices.reduce(0) { $0 + ($1.online ? 1 : 0) }, isReconnecting: isReconnecting)
    }

    public init(total: Int, online: Int, isReconnecting: Bool = false) {
        self.total = total
        self.online = online
        self.isReconnecting = isReconnecting
        hasOfflineDevices = online < total
        emptyState = total == 0 ? .noDevices : online == 0 ? .allOffline : nil
        if isReconnecting {
            // $('#summaryText').textContent = 'Reconnecting to hub…'; … $('#summaryShort').textContent = '';
            text = DashboardSummaryModel.reconnectingText
            shortText = ""
            compactText = DashboardSummaryModel.reconnectingText
        } else if total == 0 {
            text = ""
            shortText = ""
            compactText = ""
        } else {
            // `${on} of ${list.length} device${list.length === 1 ? '' : 's'} online` and `${on}/${list.length} online`
            text = "\(online) of \(total) device\(total == 1 ? "" : "s") online"
            shortText = "\(online)/\(total) online"
            compactText = shortText
        }
    }
}

/// Everything the dashboard's main page shows for a set of devices (renderGrid): the summary, a
/// card per online device and the list of offline ones.
///
/// A convenience for building the whole screen in one go. A view that redraws one card when its
/// device reports can make that card's `DeviceCardModel` on its own.
public struct DashboardModel: Sendable, Equatable {
    public let summary: DashboardSummaryModel
    /// The online devices, in the order of the grid.
    public let cards: [DeviceCardModel]
    /// The offline devices; they have no card.
    public let offline: OfflineDeviceListModel

    public init(
        devices: [Device], unit: TemperatureUnit, latestVersions: [String: String] = [:], isReconnecting: Bool = false,
        now: Double = Date().hubTime, locale: Locale = .current
    ) {
        let sorted = DashboardOrder.sorted(devices, locale: locale)
        summary = DashboardSummaryModel(devices: devices, isReconnecting: isReconnecting)
        cards = sorted.filter(\.online).map { DeviceCardModel(device: $0, unit: unit, latestVersions: latestVersions, now: now) }
        offline = OfflineDeviceListModel(sorted: sorted.filter { !$0.online }, latestVersions: latestVersions, now: now)
    }
}

/// What the grid shows in place of cards.
public enum DashboardEmptyState: Sendable, Equatable {
    /// The hub knows no device.
    case noDevices
    /// Devices exist but none is online; they are all in the offline list.
    case allOffline

    public var title: String? {
        switch self {
        case .noDevices: "No devices yet"
        case .allOffline: nil
        }
    }

    public var message: String {
        switch self {
        // The dashboard says "Click the + button (Add device) at the top and run the command on each
        // PC you want to monitor." A phone cannot enrol computers, so the app points at the hub.
        case .noDevices: "Devices are added from the hub: open its dashboard, choose Add device (+) and run the command on each PC you want to monitor."
        case .allOffline: "All devices are offline."
        }
    }
}

/// The order devices appear in (renderGrid, offlineDevices).
public enum DashboardOrder {
    /// By the order the user dragged them into, devices without one last, then by name.
    ///
    /// `(a.order ?? 1e9) - (b.order ?? 1e9) || (a.name || '').localeCompare(b.name || '')`, stable
    /// like JavaScript's sort: devices equal in both keep the order they came in.
    public static func sorted(_ devices: [Device], locale: Locale = .current) -> [Device] {
        devices.enumerated().sorted { a, b in
            let byOrder = orderKey(a.element) - orderKey(b.element)
            if byOrder != 0 { return byOrder < 0 }
            switch compareNames(a.element.name, b.element.name, locale: locale) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The cards of the grid: the online devices, in order.
    public static func online(_ devices: [Device], locale: Locale = .current) -> [Device] {
        sorted(devices, locale: locale).filter(\.online)
    }

    /// The offline list, in order.
    public static func offline(_ devices: [Device], locale: Locale = .current) -> [Device] {
        sorted(devices, locale: locale).filter { !$0.online }
    }

    /// `(a.order ?? 1e9) - (b.order ?? 1e9)`, stable, without the name: the order of the history
    /// page's device chips (renderHvDevices).
    public static func sortedByOrderOnly(_ devices: [Device]) -> [Device] {
        devices.enumerated().sorted { a, b in
            let byOrder = orderKey(a.element) - orderKey(b.element)
            return byOrder != 0 ? byOrder < 0 : a.offset < b.offset
        }.map(\.element)
    }

    static func orderKey(_ device: Device) -> Double {
        device.order.map(Double.init) ?? 1e9
    }

    /// `(a || '').localeCompare(b || '')` in the given locale.
    public static func compareNames(_ a: String?, _ b: String?, locale: Locale = .current) -> ComparisonResult {
        (a ?? "").compare(b ?? "", options: [], range: nil, locale: locale)
    }
}

/// A row of the offline list (renderOffline).
public struct OfflineDeviceRowModel: Sendable, Equatable, Identifiable {
    public let id: String
    /// `d.name || d.hostname || d.id`.
    public let name: String
    /// "last seen 3m ago · Windows 11 Pro · v1.2.32 → 1.2.33".
    public let subtitle: String
    /// Whether the hub knows a network address to send a Wake-on-LAN signal to.
    public let canWake: Bool

    public init(device d: Device, latestVersions: [String: String] = [:], now: Double = Date().hubTime) {
        id = d.id
        name = d.displayName
        // ['last seen ' + (d.lastSeen ? ago(d.lastSeen) : 'never'), d.os || d.platform, versionLabel(d)].filter(Boolean).join(' · ')
        subtitle = [DeviceCardModel.lastSeenText(d.lastSeen, now: now), DeviceCardModel.systemText(d), DeviceVersion.label(for: d, latestVersions: latestVersions)]
            .compactMap(DashJS.text).joined(separator: " \u{B7} ")
        // d.macs?.length
        canWake = !d.macs.isEmpty
    }
}

/// The offline devices, compact, under the grid's summary.
public struct OfflineDeviceListModel: Sendable, Equatable {
    public static let title = "Offline devices"
    /// What a row does when tapped.
    public static let rowHint = "Open history"

    public let rows: [OfflineDeviceRowModel]

    public var isEmpty: Bool { rows.isEmpty }

    /// Takes all devices, in any order; keeps the offline ones and sorts them like the dashboard.
    public init(devices: [Device], latestVersions: [String: String] = [:], now: Double = Date().hubTime, locale: Locale = .current) {
        self.init(sorted: DashboardOrder.offline(devices, locale: locale), latestVersions: latestVersions, now: now)
    }

    init(sorted offline: [Device], latestVersions: [String: String], now: Double) {
        rows = offline.map { OfflineDeviceRowModel(device: $0, latestVersions: latestVersions, now: now) }
    }
}

/// The Wake button of an offline row and what it says while and after sending.
public enum WakeButtonState: Sendable, Equatable, CaseIterable {
    case idle, sending, sent, failed

    public static let hint = "Send a Wake-on-LAN signal"

    public var title: String {
        switch self {
        case .idle: "Wake"
        case .sending: "Sending\u{2026}"
        case .sent: "Sent \u{2713}"
        case .failed: "Failed"
        }
    }

    /// The dashboard disables the button once pressed and leaves it showing the outcome.
    public var isEnabled: Bool { self == .idle }
}

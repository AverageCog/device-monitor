import DMCore
import Observation
import SwiftUI

/// Wording that only the app has. Everything the dashboard itself says comes from DMCore's
/// presentation layer (`DeviceCardModel`, `DashboardSummaryModel`, `DeviceMenuItem`…).
nonisolated enum DashboardStrings {
    /// The product name next to the logo (`.logo-text` in public/index.html).
    static let productName = "Device Monitor"
    /// The title of the "+" button (`#addBtn`).
    static let addDevice = "Add device"
    static let demoBanner = "Demo mode: these devices are simulated."
    static let loading = "Loading devices\u{2026}"
    static let cancel = "Cancel"
    static let remove = "Remove"
    static let done = "Done"
    static let ok = "OK"
    static let moveUp = "Move up"
    static let moveDown = "Move down"
    static let chart = "Usage chart"
    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
    static let noReading = "No reading"
    static let reorderFailed = "Couldn\u{2019}t save the new order"
    static let wakeFailed = "The wake signal could not be sent."
    static let renameMessage = "The hub keeps up to \(DeviceRename.maxLength) characters."

    /// What VoiceOver says for the status dot.
    static func status(isOnline: Bool) -> String { isOnline ? "Online" : "Offline" }
    /// A card in a few words, for whoever lands on it and for UI tests: "online, CPU 27%".
    static func cardSummary(_ gauge: DeviceGaugeModel) -> String { "online, \(gauge.label) \(gauge.valueText)" }
    /// The same for a row of the offline list: "offline, last seen 3d ago · Windows 11 Home".
    static func offlineSummary(_ subtitle: String) -> String { "offline, \(subtitle)" }

    static func renameFailed(_ name: String) -> String { "Couldn\u{2019}t rename \u{201C}\(name)\u{201D}" }
    static func removeFailed(_ name: String) -> String { "Couldn\u{2019}t remove \u{201C}\(name)\u{201D}" }
    /// Where a card is in the grid, for VoiceOver: "2 of 5".
    static func position(_ index: Int, of count: Int) -> String { "\(index + 1) of \(count)" }
    static func moved(_ name: String, to index: Int, of count: Int) -> String { "\(name), \(position(index, of: count))" }
}

/// The accessibility identifiers of the Devices tab, in one place for the UI tests to mirror.
nonisolated enum DashboardID {
    static let screen = "screen-devices"
    static let summary = "devices-summary"
    static let addButton = "add-device-button"
    static let demoBanner = "demo-banner"
    static let loading = "devices-loading"
    static let empty = "devices-empty"
    static let emptyAddButton = "devices-empty-add-button"
    static let emptyOfflineButton = "devices-empty-offline-button"
    static let offlineList = "offline-list"
    static let offlineDone = "offline-list-done-button"
    static let renameField = "device-rename-field"

    /// A device's card in the grid, and its row in the offline list.
    static func row(_ id: String) -> String { "device-row-\(id)" }
    static func grip(_ id: String) -> String { "device-grip-\(id)" }
    static func menu(_ id: String) -> String { "device-menu-\(id)" }
    static func gauge(_ kind: DeviceGaugeModel.Kind, _ id: String) -> String { "device-gauge-\(kind.rawValue)-\(id)" }
    static func chart(_ id: String) -> String { "device-chart-\(id)" }
    static func range(_ id: String) -> String { "device-range-\(id)" }
    static func stats(_ id: String) -> String { "device-stats-\(id)" }
    static func detailsToggle(_ id: String) -> String { "device-details-toggle-\(id)" }
    static func details(_ id: String) -> String { "device-details-\(id)" }
    static func wake(_ id: String) -> String { "offline-wake-\(id)" }
    /// Where `ScrollViewReader` finds the debug tools. A card is found by its device's id.
    static let debugAnchor = "dashboard-debug"
}

extension MetricTint {
    /// The theme colour of the palette role the presentation layer names.
    var dashboardColor: Color {
        switch self {
        case .cpu: Theme.cpu
        case .gpu: Theme.gpu
        case .mem: Theme.mem
        case .secondary: Theme.textSecondary
        }
    }
}

extension Format.TempStatus {
    /// The design system's look for how warm a reading is.
    var dashboardLevel: TempLevel {
        switch self {
        case .normal: .normal
        case .warm: .warm
        case .hot: .hot
        }
    }
}

nonisolated enum DashboardLocale {
    /// The language the user reads in, for ordering names the way the dashboard's `localeCompare` does.
    static var names: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en") }
}

/// What the Devices tab remembers for as long as the app runs, whatever happens to its views in
/// between (an outage takes the tabs away and brings them back).
@Observable
final class DashboardMemory {
    static let shared = DashboardMemory()

    /// The cards whose Details are open (`details[open]` of a card in public/index.html).
    private(set) var openDetails: Set<String> = []

    func setDetails(open: Bool, for id: String) {
        if open { openDetails.insert(id) } else { openDetails.remove(id) }
    }

    /// A card that left the grid comes back as a fresh one, with its Details closed.
    func keep(only ids: Set<String>) {
        if !openDetails.isSubset(of: ids) { openDetails.formIntersection(ids) }
    }
}

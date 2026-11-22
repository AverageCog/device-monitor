import Observation
import SwiftUI

/// The five tabs, in tab-bar order.
nonisolated enum AppTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case devices, history, advanced, alerts, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: "Devices"
        case .history: "History"
        case .advanced: "Advanced"
        case .alerts: "Alerts"
        case .settings: "Settings"
        }
    }

    /// History and Advanced keep the glyphs of the dashboard's header buttons (clock, bolt).
    var systemImage: String {
        switch self {
        case .devices: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .advanced: "bolt"
        case .alerts: "bell"
        case .settings: "gearshape"
        }
    }
}

/// A sheet any screen can ask for. The tab shell presents it (`MainTabView`), so it does not
/// matter which tab is showing or which screen asked.
nonisolated enum AppSheet: String, Identifiable, Hashable, Sendable {
    /// The "+" of the dashboard: share a browser link, how to add computers (`AddDeviceSheet`).
    case addDevice
    /// The electricity price editor (`ElectricityPriceSheet`), reached from Settings and Advanced.
    case electricityPrice

    var id: String { rawValue }
}

/// Navigation state shared by every screen: which tab is showing, which device History is on and
/// which shared sheet is up. Injected with `.environment(router)`; read with
/// `@Environment(AppRouter.self)`.
@Observable
final class AppRouter {
    var selectedTab: AppTab = .devices
    /// The device the History tab shows. `nil` lets History pick the first device.
    var historyDeviceID: String?
    /// The shared sheet on show. A screen with a sheet of its own up dismisses that first.
    var sheet: AppSheet?

    #if DEBUG
    /// The debug screen covering the tabs: the component gallery or a probe (see App/Debug).
    var debugScreen: DebugScreen?
    #endif

    /// Shows a device's history from anywhere: selects it and switches to the History tab
    /// (the dashboard's `#/history/<id>`).
    func openHistory(deviceID: String) {
        historyDeviceID = deviceID
        sheet = nil
        selectedTab = .history
    }

    /// Switches to the Alerts tab.
    func showAlerts() {
        sheet = nil
        selectedTab = .alerts
    }

    /// Presents the "Add a device" sheet.
    func showAddDevice() {
        sheet = .addDevice
    }

    /// Presents the electricity price editor.
    func showElectricityPrice() {
        sheet = .electricityPrice
    }

    /// Back to the first tab with nothing selected or presented, e.g. after pairing with a different hub.
    func reset() {
        selectedTab = .devices
        historyDeviceID = nil
        sheet = nil
    }
}

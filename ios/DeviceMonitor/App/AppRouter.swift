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

/// Navigation state shared by every screen: which tab is showing and which device History is on.
/// Injected with `.environment(router)`; read with `@Environment(AppRouter.self)`.
@Observable
final class AppRouter {
    var selectedTab: AppTab = .devices
    /// The device the History tab shows. `nil` lets History pick the first device.
    var historyDeviceID: String?

    /// Shows a device's history from anywhere: selects it and switches to the History tab
    /// (the dashboard's `#/history/<id>`).
    func openHistory(for deviceID: String) {
        historyDeviceID = deviceID
        selectedTab = .history
    }

    /// Back to the first tab with nothing selected, e.g. after pairing with a different hub.
    func reset() {
        selectedTab = .devices
        historyDeviceID = nil
    }
}

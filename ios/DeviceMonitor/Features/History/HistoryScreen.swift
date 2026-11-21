import DMCore
import SwiftUI

/// The History tab: one device's readings over a window of time, as tiles and charts
/// (`#historyView` and "// ---------- history page ----------" in public/index.html).
///
/// Which device comes from `AppRouter.historyDeviceID` (the dashboard's `#/history/<id>`); with
/// none, or one the hub no longer knows, it is the first device in the dashboard's order.
struct HistoryScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    #if DEBUG
    /// Launch arguments, or what a preview asks for. See `HistoryDebugOptions`.
    private let debug: HistoryDebugOptions

    init(debug: HistoryDebugOptions = .current) {
        self.debug = debug
    }
    #else
    init() {}
    #endif

    var body: some View {
        #if DEBUG
        HistoryRoot(store: store, preferences: preferences, debug: debug)
            .navigationTitle(AppTab.history.title)
        #else
        HistoryRoot(store: store, preferences: preferences)
            .navigationTitle(AppTab.history.title)
        #endif
    }
}

/// Owns the page's state and ties it to what happens around it: the device the router names, the
/// unit, the connection coming back, and the page being on screen.
private struct HistoryRoot: View {
    private let store: HubStore
    private let preferences: Preferences
    @State private var controller: HistoryController

    #if DEBUG
    init(store: HubStore, preferences: Preferences, debug: HistoryDebugOptions) {
        self.store = store
        self.preferences = preferences
        let controller = HistoryController(store: store, preferences: preferences)
        debug.prepare(controller)
        _controller = State(wrappedValue: controller)
    }
    #else
    init(store: HubStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        _controller = State(wrappedValue: HistoryController(store: store, preferences: preferences))
    }
    #endif

    var body: some View {
        HistoryPage(controller: controller)
            .background { HistoryDeviceTracker(controller: controller) }
            .onChange(of: preferences.temperatureUnit) { _, unit in
                controller.setUnit(unit)
            }
            // Back from an outage or from the background: what failed is asked again, and the
            // window moves up to now without waiting for the next half minute.
            .onChange(of: store.isLive) { _, isLive in
                if isLive { controller.tick() }
            }
            // From appearing to disappearing: a tab that is not showing asks the hub for nothing.
            .task { await controller.run() }
            .onDisappear { controller.leave() }
    }
}

/// Follows the device list for the page, so that the page does not have to: it changes with every
/// report, and the page only cares when the device to show does.
private struct HistoryDeviceTracker: View {
    let controller: HistoryController

    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        Color.clear
            .onChange(of: selected, initial: true) { _, id in
                controller.select(device: id)
                // hv.id = id: the device shown is the one History opens with next time, also after
                // falling back from one that was removed.
                if let id, router.historyDeviceID != id { router.historyDeviceID = id }
            }
            .accessibilityHidden(true)
    }

    /// `hv.id && devices.has(hv.id) ? hv.id : first ? first.id : ''`
    private var selected: String? {
        #if DEBUG
        if controller.debug.scenario == .noDevices { return nil }
        #endif
        return HistoryDeviceChipModel.defaultDevice(among: store.devices, last: router.historyDeviceID)
    }
}

#Preview("History") {
    NavigationStack { HistoryScreen().dmScreen() }
        .demoEnvironment(tab: .history)
}

// The other states are set up with the History tab's DEBUG launch arguments.
#if DEBUG
/// Opens a preview on a given device, as `AppRouter.openHistory(deviceID:)` would.
private struct HistoryPreviewDevice: ViewModifier {
    let id: String
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.onAppear { router.historyDeviceID = id }
    }
}

#Preview("Zoomed, inspecting") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-zoom", "0.3,0.7", "-dm-history-inspect", "0.6"])).dmScreen() }
        .demoEnvironment(tab: .history)
}

#Preview("Thirty days, Fahrenheit") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-range", "30d", "-dm-history-unit", "F"])).dmScreen() }
        .demoEnvironment(tab: .history)
}

#Preview("Offline device") {
    NavigationStack { HistoryScreen().dmScreen() }
        .modifier(HistoryPreviewDevice(id: "htpc"))
        .demoEnvironment(tab: .history)
}

#Preview("Loading") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-state", "loading"])).dmScreen() }
        .demoEnvironment(tab: .history)
}

#Preview("No history") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-state", "empty"])).dmScreen() }
        .demoEnvironment(tab: .history)
}

#Preview("Failed") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-state", "error"])).dmScreen() }
        .demoEnvironment(tab: .history)
}

#Preview("No devices") {
    NavigationStack { HistoryScreen(debug: HistoryDebugOptions(arguments: ["-dm-history-state", "no-devices"])).dmScreen() }
        .demoEnvironment(tab: .history)
}
#endif

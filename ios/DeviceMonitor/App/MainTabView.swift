import DMCore
import SwiftUI

/// The five-tab shell. Each tab owns a navigation stack; the router owns the selection and the
/// shared sheets, so any screen can switch tabs or present one (see `AppRouter`).
struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(HubStore.self) private var store

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                        .dmScreen()
                }
                // Above the tab bar on every tab, so no screen has to say it itself.
                .safeAreaInset(edge: .bottom, spacing: 0) { ReconnectingBanner() }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .badge(tab == .alerts ? store.alerts.active.count : 0)
                .tag(tab)
            }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .addDevice: AddDeviceSheet()
            case .electricityPrice: ElectricityPriceSheet()
            }
        }
        #if DEBUG
        .fullScreenCover(item: $router.debugScreen) { screen in
            DebugScreenHost(screen: screen)
        }
        #endif
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .devices: DashboardScreen()
        case .history: HistoryScreen()
        case .advanced: AdvancedScreen()
        case .alerts: AlertsScreen()
        case .settings: SettingsScreen()
        }
    }
}

/// "Reconnecting to hub…" while the live stream is down and what is on show is the last known
/// state (`#summaryText` of the dashboard). After ten seconds the session shows the unreachable
/// screen instead.
struct ReconnectingBanner: View {
    @Environment(HubStore.self) private var store
    /// The outage the banner is up for.
    @State private var shownSince: Double?

    /// Coming back to the app reconnects in a moment; saying so each time would only flicker.
    private static let delay: Duration = .milliseconds(1200)

    var body: some View {
        let since = lostSince
        Group {
            if let since, since == shownSince {
                BannerView(FleetCounts.reconnectingText, showsProgress: true)
                    .padding(.horizontal, Theme.Layout.screenPaddingCompact)
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityIdentifier("reconnecting-banner")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shownSince)
        .task(id: since) {
            guard let since else {
                shownSince = nil
                return
            }
            try? await Task.sleep(for: Self.delay)
            if !Task.isCancelled { shownSince = since }
        }
    }

    private var lostSince: Double? {
        if case .reconnecting(let since) = store.connection { since } else { nil }
    }
}

#Preview("Tabs") {
    RootView()
        .demoEnvironment()
}

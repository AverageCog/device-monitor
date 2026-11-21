import SwiftUI

/// The five-tab shell. Each tab owns a navigation stack; the router owns the selection, so any
/// screen can switch tabs (see `AppRouter.openHistory(for:)`).
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                        .dmScreen()
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
            }
        }
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

#Preview("Tabs") {
    MainTabView()
        .environment(AppRouter())
        .environment(PlaceholderSession(phase: .live))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}

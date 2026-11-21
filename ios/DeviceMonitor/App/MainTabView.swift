import DMCore
import SwiftUI

/// The five-tab shell. Each tab owns a navigation stack; the router owns the selection and the
/// shared sheets, so any screen can switch tabs or present one (see `AppRouter`).
struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(HubStore.self) private var store
    /// The outage the "Reconnecting to hub…" banners are up for.
    @State private var shownOutage: Double?

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                        .dmScreen()
                }
                // Above the tab bar on every tab, so no screen has to say it itself.
                .safeAreaInset(edge: .bottom, spacing: 0) { ReconnectingBanner(isShown: lostSince != nil && lostSince == shownOutage) }
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
        // Followed here rather than by the banners: there is one on each tab, and VoiceOver is
        // to hear of an outage once.
        .task(id: lostSince) { await follow(outageSince: lostSince) }
        #if DEBUG
        .fullScreenCover(item: $router.debugScreen) { screen in
            DebugScreenHost(screen: screen)
        }
        #endif
    }

    private var lostSince: Double? {
        if case .reconnecting(let since) = store.connection { since } else { nil }
    }

    /// Puts the banners up once an outage has lasted a moment and tells VoiceOver, whose user would
    /// otherwise read on through figures that have stopped updating. When the stream is back, it
    /// says that too.
    private func follow(outageSince since: Double?) async {
        guard let since else {
            // Going to the background or being refused ends an outage as well, with nothing back.
            if shownOutage != nil, store.isLive { ReconnectingBanner.announce(ReconnectingBanner.reconnectedText, urgently: false) }
            shownOutage = nil
            return
        }
        try? await Task.sleep(for: ReconnectingBanner.delay)
        guard !Task.isCancelled else { return }
        shownOutage = since
        ReconnectingBanner.announce(FleetCounts.reconnectingText, urgently: true)
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
/// screen instead. `MainTabView` says when.
struct ReconnectingBanner: View {
    let isShown: Bool

    /// Coming back to the app reconnects in a moment; saying so each time would only flicker.
    static let delay: Duration = .milliseconds(1200)
    /// What VoiceOver hears when the stream is back after the banner was up.
    static let reconnectedText = "Reconnected to hub"

    var body: some View {
        Group {
            if isShown {
                BannerView(FleetCounts.reconnectingText, showsProgress: true)
                    .padding(.horizontal, Theme.Layout.screenPaddingCompact)
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityIdentifier("reconnecting-banner")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShown)
    }

    /// - Parameter urgently: Spoken over whatever VoiceOver is reading, rather than after it.
    static func announce(_ text: String, urgently: Bool) {
        var announcement = AttributedString(text)
        if urgently { announcement.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(announcement).post()
        #if DEBUG
        AnnouncementProbe.record(text)
        #endif
    }
}

#Preview("Tabs") {
    RootView()
        .demoEnvironment()
}

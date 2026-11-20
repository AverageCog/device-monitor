import SwiftUI

@main
struct DeviceMonitorApp: App {
    @State private var router: AppRouter
    // PLACEHOLDER — the next wave swaps this for the DMCore-backed store (see AppPhase.swift).
    @State private var session: PlaceholderSession

    init() {
        let router = AppRouter()
        #if DEBUG
        // `-dm-phase` / `-dm-tab` start the app somewhere else; see DebugLaunchOptions.
        let options = DebugLaunchOptions.current
        if let tab = options.tab { router.selectedTab = tab }
        let phase = options.phase ?? .onboarding
        #else
        let phase = AppPhase.onboarding
        #endif
        _router = State(initialValue: router)
        _session = State(initialValue: PlaceholderSession(phase: phase))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(session)
                // The palette is dark only; Info.plist pins UIUserInterfaceStyle as well so system
                // surfaces (launch screen, alerts) never flash light.
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

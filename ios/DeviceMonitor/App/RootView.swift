import DMCore
import SwiftUI

/// Switches between the app's phases: pairing, connecting, the tabs, and the two failure screens.
struct RootView: View {
    @Environment(SessionController.self) private var session
    @Environment(AppRouter.self) private var router

    var body: some View {
        let phase = session.phase
        ZStack {
            Theme.page.ignoresSafeArea()
            switch phase {
            case .onboarding:
                OnboardingScreen()
            case .connecting:
                ConnectingScreen()
            case .live:
                // The tabs exist only while live, so no screen under them has to think about
                // being covered. The router outlives them: after an outage the user is back on
                // the tab, and the History device, they were on.
                if let store = session.store {
                    MainTabView()
                        .environment(store)
                        // Another hub, another set of tabs.
                        .id(ObjectIdentifier(store))
                }
            case .unreachable:
                UnreachableScreen()
            case .revoked:
                RevokedScreen()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .onChange(of: phase) { _, phase in
            switch phase {
            // A new pairing starts on the first tab rather than wherever the last hub left off.
            case .onboarding: router.reset()
            case .live: break
            // A shared sheet would come straight back with the tabs.
            case .connecting, .unreachable, .revoked: router.sheet = nil
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { SessionProbe() }
        #endif
    }
}

#Preview("Onboarding") {
    RootView()
        .demoEnvironment(.onboarding)
}

#Preview("Demo") {
    RootView()
        .demoEnvironment()
}

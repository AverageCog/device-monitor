import SwiftUI

/// Switches between the app's phases: pairing, connecting, the tabs, and the two failure screens.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    // PLACEHOLDER — becomes the DMCore-backed store in the next wave.
    @Environment(PlaceholderSession.self) private var session

    var body: some View {
        ZStack {
            Theme.page.ignoresSafeArea()
            switch session.phase {
            case .onboarding:
                OnboardingScreen()
            case .connecting:
                ConnectingScreen()
            case .live:
                MainTabView()
            case .unreachable:
                UnreachableScreen(onRetry: session.retry, onChangeSetup: session.pairAgain)
            case .revoked:
                RevokedScreen(onPairAgain: session.pairAgain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.phase)
        .onChange(of: session.phase) { _, phase in
            // A new pairing starts on the first tab rather than wherever the last hub left off.
            if phase == .onboarding { router.reset() }
        }
    }
}

#Preview("Onboarding") {
    RootView()
        .environment(AppRouter())
        .environment(PlaceholderSession(phase: .onboarding))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}

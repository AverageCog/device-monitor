import DMCore
import SwiftUI

// PLACEHOLDER — the Onboarding feature (scan or paste an invitation, pair) replaces this file wholesale.
struct OnboardingScreen: View {
    @Environment(PlaceholderSession.self) private var session

    var body: some View {
        PhaseContainer {
            EmptyStateView(
                title: "Device Monitor",
                message: "Pair this device with your hub to see your computers here.",
                // Also proves the DMCore package is linked into the app.
                hint: "An invitation looks like https://your-hub\(DMCore.invitationPath)#join=…",
                systemImage: "gauge.with.dots.needle.33percent"
            ) {
                #if DEBUG
                Button("Skip pairing (debug)") { session.finishOnboarding() }
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier("debug-skip-onboarding")
                #endif
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-screen")
        }
    }
}

#Preview {
    OnboardingScreen()
        .environment(PlaceholderSession())
        .preferredColorScheme(.dark)
}

import DMCore
import SwiftUI

// INTERIM — replaced by the Onboarding feature.
/// The verified hub no longer accepts this enrollment (`SessionPhase.revoked`, the "repair" case
/// of app/offline.js). The enrollment stays stored until the user pairs again.
struct RevokedScreen: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        PhaseContainer {
            // The desktop reuses its "Can't reach the hub" page here; the hub is reachable, so say what happened.
            EmptyStateView(
                title: "Pairing no longer valid",
                // app/offline.js: "…Choose Change setup and paste a fresh desktop invitation."
                message: "The verified hub no longer accepts this enrollment. On the hub, choose + → iPhone / iPad app, then pair again with the fresh invitation."
            ) {
                Button("Pair again") { session.pairAgain() }
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier("revoked-pair-again-button")
                Button("Try again") { session.retryNow() }
                    .buttonStyle(.dm())
                    .accessibilityIdentifier("revoked-retry-button")
            }
            .frame(maxWidth: 480)
            .padding(Theme.Spacing.xl)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-revoked")
        }
    }
}

#Preview {
    RevokedScreen()
        .demoEnvironment(.onboarding)
}

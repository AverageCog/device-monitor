import DMCore
import SwiftUI

// INTERIM — replaced by the Onboarding feature.
/// Shown while the first connection to the hub is being made (`SessionPhase.connecting`).
struct ConnectingScreen: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        PhaseContainer {
            VStack(spacing: Theme.Spacing.l) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Connecting to hub…")
                    .dmFont(.body)
                    .foregroundStyle(Theme.textSecondary)
                if let origin = session.hubOriginText {
                    Text(origin)
                        .dmFont(.mono)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(Theme.Spacing.xl)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phase-connecting")
        }
    }
}

#Preview {
    ConnectingScreen()
        .demoEnvironment(.onboarding)
}

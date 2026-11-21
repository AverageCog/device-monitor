import DMCore
import SwiftUI

// INTERIM — replaced by the Onboarding feature.
/// The hub cannot be reached (`SessionPhase.unreachable`). Wording from app/offline.html and
/// app/offline.js. The session keeps retrying by itself and leaves this screen with the first
/// snapshot; "Try again" only makes the next attempt happen now.
struct UnreachableScreen: View {
    @Environment(SessionController.self) private var session
    @State private var isConfirmingChange = false

    var body: some View {
        PhaseContainer {
            VStack(spacing: Theme.Spacing.m) {
                EmptyStateView(title: "Can't reach the hub", message: message) {
                    Button(session.isRetrying ? "Trying…" : "Try again") { session.retryNow() }
                        .buttonStyle(.dm(.primary))
                        .disabled(session.isRetrying || session.isDisconnecting)
                        .accessibilityIdentifier("unreachable-retry-button")
                    Button("Change setup") { isConfirmingChange = true }
                        .buttonStyle(.dm())
                        .disabled(session.isDisconnecting)
                        .accessibilityIdentifier("unreachable-change-button")
                }
                Group {
                    if let reason = session.unreachableReason {
                        // The transport's own words: it may be this device that is offline, or
                        // not allowed on the local network.
                        Text(reason)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("unreachable-reason")
                    }
                    Text("Certificate renewals reconnect automatically. If you replaced the hub or revoked this device, use a fresh invitation.")
                        .foregroundStyle(Theme.textMuted)
                }
                .dmFont(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 480)
            .padding(Theme.Spacing.xl)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-unreachable")
        }
        .confirmationDialog("Forget this hub?", isPresented: $isConfirmingChange, titleVisibility: .visible) {
            Button("Forget hub", role: .destructive) {
                Task { await session.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pairing again needs a fresh invitation from the hub.")
        }
    }

    private var message: String {
        if case .unreachable(let message) = session.phase { message } else { "The PC hosting the dashboard may be off or asleep." }
    }
}

#Preview {
    UnreachableScreen()
        .demoEnvironment(.onboarding)
}

import DMCore
import SwiftUI

// INTERIM — replaced by the Onboarding feature (scan or paste an invitation, pair).
// Keep, under #if DEBUG, the two launch arguments that pre-fill this screen
// (`DebugLaunchOptions.current.invitation` and `.deviceName`); `-dm-autoconnect` is the shell's.
struct OnboardingScreen: View {
    @Environment(SessionController.self) private var session
    @State private var invitation = OnboardingScreen.suggestedInvitation
    @State private var name = OnboardingScreen.suggestedName

    var body: some View {
        PhaseContainer {
            VStack(spacing: Theme.Spacing.l) {
                EmptyStateView(
                    title: "Device Monitor",
                    message: "Pair this device with your hub to see your computers here.",
                    systemImage: "gauge.with.dots.needle.33percent"
                )
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("On the hub, choose + → iPhone / iPad app, and paste the invitation it shows.")
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.Spacing.xs)
                    SectionLabel("Invitation")
                    // Hidden as it is typed: until it is used, the invitation lets anyone in.
                    SecureField("https://your-hub\(DMCoreInfo.invitationPath)#join=…", text: $invitation)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        // Keeps the keyboard from offering to save it as a password.
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .dmField(isInvalid: session.pairingError != nil)
                        .accessibilityLabel("Invitation")
                        .accessibilityIdentifier("pair-invitation-field")
                    SectionLabel("Name shown on the hub")
                        .padding(.top, Theme.Spacing.xs)
                    TextField("iPhone", text: $name)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .dmField()
                        .accessibilityLabel("Name shown on the hub")
                        .accessibilityIdentifier("pair-name-field")
                    if let error = session.pairingError {
                        Text(error)
                            .dmFont(.caption)
                            .foregroundStyle(Theme.dangerText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pair-error")
                    }
                }
                VStack(spacing: Theme.Spacing.s) {
                    Button(session.isPairing ? "Connecting…" : "Connect", action: connect)
                        .buttonStyle(.dm(.primary, size: .large, fillsWidth: true))
                        .disabled(session.isPairing || invitation.isEmpty)
                        .accessibilityIdentifier("pair-connect-button")
                    Button("Try the demo") { session.startDemo() }
                        .buttonStyle(.dm(size: .large, fillsWidth: true))
                        .disabled(session.isPairing)
                        .accessibilityIdentifier("pair-demo-button")
                }
                Text("interim — replaced by the Onboarding feature")
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: 420)
            .padding(Theme.Spacing.xl)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-screen")
        }
    }

    private func connect() {
        guard !session.isPairing, !invitation.isEmpty else { return }
        Task { await session.pair(invitationText: invitation, name: name) }
    }

    private static var suggestedInvitation: String {
        #if DEBUG
        DebugLaunchOptions.current.invitation ?? ""
        #else
        ""
        #endif
    }

    private static var suggestedName: String {
        #if DEBUG
        DebugLaunchOptions.current.deviceName ?? AppModel.deviceName
        #else
        AppModel.deviceName
        #endif
    }
}

#Preview {
    OnboardingScreen()
        .demoEnvironment(.onboarding)
}

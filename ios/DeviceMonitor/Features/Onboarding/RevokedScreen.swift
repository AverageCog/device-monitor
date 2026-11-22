import DMCore
import SwiftUI

/// The verified hub no longer accepts this enrollment (`SessionPhase.revoked`): the "repair" case
/// of app/offline.js. Nothing is retried, and the enrollment stays stored until the user pairs
/// again. The desktop reuses its "Can't reach the hub" page for this; the hub is reachable here,
/// so the screen says what did happen and how to get a fresh invitation.
struct RevokedScreen: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        OnboardingPhaseLayout { _ in
            VStack(spacing: Theme.Spacing.xl) {
                OnboardingMark(mode: .idle, badge: .revoked)
                VStack(spacing: Theme.Spacing.s) {
                    if isDemo { OnboardingTag(text: OnboardingCopy.demoTag) }
                    Text(OnboardingCopy.revokedTitle)
                        .dmFont(.emptyTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(isDemo ? OnboardingCopy.demoRevokedMessage : OnboardingCopy.revokedMessage)
                        .dmFont(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isDemo, let origin = session.hubOriginText {
                        OnboardingOriginText(origin: origin)
                    }
                }
                if !isDemo {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionLabel(OnboardingCopy.freshInvitationTitle)
                        OnboardingStepList(steps: [.openInvitation(1), .plain(2, OnboardingCopy.pairAgainStep)])
                    }
                    .padding(Theme.Spacing.l + 2)
                    .dmSurface()
                }
                OnboardingActionRow {
                    Button(isDemo ? OnboardingCopy.exitDemo : OnboardingCopy.pairAgain) { session.pairAgain() }
                        .buttonStyle(.dm(.primary))
                        .accessibilityIdentifier("revoked-pair-again-button")
                    // In case the hub was put right: asks it once more.
                    Button(OnboardingCopy.tryAgain) {
                        OnboardingHaptics.tap()
                        session.retryNow()
                    }
                    .buttonStyle(.dm())
                    .accessibilityIdentifier("revoked-retry-button")
                }
                Text(isDemo ? OnboardingCopy.demoRevokedHint : OnboardingCopy.revokedHint)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-revoked")
        }
    }

    private var isDemo: Bool {
        #if DEBUG
        if OnboardingDebugOptions.current.actsAsDemo { return true }
        #endif
        return session.isDemo
    }
}

#Preview("Revoked, not paired") {
    RevokedScreen()
        .demoEnvironment(.onboarding)
}

#if DEBUG
#Preview("Revoked") {
    RevokedScreen()
        .onboardingPreview(.revoked)
}

#Preview("Revoked, large text") {
    RevokedScreen()
        .onboardingPreview(.revoked)
        .dynamicTypeSize(.accessibility2)
}
#endif

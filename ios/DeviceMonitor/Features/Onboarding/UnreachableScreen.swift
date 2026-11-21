import DMCore
import SwiftUI

/// The hub cannot be reached (`SessionPhase.unreachable`): app/offline.html. The session keeps
/// retrying by itself and leaves this screen with the hub's first snapshot; "Try again" only makes
/// the next attempt happen now. "Change setup" disconnects, after asking (main.js `dm:change-setup`).
struct UnreachableScreen: View {
    @Environment(SessionController.self) private var session
    @State private var isConfirmingChange = UnreachableScreen.confirmsAtLaunch

    var body: some View {
        OnboardingPhaseLayout { _ in
            VStack(spacing: Theme.Spacing.xl) {
                OnboardingMark(mode: .idle, badge: .unreachable)
                VStack(spacing: Theme.Spacing.s) {
                    if isDemo { OnboardingTag(text: OnboardingCopy.demoTag) }
                    Text(OnboardingCopy.unreachableTitle)
                        .dmFont(.emptyTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .dmFont(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                attempts
                OnboardingActionRow {
                    Button {
                        OnboardingHaptics.tap()
                        session.retryNow()
                    } label: {
                        OnboardingSwappingLabel(OnboardingCopy.tryAgain, busy: OnboardingCopy.retrying, isBusy: isRetrying)
                    }
                    .buttonStyle(.dm(.primary))
                    .disabled(isRetrying || session.isDisconnecting)
                    .accessibilityIdentifier("unreachable-retry-button")

                    Button {
                        // Nothing is paired in the demo, so there is nothing to be sure about.
                        if session.isDemo { leave() } else { isConfirmingChange = true }
                    } label: {
                        OnboardingSwappingLabel(
                            isDemo ? OnboardingCopy.exitDemo : OnboardingCopy.changeSetup,
                            busy: OnboardingCopy.disconnecting, isBusy: session.isDisconnecting)
                    }
                    .buttonStyle(.dm())
                    .disabled(session.isDisconnecting)
                    .accessibilityIdentifier("unreachable-change-button")
                    // On the button, so that where the question is a popover it points at it.
                    .confirmationDialog(OnboardingCopy.changeSetupQuestion, isPresented: $isConfirmingChange, titleVisibility: .visible) {
                        Button(OnboardingCopy.forgetHub, role: .destructive, action: leave)
                        Button(OnboardingCopy.cancel, role: .cancel) {}
                    } message: {
                        Text(OnboardingCopy.changeSetupConsequence)
                    }
                }
                Text(OnboardingCopy.unreachableHint)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-unreachable")
        }
        .onChange(of: session.isRetrying) { wasRetrying, isRetrying in
            // "Try again" came to nothing. When it works this screen is gone before it could say so.
            if wasRetrying, !isRetrying, case .unreachable = session.phase { OnboardingHaptics.failure() }
        }
    }

    /// The retrying, made visible: a spinner for as long as this screen is up, beside what the
    /// last attempt ran into, in the transport's own words. It may be this device that is
    /// offline, or not allowed on the local network.
    private var attempts: some View {
        let reason = session.unreachableReason
        return HStack(alignment: .center, spacing: Theme.Spacing.s + 2) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
                // The message above already says that the app keeps trying.
                .accessibilityHidden(true)
            Text(reason ?? OnboardingCopy.stillTrying)
                .dmFont(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(reason == nil ? "unreachable-status" : "unreachable-reason")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dmSurface(Theme.surface1, radius: Theme.Radius.banner)
    }

    /// app/offline.js's sentence for this hub, from the session.
    private var message: String {
        if case .unreachable(let message) = session.phase { message } else { OnboardingCopy.unreachableFallback }
    }

    private var isDemo: Bool {
        #if DEBUG
        if OnboardingDebugOptions.current.actsAsDemo { return true }
        #endif
        return session.isDemo
    }

    private var isRetrying: Bool {
        #if DEBUG
        if OnboardingDebugOptions.current.showsRetrying { return true }
        #endif
        return session.isRetrying
    }

    private func leave() {
        Task { await session.disconnect() }
    }

    private static var confirmsAtLaunch: Bool {
        #if DEBUG
        OnboardingDebugOptions.current.confirmsChange
        #else
        false
        #endif
    }
}

#Preview("Unreachable, not paired") {
    UnreachableScreen()
        .demoEnvironment(.onboarding)
}

#if DEBUG
#Preview("Unreachable") {
    UnreachableScreen()
        .onboardingPreview(.unreachable)
}

#Preview("Unreachable, large text") {
    UnreachableScreen()
        .onboardingPreview(.unreachable)
        .dynamicTypeSize(.accessibility2)
}
#endif

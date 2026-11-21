import DMCore
import SwiftUI

/// From launch, or from pairing, until the hub's first snapshot (`SessionPhase.connecting`).
/// Usually on screen for a moment only, so it is the product mark at work and one line of text.
/// When the hub takes its time the screen says what it is waiting for; after ten seconds the
/// session shows `UnreachableScreen` instead.
struct ConnectingScreen: View {
    @Environment(SessionController.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSlow = ConnectingScreen.startsSlow

    /// How long "Connecting to hub…" is all there is to say.
    private static let patience: Duration = .seconds(4)

    var body: some View {
        OnboardingPhaseLayout { _ in
            VStack(spacing: Theme.Spacing.xl) {
                OnboardingMark(mode: .seeking, size: 84)
                VStack(spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        // The mark stands still for people who asked for less motion; something
                        // must still say that the app is busy.
                        if reduceMotion {
                            ProgressView()
                                .tint(Theme.textSecondary)
                        }
                        Text(session.isDemo ? OnboardingCopy.startingDemo : OnboardingCopy.connecting)
                            .dmFont(.emptyTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if !session.isDemo, let origin = session.hubOriginText {
                        OnboardingOriginText(origin: origin)
                    }
                }
                // Takes its room from the start, so nothing moves when it appears.
                Text(OnboardingCopy.connectingSlow)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(showsSlow ? 1 : 0)
                    .accessibilityHidden(!showsSlow)
                    .accessibilityIdentifier("connecting-status")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-connecting")
        }
        .task {
            guard !isSlow, Self.becomesSlow else { return }
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isSlow = true }
            if showsSlow { AccessibilityNotification.Announcement(OnboardingCopy.connectingSlow).post() }
        }
    }

    /// The demo hub is in this app: there is no PC that could be asleep.
    private var showsSlow: Bool { isSlow && !session.isDemo }

    private static var startsSlow: Bool {
        #if DEBUG
        OnboardingDebugOptions.current.isSlow == true
        #else
        false
        #endif
    }

    private static var becomesSlow: Bool {
        #if DEBUG
        OnboardingDebugOptions.current.isSlow != false
        #else
        true
        #endif
    }
}

#Preview("Connecting") {
    ConnectingScreen()
        .demoEnvironment(.onboarding)
}

#if DEBUG
#Preview("Connecting to a hub") {
    ConnectingScreen()
        .onboardingPreview(.connecting)
}
#endif

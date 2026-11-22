import DMCore
import SwiftUI

/// First run, and every time the app is not paired (`SessionPhase.onboarding`): what the app is,
/// how to get an invitation from the hub, and the two ways to hand it over, scanning it or
/// pasting it. The phone's counterpart of "Connect to a hub" in app/setup.html.
struct OnboardingScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        OnboardingPhaseLayout(maxWidth: { Self.isWide($0, dynamicTypeSize) ? 860 : 460 }) { viewport in
            let isWide = Self.isWide(viewport.size, dynamicTypeSize)
            // One layout value for both arrangements: the form keeps its place in the view tree,
            // and with it its text and the keyboard, when the device is turned.
            let layout = isWide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Spacing.xxl))
                : AnyLayout(VStackLayout(spacing: Theme.Spacing.xl))
            layout {
                VStack(alignment: isWide ? .leading : .center, spacing: Theme.Spacing.xl) {
                    OnboardingIntro(isLeading: isWide)
                    if isWide {
                        OnboardingInstructions()
                        OnboardingDemoOffer(isLeading: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    SectionLabel(OnboardingCopy.connectTitle)
                    if !isWide { OnboardingInstructions() }
                    OnboardingPairingForm(viewport: viewport)
                }
                .padding(OnboardingPairingForm.cardPadding)
                .dmSurface()
                // The form scrolls here: the card's lower edge, which leaves its padding
                // between Connect and the keyboard.
                .id(OnboardingAnchor.fields)
                .frame(maxWidth: .infinity)

                if !isWide {
                    OnboardingDemoOffer(isLeading: false)
                        .id(OnboardingAnchor.end)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding-screen")
        }
    }

    /// Two columns where the screen is wide and not tall: a phone on its side, most iPads in
    /// landscape. One column of large text reads better than two narrow ones.
    private static func isWide(_ size: CGSize, _ dynamicTypeSize: DynamicTypeSize) -> Bool {
        size.width >= 640 && size.height < 780 && !dynamicTypeSize.isAccessibilitySize
    }
}

/// The product mark, its name and what the app does.
private struct OnboardingIntro: View {
    let isLeading: Bool

    var body: some View {
        VStack(alignment: isLeading ? .leading : .center, spacing: Theme.Spacing.m) {
            OnboardingMark(size: 60)
            VStack(alignment: isLeading ? .leading : .center, spacing: Theme.Spacing.xs + 2) {
                Text(OnboardingCopy.productName)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingCopy.tagline)
                    .dmFont(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(isLeading ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the invitation comes from, and what the hub needs for it.
private struct OnboardingInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            OnboardingStepList(steps: [.openInvitation(1), .plain(2, OnboardingCopy.scanStep)])
            Text(OnboardingCopy.requirements)
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Try the demo", for somebody who has no hub yet. Deliberately quiet: it is not why the app was
/// installed.
private struct OnboardingDemoOffer: View {
    let isLeading: Bool
    @Environment(SessionController.self) private var session

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xs) { parts }
            VStack(spacing: 0) { parts }
        }
        .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .center)
    }

    @ViewBuilder
    private var parts: some View {
        Text(OnboardingCopy.demoLead)
            .dmFont(.callout)
            .foregroundStyle(Theme.textMuted)
        Button(OnboardingCopy.demo) { session.startDemo() }
            .buttonStyle(OnboardingLinkButtonStyle())
            .disabled(session.isPairing)
            .accessibilityIdentifier("pair-demo-button")
    }
}

/// A text button with a full-height touch target.
private struct OnboardingLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingLinkButtonBody(configuration: configuration)
    }
}

private struct OnboardingLinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .dmFont(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
    }
}

#Preview("Onboarding") {
    OnboardingScreen()
        .demoEnvironment(.onboarding)
}

#Preview("Onboarding, large text") {
    OnboardingScreen()
        .demoEnvironment(.onboarding)
        .dynamicTypeSize(.accessibility2)
}

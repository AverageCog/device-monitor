import SwiftUI

/// A full-screen phase: content centred on the page background. When the content is taller than the
/// screen (a phone in landscape, large text) it scrolls instead of being clipped.
struct PhaseContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // One copy of the content, in a scroll view at least as tall as the screen. Picking between
        // a centred and a scrolling copy (ViewThatFits) rebuilds the content each time the keyboard,
        // a rotation or the text size tips it over, and its state and keyboard focus go with it.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.page.ignoresSafeArea())
    }
}

/// Shown while the first connection to the hub is being made.
struct ConnectingScreen: View {
    var body: some View {
        PhaseContainer {
            VStack(spacing: Theme.Spacing.l) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Connecting to hub…")
                    .dmFont(.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Spacing.xl)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phase-connecting")
        }
    }
}

/// The hub cannot be reached. Wording from app/offline.html.
struct UnreachableScreen: View {
    /// Why, when known, e.g. "Could not connect to https://… and verify its identity. Retrying automatically."
    var message = "The PC hosting the dashboard may be off or asleep."
    let onRetry: () -> Void
    let onChangeSetup: () -> Void

    var body: some View {
        PhaseContainer {
            EmptyStateView(
                title: "Can't reach the hub",
                message: message,
                hint: "Certificate renewals reconnect automatically. If you replaced the hub or revoked this device, use a fresh invitation."
            ) {
                Button("Try again", action: onRetry)
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier("unreachable-retry-button")
                Button("Change setup", action: onChangeSetup)
                    .buttonStyle(.dm())
                    .accessibilityIdentifier("unreachable-change-button")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-unreachable")
        }
    }
}

/// The verified hub no longer accepts this enrollment (the "repair" case of app/offline.js).
struct RevokedScreen: View {
    let onPairAgain: () -> Void

    var body: some View {
        PhaseContainer {
            // The desktop reuses its "Can't reach the hub" page here; the hub is reachable, so say what happened.
            EmptyStateView(
                title: "Pairing no longer valid",
                message: "The verified hub no longer accepts this enrollment. Pair again with a fresh invitation from the hub.",
                actionTitle: "Pair again",
                action: onPairAgain
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-revoked")
        }
    }
}

#Preview("Unreachable") {
    UnreachableScreen(onRetry: {}, onChangeSetup: {})
        .preferredColorScheme(.dark)
}

#Preview("Revoked") {
    RevokedScreen(onPairAgain: {})
        .preferredColorScheme(.dark)
}

#Preview("Connecting") {
    ConnectingScreen()
        .preferredColorScheme(.dark)
}

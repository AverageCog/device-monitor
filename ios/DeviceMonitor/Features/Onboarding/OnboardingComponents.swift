import SwiftUI
import UIKit

/// What a phase screen's content is told about the scroll view it sits in.
struct OnboardingViewport {
    /// Scrolls the screen to one of its views.
    let scroll: ScrollViewProxy
    /// The height on show: the screen less the safe areas and the keyboard.
    let visibleHeight: CGFloat
    /// The screen's size, the keyboard not counted: what a layout may depend on without
    /// rearranging itself whenever the keyboard comes or goes.
    let size: CGSize
}

/// The frame of the four phase screens: the content centred on the page at a readable width,
/// scrolling when it is taller than what is on show (a phone on its side, large text, the keyboard).
struct OnboardingPhaseLayout<Content: View>: View {
    /// The content is not laid out wider than this, however wide the screen.
    var maxWidth: (CGSize) -> CGFloat = { _ in 460 }
    @ViewBuilder var content: (OnboardingViewport) -> Content

    @State private var visibleHeight: CGFloat = 0
    @State private var size: CGSize = .zero

    var body: some View {
        #if DEBUG
        if let canvas = OnboardingDebugOptions.current.canvas {
            OnboardingDebugCanvas(size: canvas) { screen }
        } else {
            screen
        }
        #else
        screen
        #endif
    }

    private var screen: some View {
        ScrollViewReader { proxy in
            PhaseContainer {
                content(OnboardingViewport(scroll: proxy, visibleHeight: visibleHeight, size: size))
                    .frame(maxWidth: maxWidth(size))
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { visibleHeight = $0 })
            .background {
                Color.clear
                    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size = $0 })
                    .ignoresSafeArea(.keyboard)
            }
            // There is no navigation bar here, so what scrolls up would pass behind the clock.
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Theme.page
                        .ignoresSafeArea(edges: .top)
                        .frame(height: 0)
                    LinearGradient(colors: [Theme.page, Theme.page.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Theme.Spacing.m)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// The places a phase screen scrolls itself to.
enum OnboardingAnchor: Hashable {
    /// The card that holds the pairing form: its lower edge is just under Connect.
    case fields
    /// The last thing on the screen.
    case end
}

/// Numbered instructions (`.opt ul` of app/setup.html, as steps).
struct OnboardingStepList: View {
    struct Step: Identifiable {
        let id: Int
        let text: Text
        /// What VoiceOver reads; the text may hold symbols that do not read well.
        let spoken: String
    }

    let steps: [Step]

    @ScaledMetric(relativeTo: .callout) private var badgeSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s + 2) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s + 2) {
                    Text(String(step.id))
                        .dmFont(.captionStrong)
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .frame(width: badgeSize, height: badgeSize)
                        .background(Theme.accent.opacity(0.14), in: Circle())
                    step.text
                        .dmFont(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step.id): \(step.spoken)")
            }
        }
    }
}

extension OnboardingStepList.Step {
    /// "On the computer that hosts Device Monitor, open + → iPhone / iPad app."
    static func openInvitation(_ id: Int) -> Self {
        let menu = Text(OnboardingCopy.invitationMenu).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
        return Self(
            id: id,
            text: Text("\(OnboardingCopy.hostStepLead) \(menu)."),
            spoken: "\(OnboardingCopy.hostStepLead) \(OnboardingCopy.invitationMenuSpoken).")
    }

    static func plain(_ id: Int, _ text: String) -> Self {
        Self(id: id, text: Text(text), spoken: text)
    }
}

/// The actions of a phase screen: side by side while their labels fit, stacked at large text sizes
/// (the buttons of app/offline.html).
struct OnboardingActionRow<Actions: View>: View {
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) { actions }
            VStack(spacing: Theme.Spacing.s) { actions }
        }
    }
}

/// A button title that changes while its action is under way without changing the button's
/// width: both titles take their room, one of them shows.
struct OnboardingSwappingLabel: View {
    private let title: String
    private let busy: String
    private let isBusy: Bool

    init(_ title: String, busy: String, isBusy: Bool) {
        self.title = title
        self.busy = busy
        self.isBusy = isBusy
    }

    var body: some View {
        ZStack {
            Text(title).opacity(isBusy ? 0 : 1)
            Text(busy).opacity(isBusy ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBusy ? busy : title)
    }
}

/// A small uppercase tag (`.tag` of app/setup.html).
struct OnboardingTag: View {
    let text: String

    var body: some View {
        Text(text)
            .dmFont(.statKey)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.14), in: Capsule())
    }
}

/// The hub's address, as the settings show addresses.
struct OnboardingOriginText: View {
    let origin: String

    var body: some View {
        Text(origin)
            .dmFont(.mono)
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Hub \(origin)")
    }
}

extension View {
    /// A text input of the pairing form (`input` of app/setup.html): the inset fill, a hairline
    /// border, and the accent outline while it has the keyboard.
    func onboardingField(isFocused: Bool, isInvalid: Bool = false) -> some View {
        dmFont(.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.m)
            // 44 points at the standard text size, and taller as the text grows.
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: 44)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isFocused ? Theme.accent : isInvalid ? Theme.critical : Theme.border,
                        lineWidth: isFocused ? 2 : Theme.Layout.hairline)
            }
    }
}

/// The taps of the system for the moments an iPhone app has them: a result arrived.
enum OnboardingHaptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

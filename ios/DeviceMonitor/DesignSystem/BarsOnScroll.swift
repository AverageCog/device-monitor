import DMCore
import SwiftUI

extension View {
    /// Puts the navigation bar and the tab bar away while the page is scrolled down, and brings them
    /// back when it is scrolled up or reaches its top (`BarsOnScroll`). Apply to a tab's own scroll
    /// view, inside its navigation stack. From iOS 26, whose scroll edge effect keeps the status bar
    /// legible over the page once the bars are gone; before that the bars stay.
    ///
    /// A screen pushed on top has bars of its own, and the bars are back when the page is left.
    /// With VoiceOver or Switch Control on they never go: what is in them has to stay where it is.
    ///
    /// - Parameter isPaused: Something else has the page for now and the bars stay as they are,
    ///   such as a card being dragged to a new place, which scrolls the page near the screen's edges.
    func dmHidesBarsOnScroll(isPaused: Bool = false) -> some View {
        modifier(BarsOnScrollState(isPaused: isPaused))
    }

    /// The same, for a page that puts away something of its own along with the bars: `isHidden`
    /// says when.
    func dmHidesBarsOnScroll(_ isHidden: Binding<Bool>, isPaused: Bool = false) -> some View {
        modifier(HidesBarsOnScroll(isHidden: isHidden, isPaused: isPaused))
    }
}

/// For a page that has no use for the state itself.
private struct BarsOnScrollState: ViewModifier {
    let isPaused: Bool
    @State private var isHidden = false

    func body(content: Content) -> some View {
        content.modifier(HidesBarsOnScroll(isHidden: $isHidden, isPaused: isPaused))
    }
}

private struct HidesBarsOnScroll: ViewModifier {
    @Binding var isHidden: Bool
    let isPaused: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Changes with every scroll event, so it is kept where a change redraws nothing.
    @State private var tracker = Tracker()

    /// Not observed: only the decision it comes to is.
    private final class Tracker {
        var bars = BarsOnScroll()
        var isUserScrolling = false
    }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .onScrollPhaseChange { _, phase in
                    tracker.isUserScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: BarsOnScroll.Geometry.self) { geometry in
                    BarsOnScroll.Geometry(
                        offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                        topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom,
                        viewportHeight: geometry.containerSize.height)
                } action: { _, geometry in
                    if keepsBars || isPaused {
                        tracker.bars.hold(geometry)
                    } else {
                        tracker.bars.update(geometry, byUser: tracker.isUserScrolling)
                    }
                    apply(animated: true)
                }
                .toolbarVisibility(isHidden ? .hidden : .automatic, for: .navigationBar, .tabBar)
                // Left to itself, the edge effect keeps the navigation bar's height once the bar is
                // gone: a frosted band with nothing in it. The soft one lets the page run up under
                // the status bar, with just enough of a fade there to keep the clock legible.
                .scrollEdgeEffectStyle(isHidden ? .soft : nil, for: .top)
                .onChange(of: keepsBars) { _, keeps in
                    if keeps { show(animated: true) }
                }
                // A tab left for another, or a screen pushed on top: back on it, the bars are there.
                .onDisappear { show(animated: false) }
        } else {
            content
        }
    }

    private var keepsBars: Bool { voiceOver || switchControl }

    private func show(animated: Bool) {
        tracker.bars.show()
        apply(animated: animated)
    }

    private func apply(animated: Bool) {
        let hidden = tracker.bars.isHidden
        guard hidden != isHidden else { return }
        if animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { isHidden = hidden }
        } else {
            isHidden = hidden
        }
    }
}

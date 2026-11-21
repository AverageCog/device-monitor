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
    /// - Parameters:
    ///   - isHidden: When the bars are away, for a page that puts away something of its own with them.
    ///   - isPaused: Something else has the page for now and the bars stay as they are, such as a
    ///     card being dragged to a new place, which scrolls the page near the screen's edges.
    func dmHidesBarsOnScroll(_ isHidden: Binding<Bool>, isPaused: Bool = false) -> some View {
        modifier(HidesBarsOnScroll(isHidden: isHidden, isPaused: isPaused, isTitledPage: false))
    }

    /// For a tab whose page carries its own title (`DMPageTitle`): it has no navigation bar at all,
    /// so the title scrolls away with the page rather than shrinking into a bar, and the tab bar
    /// comes and goes as with `dmHidesBarsOnScroll`. Apply to the tab's own scroll view. From
    /// iOS 26, like the title; before that the tab keeps its navigation bar and its large title.
    func dmTitledPage() -> some View {
        modifier(TitledPage())
    }
}

/// For a page that has no use for the bars' state itself.
private struct TitledPage: ViewModifier {
    @State private var isHidden = false

    func body(content: Content) -> some View {
        content.modifier(HidesBarsOnScroll(isHidden: $isHidden, isPaused: false, isTitledPage: true))
    }
}

private struct HidesBarsOnScroll: ViewModifier {
    @Binding var isHidden: Bool
    let isPaused: Bool
    /// The page has no navigation bar, only the tab bar comes and goes.
    let isTitledPage: Bool

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
                .toolbarVisibility(isTitledPage || isHidden ? .hidden : .automatic, for: .navigationBar)
                .toolbarVisibility(isHidden ? .hidden : .automatic, for: .tabBar)
                // Left to itself, the edge effect keeps the navigation bar's height once the bar is
                // gone: a frosted band with nothing in it. The soft one lets the page run up under
                // the status bar, with a light fade under the clock.
                .scrollEdgeEffectStyle(isTitledPage || isHidden ? .soft : nil, for: .top)
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

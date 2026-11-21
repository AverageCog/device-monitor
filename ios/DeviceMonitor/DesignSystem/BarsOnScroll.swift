import DMCore
import SwiftUI

extension View {
    /// For a tab whose page carries its own title (`DMPageTitle`, or the Devices tab's header): it
    /// has no navigation bar at all, so the title scrolls away with the page rather than shrinking
    /// into a bar, and the tab bar goes while the page is scrolled down and comes back when it is
    /// scrolled up or reaches its top (`BarsOnScroll`). Apply to the tab's own scroll view, inside
    /// its navigation stack. From iOS 26, like the titles; before that the tab keeps its
    /// navigation bar, and its bars stay.
    ///
    /// A screen pushed on top has bars of its own, and the tab bar is back when the page is left.
    /// With VoiceOver or Switch Control on it never goes: what is in it has to stay where it is.
    ///
    /// - Parameter isPaused: Something else has the page for now and the tab bar stays as it is,
    ///   such as a card being dragged to a new place, which scrolls the page near the screen's edges.
    func dmTitledPage(isPaused: Bool = false) -> some View {
        modifier(TitledPage(isPaused: isPaused))
    }
}

private struct TitledPage: ViewModifier {
    let isPaused: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Changes with every scroll event, so it is kept where a change redraws nothing.
    @State private var tracker = Tracker()
    @State private var isHidden = false

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
                .toolbarVisibility(.hidden, for: .navigationBar)
                .toolbarVisibility(isHidden ? .hidden : .automatic, for: .tabBar)
                // The page runs up under the status bar, with a light fade under the clock.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onChange(of: keepsBars) { _, keeps in
                    if keeps { show(animated: true) }
                }
                // A tab left for another, or a screen pushed on top: back on it, the tab bar is there.
                .onDisappear { show(animated: false) }
        } else {
            content
        }
    }

    /// The tab bar stays where it is.
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

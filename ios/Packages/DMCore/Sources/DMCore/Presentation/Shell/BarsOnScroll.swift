import Foundation

/// When a tab's top bar and the tab bar get out of the way of its page: they go while the page is
/// scrolled down, and come back as soon as it is scrolled up a little, or when it is back at its
/// top. Like Safari's bars they follow the direction of the scroll, not the position, so a page
/// left halfway down keeps them away until it is moved up again.
///
/// It is fed every change of the scroll view's geometry. Only a scroll the user makes (a drag, or
/// the fling after it) puts the bars away; a scroll the app makes, to an anchor or to the top,
/// only ever brings them back.
public struct BarsOnScroll: Sendable, Equatable {
    /// The scroll view's geometry along its vertical axis, in points.
    public struct Geometry: Sendable, Equatable {
        /// `contentOffset.y`: `-topInset` when the page is at its top.
        public var offset: Double
        public var contentHeight: Double
        /// What the bars and the screen's edges cover of the scroll view at its top and bottom.
        public var topInset: Double
        public var bottomInset: Double
        /// The scroll view's height between those (SwiftUI's `ScrollGeometry.containerSize`).
        public var viewportHeight: Double

        public init(offset: Double, contentHeight: Double, topInset: Double, bottomInset: Double, viewportHeight: Double) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.topInset = topInset
            self.bottomInset = bottomInset
            self.viewportHeight = viewportHeight
        }

        /// The offset at which the page rests at its top.
        var top: Double { -topInset }
        /// The offset at which it rests at its end. Beyond either the page is only rubber-banding.
        var bottom: Double { top + max(0, contentHeight - viewportHeight) }
        /// How far the page scrolls between the two.
        var range: Double { bottom - top }
        /// The offset, without the rubber-banding.
        var restingOffset: Double { min(max(offset, top), bottom) }
        /// How far the page is scrolled down from its top.
        var fromTop: Double { restingOffset - top }
        /// Whether the page still scrolls once the bars are away. Their going takes at most the
        /// insets from the page's ends and gives that to the viewport; a page that then fit the
        /// screen would be back at its top, which brings the bars back at once.
        var scrollsWithoutBars: Bool { range > topInset + bottomInset }

        /// Whether the page has only moved, or grown or shrunk: the bars and the screen's edges are
        /// where they were.
        func isScroll(from other: Geometry) -> Bool {
            topInset == other.topInset && bottomInset == other.bottomInset && viewportHeight == other.viewportHeight
        }
    }

    /// Scrolled down this far without turning back, the bars go.
    public static let hideDistance = 24.0
    /// Scrolled back up this far, they come back.
    public static let showDistance = 16.0
    /// They only go once the page is this far down: past a large title collapsing into the bar,
    /// and far enough that the page's top rising by the bars' height on their going (if the
    /// offset stays put) cannot leave it at its top.
    public static let hideStart = 120.0

    /// Whether the bars are away.
    public private(set) var isHidden = false
    private var last: Geometry?
    /// How far the page has moved since it last turned, down positive.
    private var travel = 0.0

    public init() {}

    /// Takes in where the page is now.
    /// - Parameter byUser: The user is scrolling it (dragging, or the fling after a drag), as
    ///   opposed to the app scrolling it or the page resting.
    public mutating func update(_ geometry: Geometry, byUser: Bool) {
        defer { last = geometry }
        if geometry.fromTop <= 0.5 {
            // At the top, whoever took it there.
            show()
            return
        }
        guard byUser, let last, geometry.isScroll(from: last) else {
            // The bars coming or going, or the screen turning, move the page's top and end
            // without anybody scrolling; what the app scrolls is not the user's to read.
            travel = 0
            return
        }
        // Clamped as `last` would be clamped now, so that a page that just got longer or shorter
        // has not moved for it.
        let delta = geometry.restingOffset - min(max(last.offset, geometry.top), geometry.bottom)
        guard delta != 0 else { return }
        if travel != 0, (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel >= Self.hideDistance, geometry.fromTop >= Self.hideStart, geometry.scrollsWithoutBars {
            isHidden = true
        } else if travel <= -Self.showDistance {
            isHidden = false
        }
    }

    /// Takes note of where the page is without moving the bars: something else has the page for
    /// now, such as a card being dragged to a new place, which scrolls it near the screen's edges.
    public mutating func hold(_ geometry: Geometry) {
        last = geometry
        travel = 0
    }

    /// Brings the bars back: the page is left, or the user needs them in place (VoiceOver).
    public mutating func show() {
        isHidden = false
        travel = 0
    }
}

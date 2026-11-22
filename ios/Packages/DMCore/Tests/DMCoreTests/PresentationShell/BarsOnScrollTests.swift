import Testing
@testable import DMCore

/// The bars of a tab going away while its page is scrolled down and coming back when it is scrolled
/// up. The geometry is an iPhone 17 Pro's, as its simulator reports it: the navigation bar and the
/// status bar above (116 points, 62 without the bar), the tab bar and the home indicator below
/// (83 points, 34 without it).
@Suite struct BarsOnScrollTests {
    private static let shownTop = 116.0, hiddenTop = 62.0
    private static let shownBottom = 83.0, hiddenBottom = 34.0
    private static let screen = 874.0

    /// The page `fromTop` points down from its top, with or without the bars.
    private func page(_ fromTop: Double, length: Double = 3000, barsHidden: Bool = false) -> BarsOnScroll.Geometry {
        let top = barsHidden ? Self.hiddenTop : Self.shownTop
        let bottom = barsHidden ? Self.hiddenBottom : Self.shownBottom
        return BarsOnScroll.Geometry(
            offset: fromTop - top, contentHeight: length, topInset: top, bottomInset: bottom,
            viewportHeight: Self.screen - top - bottom)
    }

    /// Drags the page from one place to another a few points at a time, as scroll events come.
    private func drag(_ bars: inout BarsOnScroll, from start: Double, to end: Double, length: Double = 3000, byUser: Bool = true) {
        let step = start < end ? 4.0 : -4.0
        var position = start
        while (step > 0 && position < end) || (step < 0 && position > end) {
            position += step
            bars.update(page(position, length: length, barsHidden: bars.isHidden), byUser: byUser)
        }
    }

    @Test func scrollingDownPutsTheBarsAwayAndScrollingUpBringsThemBack() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: 400)
        #expect(bars.isHidden)
        drag(&bars, from: 400, to: 380)
        #expect(!bars.isHidden)
        drag(&bars, from: 380, to: 700)
        #expect(bars.isHidden)
    }

    @Test func theyStayWhileThePageIsNearItsTop() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: BarsOnScroll.hideStart - 4)
        #expect(!bars.isHidden, "Not before the page is \(BarsOnScroll.hideStart) points down")
        drag(&bars, from: BarsOnScroll.hideStart - 4, to: BarsOnScroll.hideStart + 4)
        #expect(bars.isHidden)
    }

    @Test func aWobbleOfTheFingerMovesNothing() {
        var bars = BarsOnScroll()
        bars.update(page(300), byUser: false)
        drag(&bars, from: 300, to: 320)
        #expect(!bars.isHidden, "Twenty points down is not yet a scroll down")
        drag(&bars, from: 320, to: 400)
        #expect(bars.isHidden)
        drag(&bars, from: 400, to: 390)
        drag(&bars, from: 390, to: 420)
        #expect(bars.isHidden, "Ten points back up is not yet a scroll up")
    }

    @Test func theirGoingDoesNotReadAsAScroll() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        // The insets follow a moment after the decision.
        for position in stride(from: 4.0, through: 200, by: 4) {
            bars.update(page(position), byUser: true)
        }
        #expect(bars.isHidden)
        // SwiftUI keeps the page as far down from its top as it was: the offset moves by the
        // 54 points the top inset loses.
        bars.update(page(200, barsHidden: true), byUser: true)
        #expect(bars.isHidden)
        drag(&bars, from: 200, to: 220)
        #expect(bars.isHidden)
    }

    @Test func theirGoingDoesNotReadAsAScrollWhereTheOffsetStays() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        for position in stride(from: 4.0, through: 200, by: 4) {
            bars.update(page(position), byUser: true)
        }
        #expect(bars.isHidden)
        // A scroll view that keeps the offset instead: the page's top is 54 points higher, a jump
        // of 54 points up from the top, but no scroll up.
        var geometry = page(0, barsHidden: true)
        geometry.offset = page(200).offset
        bars.update(geometry, byUser: true)
        #expect(bars.isHidden, "Still 146 points down without the bars")
        drag(&bars, from: 146, to: 160)
        #expect(bars.isHidden)
    }

    @Test func atTheEndTheBounceBackIsNotAScrollUp() {
        let length = 1600.0
        let end = length - (Self.screen - Self.shownTop - Self.shownBottom)
        var bars = BarsOnScroll()
        bars.update(page(end - 300, length: length), byUser: false)
        drag(&bars, from: end - 300, to: end, length: length)
        #expect(bars.isHidden)
        // Without the tab bar the page ends 49 points sooner: the scroll view is pulled past its
        // end, and settles back there.
        let hiddenEnd = end - (Self.shownTop - Self.hiddenTop) - 49
        var geometry = page(hiddenEnd + 49, length: length, barsHidden: true)
        bars.update(geometry, byUser: true)
        for back in stride(from: 45.0, through: 0, by: -5) {
            geometry.offset = page(hiddenEnd + back, length: length, barsHidden: true).offset
            bars.update(geometry, byUser: true)
        }
        #expect(bars.isHidden)
    }

    @Test func pullingDownAtTheTopKeepsThem() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: -120)
        #expect(!bars.isHidden)
    }

    @Test func reachingTheTopBringsThemBack() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: 600)
        #expect(bars.isHidden)
        // `scrollTo(top)`: the app's own scroll, all the way up.
        drag(&bars, from: 600, to: 200, byUser: false)
        #expect(bars.isHidden, "What the app scrolls is not a scroll up")
        bars.update(page(0, barsHidden: true), byUser: false)
        #expect(!bars.isHidden)
    }

    @Test func whatTheAppScrollsNeverPutsThemAway() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: 1200, byUser: false)
        #expect(!bars.isHidden)
    }

    @Test func aPageThatCouldFitWithoutThemKeepsThem() {
        // As tall as the screen, it scrolls by the insets (199 points): without the bars it might
        // fit the screen and be back at its top.
        let short = Self.screen
        var bars = BarsOnScroll()
        bars.update(page(0, length: short), byUser: false)
        drag(&bars, from: 0, to: Self.shownTop + Self.shownBottom, length: short)
        #expect(!bars.isHidden)

        // Settings in the demo: 220 points of scrolling under a collapsed large title (116 above).
        let settings = BarsOnScroll.Geometry(offset: 0, contentHeight: 895, topInset: 116, bottomInset: 83, viewportHeight: 675)
        var shown = BarsOnScroll()
        shown.update(settings, byUser: false)
        for offset in stride(from: 4.0, through: 104, by: 4) {
            var next = settings
            next.offset = offset
            shown.update(next, byUser: true)
        }
        #expect(shown.isHidden, "Without the bars it still scrolls 117 points")
    }

    @Test func heldTheyStayAsTheyAre() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: 400)
        #expect(bars.isHidden)
        // A card dragged to the top edge scrolls the page up; then the user scrolls on down.
        for position in stride(from: 396.0, through: 300, by: -4) {
            bars.hold(page(position, barsHidden: true))
        }
        #expect(bars.isHidden)
        drag(&bars, from: 300, to: 310)
        #expect(bars.isHidden, "The scroll down goes on from where the hold left it, not from 400")

        var shown = BarsOnScroll()
        shown.update(page(0), byUser: false)
        for position in stride(from: 4.0, through: 500, by: 4) {
            shown.hold(page(position))
        }
        #expect(!shown.isHidden)
        shown.update(page(504), byUser: true)
        #expect(!shown.isHidden, "Four points down is not a scroll down")
    }

    @Test func showBringsThemBackAndStartsAfresh() {
        var bars = BarsOnScroll()
        bars.update(page(0), byUser: false)
        drag(&bars, from: 0, to: 400)
        #expect(bars.isHidden)
        bars.show()
        #expect(!bars.isHidden)
        drag(&bars, from: 400, to: 420)
        #expect(!bars.isHidden, "Twenty points down after coming back is not yet a scroll down")
    }
}

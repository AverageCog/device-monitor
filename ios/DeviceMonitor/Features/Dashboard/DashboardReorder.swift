import DMCore
import Observation
import SwiftUI
import UIKit

/// Dragging a card to a new place in the grid, ported from `startDrag`, `follow` and `maybeReorder`
/// in public/index.html: the card follows the finger, the others move out of its way, and on
/// release the new order goes to the hub.
///
/// The card in the air is a copy drawn over the grid (`DashboardLiftedCard`); the card itself stays
/// in the grid, blank, and marks where the copy will land. Hit-testing uses the cards' layout
/// frames, which an animation does not move, so cards gliding past never flicker back.
@Observable
final class DashboardReorderModel {
    /// The coordinate space of the grid: every frame and point here is in it.
    nonisolated static let coordinateSpace = "dashboard-grid"
    /// `cubic-bezier(.2, .8, .2, 1)` over 260 ms: how the other cards glide.
    static let glide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)
    /// The same curve over 220 ms: the dropped card settling into its slot.
    static let settle = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    /// The part of a card that takes the drag, from its top leading corner: the grip with a
    /// 44-point reach around it.
    nonisolated static let gripReach = CGSize(width: 44, height: 52)

    // MARK: Observed by the grid

    /// The order on show while it is not the store's: during a drag, and until the store has it.
    private(set) var order: [String]?
    /// The card in the air.
    private(set) var liftedID: String?

    // MARK: Observed by the lifted copy

    /// Top leading corner of the lifted card.
    private(set) var liftOrigin = CGPoint.zero
    private(set) var liftSize = CGSize.zero
    /// True while the dropped card glides into its slot.
    private(set) var isSettling = false

    // MARK: Not observed

    @ObservationIgnored private var frames: [String: CGRect] = [:]
    /// From the lifted card's corner to the finger.
    @ObservationIgnored private var grab = CGPoint.zero
    /// The finger when the drag began, in the grid and in the window.
    @ObservationIgnored private var startPointer = CGPoint.zero
    @ObservationIgnored private var startWindowPoint = CGPoint.zero
    @ObservationIgnored private var lastWindowPoint = CGPoint.zero
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var startOffset: CGFloat = 0
    /// The card last swapped with: nothing swaps back until the finger has left it.
    @ObservationIgnored private var lastOver: String?
    @ObservationIgnored private var scroller: Task<Void, Never>?
    /// Counts drags and moves, so that what a finished one left running knows it was overtaken.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let lift = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let tick = UISelectionFeedbackGenerator()
    @ObservationIgnored private let drop = UIImpactFeedbackGenerator(style: .light)

    /// Reduce Motion: cards change places without gliding.
    private var isMotionReduced: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: Layout

    /// The grid reports where each card is.
    func setFrame(_ frame: CGRect, for id: String) {
        frames[id] = frame
    }

    func forgetFrame(of id: String) {
        frames[id] = nil
    }

    /// The online devices in the order to show them: the store's, unless a drag says otherwise.
    func arranged(_ devices: [Device]) -> [Device] {
        guard let order else { return devices }
        let byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return arranged(devices.map(\.id), by: order).compactMap { byID[$0] }
    }

    func arranged(_ ids: [String]) -> [String] {
        order.map { arranged(ids, by: $0) } ?? ids
    }

    /// `ids` as `order` has them; an id the order does not know (a device that came online
    /// meanwhile) goes last.
    private func arranged(_ ids: [String], by order: [String]) -> [String] {
        let present = Set(ids), known = Set(order)
        return order.filter(present.contains) + ids.filter { !known.contains($0) }
    }

    // MARK: Dragging

    /// The finger has taken hold of a card's grip.
    /// - Parameters:
    ///   - point: where, from the card's top leading corner.
    ///   - windowPoint: the same in the window; later positions are measured against it.
    ///   - scrollView: the grid's scroll view, to scroll when the finger nears an edge.
    ///   - online: the ids of the cards in the grid, in the store's order.
    func begin(id: String, at point: CGPoint, windowPoint: CGPoint, scrollView: UIScrollView?, online: [String]) {
        guard let frame = frames[id], online.contains(id) else { return }
        // A card still settling from the last drag is in its slot as far as layout goes.
        finishSettling()
        generation += 1
        order = arranged(online)
        liftedID = id
        liftSize = frame.size
        liftOrigin = frame.origin
        isSettling = false
        grab = point
        startPointer = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
        startWindowPoint = windowPoint
        lastWindowPoint = windowPoint
        self.scrollView = scrollView
        startOffset = scrollView?.contentOffset.y ?? 0
        lastOver = nil
        lift.impactOccurred()
        tick.prepare()
        scroller?.cancel()
        scroller = Task { [weak self] in
            // setInterval(…, 16): scroll while the finger rests near the top or bottom edge.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.scrollNearEdges()
            }
        }
    }

    /// The finger moved.
    func move(windowPoint: CGPoint) {
        guard liftedID != nil, !isSettling else { return }
        lastWindowPoint = windowPoint
        follow()
    }

    /// The finger lifted, or the system took the touch away: either way the card lands where it is,
    /// as `pointerup` and `pointercancel` both end a drag on the dashboard.
    func end(store: HubStore, failures: DashboardDeviceActionModel) {
        scroller?.cancel()
        scroller = nil
        guard let id = liftedID, !isSettling else { return }
        drop.impactOccurred()
        let ids = order ?? []
        if let slot = frames[id], !isMotionReduced {
            let generation = generation
            withAnimation(Self.settle) {
                liftOrigin = slot.origin
                isSettling = true
            } completion: { [weak self] in
                if self?.generation == generation { self?.finishSettling() }
            }
        } else {
            finishSettling()
        }
        commit(ids, store: store, failures: failures)
    }

    private func finishSettling() {
        liftedID = nil
        isSettling = false
    }

    /// `follow()`: the lifted card goes where the finger is, wherever its slot has moved to.
    private func follow() {
        // The content may have scrolled under a finger that did not move.
        let scrolled = (scrollView?.contentOffset.y ?? startOffset) - startOffset
        let pointer = CGPoint(
            x: startPointer.x + lastWindowPoint.x - startWindowPoint.x,
            y: startPointer.y + lastWindowPoint.y - startWindowPoint.y + scrolled)
        liftOrigin = CGPoint(x: pointer.x - grab.x, y: pointer.y - grab.y)
        reorder(at: pointer)
    }

    /// `maybeReorder()`: when the finger is over another card, the lifted one takes its place.
    private func reorder(at pointer: CGPoint) {
        guard let id = liftedID, var ids = order else { return }
        guard let over = ids.first(where: { $0 != id && frames[$0]?.contains(pointer) == true }) else {
            lastOver = nil
            return
        }
        // Wait until the finger leaves it before swapping back.
        guard over != lastOver else { return }
        lastOver = over
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: over) else { return }
        // insertBefore(el, from < to ? over.nextSibling : over): either way it ends up at `to`.
        ids.remove(at: from)
        ids.insert(id, at: to)
        tick.selectionChanged()
        withAnimation(isMotionReduced ? nil : Self.glide) { order = ids }
    }

    /// Scrolls when the finger is within 70 points of the visible top or bottom, faster the nearer.
    private func scrollNearEdges() {
        guard liftedID != nil, !isSettling, let scrollView, scrollView.window != nil else { return }
        let visible = scrollView.convert(scrollView.bounds, to: nil)
        let insets = scrollView.adjustedContentInset
        let top = visible.minY + insets.top, bottom = visible.maxY - insets.bottom
        let edge: CGFloat = 70, step: CGFloat = 14
        var delta: CGFloat = 0
        if lastWindowPoint.y < top + edge {
            delta = -step * min(1, (top + edge - lastWindowPoint.y) / edge)
        } else if lastWindowPoint.y > bottom - edge {
            delta = step * min(1, (lastWindowPoint.y - (bottom - edge)) / edge)
        }
        guard delta != 0 else { return }
        let lowest = -insets.top
        let highest = max(lowest, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        let target = min(highest, max(lowest, scrollView.contentOffset.y + delta))
        guard abs(target - scrollView.contentOffset.y) > 0.01 else { return }
        scrollView.contentOffset.y = target
        follow()
    }

    // MARK: Without dragging

    /// "Move up" and "Move down" for VoiceOver, Switch Control and Voice Control: one place
    /// earlier or later, sent to the hub like a drag.
    /// - Returns: the card's new position, or nil when it is already at that end.
    @discardableResult
    func move(id: String, by offset: Int, online: [String], store: HubStore, failures: DashboardDeviceActionModel) -> Int? {
        guard liftedID == nil else { return nil }
        var ids = arranged(online)
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return nil }
        ids.swapAt(from, from + offset)
        generation += 1
        withAnimation(isMotionReduced ? nil : Self.glide) { order = ids }
        commit(ids, store: store, failures: failures)
        return from + offset
    }

    // MARK: Telling the hub

    /// The visible order goes to the store, which appends the offline devices, applies the new
    /// positions at once and tells the hub only when something moved (the end of `startDrag`).
    private func commit(_ ids: [String], store: HubStore, failures: DashboardDeviceActionModel) {
        let generation = generation
        Task { [weak self] in
            do {
                try await store.reorder(ids: ids)
            } catch {
                // Not undone, as on the dashboard: the hub's order returns with its next snapshot.
                failures.report(DashboardStrings.reorderFailed, HubError(error))
            }
            // The store has had the order since the call began; ours has done its work.
            if let self, self.generation == generation { self.order = nil }
        }
    }

    #if DEBUG
    /// Shows a card as it looks in the air, moved from its place. For screenshots.
    func debugLift(id: String, dx: Double, dy: Double, online: [String]) {
        guard let frame = frames[id], online.contains(id) else { return }
        generation += 1
        order = online
        liftedID = id
        liftSize = frame.size
        liftOrigin = CGPoint(x: frame.minX + dx, y: frame.minY + dy)
        isSettling = false
    }
    #endif
}

/// The touch surface over a card's grip. It takes the finger after a short hold, so that a swipe
/// that happens to start on the grip still scrolls; once it has the touch, the scroll view does not
/// pan (UIKit lets one recogniser of a touch win).
///
/// Positions are reported in the surface's own coordinates when the drag begins, which is how the
/// model learns where in the card the finger is, and in the window afterwards, because the surface
/// itself moves with its card as the order changes.
struct DashboardGripSurface: UIViewRepresentable {
    var onBegan: (_ point: CGPoint, _ windowPoint: CGPoint, _ scrollView: UIScrollView?) -> Void
    var onMoved: (_ windowPoint: CGPoint) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = 0.12
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject {
        var surface: DashboardGripSurface

        init(surface: DashboardGripSurface) {
            self.surface = surface
        }

        @objc func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let view = recognizer.view else { return }
                surface.onBegan(recognizer.location(in: view), recognizer.location(in: nil), Self.scrollView(around: view))
            case .changed:
                surface.onMoved(recognizer.location(in: nil))
            case .ended, .cancelled, .failed:
                surface.onEnded()
            default:
                break
            }
        }

        private static func scrollView(around view: UIView) -> UIScrollView? {
            var candidate = view.superview
            while let current = candidate {
                if let found = current as? UIScrollView { return found }
                candidate = current.superview
            }
            return nil
        }
    }
}

/// The card being dragged, drawn over the grid where the finger has it
/// (`.card.dragging`: accent outline, deep shadow, 2 % larger).
struct DashboardLiftedCard: View {
    @Environment(DashboardReorderModel.self) private var reorder

    var body: some View {
        if let id = reorder.liftedID {
            DashboardLiftedCardBody(id: id)
        }
    }
}

private struct DashboardLiftedCardBody: View {
    let id: String

    @Environment(HubStore.self) private var store
    @Environment(DashboardReorderModel.self) private var reorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRaised = false

    var body: some View {
        if let device = store.device(id) {
            let raised = (isRaised || reduceMotion) && !reorder.isSettling
            DashboardCard(
                device: device, series: store.series(for: id), isDetailsOpen: DashboardMemory.shared.openDetails.contains(id),
                index: 0, count: 1, role: .lifted
            )
            // Redrawn when its device reports, not each time the finger moves.
            .equatable()
            .frame(width: reorder.liftSize.width, height: reorder.liftSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(raised ? 1 : 0), lineWidth: 2)
            }
            .compositingGroup()
            // box-shadow: 0 24px 60px rgba(0,0,0,.65)
            .shadow(color: .black.opacity(raised ? 0.65 : 0), radius: 30, y: 24)
            .scaleEffect(raised ? 1.02 : 1)
            .offset(x: reorder.liftOrigin.x, y: reorder.liftOrigin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { isRaised = true }
            }
        }
    }
}

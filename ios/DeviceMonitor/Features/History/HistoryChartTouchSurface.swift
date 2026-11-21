import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What a finger does on a history chart. Positions are horizontal, from the chart's leading edge.
nonisolated enum HistoryChartTouch: Equatable, Sendable {
    /// Resting on the chart, then moving: the crosshair follows.
    case point(x: CGFloat)
    /// A pointer over the chart, no button pressed.
    case hover(x: CGFloat)
    /// The finger lifted, or the pointer left.
    case pointEnded
    /// A sideways drag that began at `start` and has reached `x`.
    case selectionBegan(start: CGFloat, x: CGFloat)
    case selectionMoved(x: CGFloat)
    /// `commit` is false when the system took the touch away.
    case selectionEnded(commit: Bool)
    /// Two fingers around `x`.
    case pinchBegan(x: CGFloat)
    case pinchMoved(scale: CGFloat)
    case pinchEnded(scale: CGFloat, commit: Bool)
    case doubleTap
}

/// A transparent view over a history chart that turns touches into `HistoryChartTouch`es:
///
/// - touch and hold, then move: point at a moment (the dashboard's hover);
/// - drag sideways straight away: select a stretch to zoom into (the dashboard's mouse drag);
/// - spread two fingers: the same, around the fingers;
/// - double tap: leave the zoom;
/// - anything that starts up or down is left to the page, which scrolls.
///
/// These are UIKit recognisers because the decisions have to be made against the scroll view's
/// own pan: which way a drag started, and whether the finger rested first. A SwiftUI `DragGesture`
/// on a view inside a `ScrollView` cannot hand a touch back once it has claimed it.
struct HistoryChartTouchSurface: UIViewRepresentable {
    /// Returns true when the touch changed what the page shows (it zoomed, or left a zoom).
    var onTouch: (HistoryChartTouch) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouch: onTouch)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = Coordinator.holdDuration
        view.addGestureRecognizer(hold)

        let drag = HistoryHorizontalDragRecognizer(target: coordinator, action: #selector(Coordinator.handleDrag(_:)))
        drag.delegate = coordinator
        view.addGestureRecognizer(drag)
        coordinator.drag = drag

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTouch = onTouch
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Resting this long turns a touch into pointing. Short enough to feel immediate, long
        /// enough that a drag which is meant as one has already moved.
        static let holdDuration: TimeInterval = 0.18

        var onTouch: (HistoryChartTouch) -> Bool
        weak var drag: HistoryHorizontalDragRecognizer?
        private let selectionFeedback = UISelectionFeedbackGenerator()
        private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

        init(onTouch: @escaping (HistoryChartTouch) -> Bool) {
            self.onTouch = onTouch
        }

        private func send(_ touch: HistoryChartTouch) {
            if onTouch(touch) { impactFeedback.impactOccurred() }
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            let x = recognizer.location(in: recognizer.view).x
            switch recognizer.state {
            case .began:
                selectionFeedback.selectionChanged()
                send(.point(x: x))
            case .changed:
                send(.point(x: x))
            default:
                send(.pointEnded)
            }
        }

        @objc func handleDrag(_ recognizer: HistoryHorizontalDragRecognizer) {
            let x = recognizer.location(in: recognizer.view).x
            switch recognizer.state {
            case .began:
                impactFeedback.prepare()
                send(.selectionBegan(start: recognizer.startLocation.x, x: x))
            case .changed:
                send(.selectionMoved(x: x))
            case .ended:
                send(.selectionEnded(commit: true))
            default:
                send(.selectionEnded(commit: false))
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                impactFeedback.prepare()
                send(.pinchBegan(x: recognizer.location(in: recognizer.view).x))
                send(.pinchMoved(scale: recognizer.scale))
            case .changed:
                send(.pinchMoved(scale: recognizer.scale))
            case .ended:
                send(.pinchEnded(scale: recognizer.scale, commit: true))
            default:
                send(.pinchEnded(scale: 1, commit: false))
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            send(.doubleTap)
        }

        /// The page's pan waits for the verdict on which way the drag started: sideways selects,
        /// anything else fails the drag at once and the page scrolls as if the chart were not there.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === drag && otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
    }
}

/// A one-finger drag that starts sideways. It decides after a few points of travel: mostly
/// horizontal and it begins, otherwise it fails, so a vertical drag is never held up.
final class HistoryHorizontalDragRecognizer: UIGestureRecognizer {
    /// Travel before the direction is read; less than a scroll view's own threshold.
    static let slop: CGFloat = 6
    /// How much further across than up or down the finger must have moved.
    static let dominance: CGFloat = 1.5

    /// Where the finger came down, in the recogniser's view.
    private(set) var startLocation: CGPoint = .zero
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            // A second finger: not this gesture, and possibly a pinch.
            if state == .possible {
                state = .failed
            } else {
                touches.forEach { ignore($0, for: event) }
            }
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            let location = touch.location(in: view)
            let across = abs(location.x - startLocation.x), along = abs(location.y - startLocation.y)
            guard max(across, along) >= Self.slop else { return }
            state = across > along * Self.dominance ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        startLocation = .zero
    }
}

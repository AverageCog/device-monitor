import Foundation

/// The ranges of the history page (HV_RANGES in public/index.html).
public enum HistoryRange: String, Sendable, Hashable, CaseIterable, Codable {
    case oneHour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    public static let `default` = HistoryRange.sixHours

    /// The name stored in preferences (`hvRange`).
    public var id: String { rawValue }

    /// What the range's button says.
    public var label: String {
        switch self {
        case .oneHour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    /// Width of the window in milliseconds.
    public var duration: Double {
        switch self {
        case .oneHour: 3600e3
        case .sixHours: 6 * 3600e3
        case .day: 24 * 3600e3
        case .week: 7 * 86400e3
        case .month: 30 * 86400e3
        }
    }

    /// The range to open with, given the stored one: `store.get('hvRange') || '6h'`, and six hours
    /// for anything that is not a range.
    public static func resolve(stored: String?) -> HistoryRange {
        stored.flatMap(HistoryRange.init(rawValue:)) ?? .default
    }
}

/// What the history page asks the hub for: `GET /api/history/<id>?from=…&to=…&points=…`.
public struct HistoryRequest: Sendable, Equatable {
    /// Milliseconds since 1970, whole.
    public let from: Double
    public let to: Double
    /// How many points the hub should reduce the window to.
    public let points: Int

    public init(from: Double, to: Double, points: Int) {
        self.from = from
        self.to = to
        self.points = points
    }
}

/// The stretch of time the history page shows (the `hv` state in public/index.html): a range
/// ending now, or a part of it the user zoomed into.
public struct HistoryWindow: Sendable, Equatable {
    /// The page moves its window to "now" and loads again this often, unless zoomed (milliseconds).
    public static let refreshInterval: Double = 30_000
    /// A zoom must leave at least this much time on screen (milliseconds).
    public static let minimumSpan: Double = 60_000
    /// A drag shorter than this many points is a tap, not a selection.
    public static let minimumDrag: Double = 8
    public static let resetTitle = "Reset zoom"

    public private(set) var range: HistoryRange
    /// Left and right edge, in milliseconds since 1970. After a zoom they are rarely whole.
    public private(set) var from: Double
    public private(set) var to: Double
    public private(set) var isZoomed: Bool

    /// The window of a range, ending at `now` (setHvWindow).
    public init(range: HistoryRange = .default, now: Double = Date().hubTime) {
        self.range = range
        to = now
        from = now - range.duration
        isZoomed = false
    }

    public var span: Double { to - from }
    public var fromDate: Date { Date(hubTime: from) }
    public var toDate: Date { Date(hubTime: to) }

    /// The range whose button is lit: none while zoomed.
    public var selectedRange: HistoryRange? { isZoomed ? nil : range }

    /// Whether to offer "Reset zoom".
    public var showsReset: Bool { isZoomed }

    /// Choosing a range: leaves any zoom and ends the window at `now`.
    public mutating func select(_ range: HistoryRange, now: Double = Date().hubTime) {
        self = HistoryWindow(range: range, now: now)
    }

    /// "Reset zoom": back to the whole range, ending at `now`.
    public mutating func reset(now: Double = Date().hubTime) {
        self = HistoryWindow(range: range, now: now)
    }

    /// A double tap on a chart: resets a zoomed window and returns true (the page loads again);
    /// leaves any other window alone and returns false.
    @discardableResult
    public mutating func resetIfZoomed(now: Double = Date().hubTime) -> Bool {
        guard isZoomed else { return false }
        reset(now: now)
        return true
    }

    /// The 30-second tick. Moves the window to end at `now` and returns true when the page should
    /// load again; leaves a zoomed window alone and returns false.
    @discardableResult
    public mutating func refresh(now: Double = Date().hubTime) -> Bool {
        guard !isZoomed else { return false }
        self = HistoryWindow(range: range, now: now)
        return true
    }

    /// The window after zooming into the stretch between two times, in either order. The stretch
    /// is cut to the current window; nil when less than a minute would be left, and the window
    /// then stays as it is.
    public func zoomed(to a: Double, _ b: Double) -> HistoryWindow? {
        // const from = Math.max(hv.from, a), to = Math.min(hv.to, b); if (to - from >= 60e3) { … hv.zoomed = true; … }
        let from = max(self.from, min(a, b)), to = min(self.to, max(a, b))
        guard to - from >= HistoryWindow.minimumSpan else { return nil }
        var next = self
        next.from = from
        next.to = to
        next.isZoomed = true
        return next
    }

    /// The window after a drag across a chart from one horizontal position to another, on a chart
    /// `chartWidth` wide and laid out like the dashboard's (`HistoryChartLayout`). nil for a drag
    /// of eight points or less, and when less than a minute would be left.
    public func zoomed(byDragFrom x1: Double, to x2: Double, chartWidth: Double) -> HistoryWindow? {
        // if (d && d.x2 != null && Math.abs(d.x2 - d.x1) > 8) { const a = hvT(Math.min(d.x1, d.x2), d.W), b = hvT(Math.max(d.x1, d.x2), d.W); … }
        guard abs(x2 - x1) > HistoryWindow.minimumDrag else { return nil }
        let layout = HistoryChartLayout(width: chartWidth, from: from, to: to)
        return zoomed(to: layout.time(atX: min(x1, x2)), layout.time(atX: max(x1, x2)))
    }

    /// How many points to ask for, given the width of the column the charts are in: one per point
    /// of width, at least 200, at most 1200, and 900 when the width is not known yet.
    ///
    /// `Math.min(1200, Math.max(200, Math.round($('#hvCharts').clientWidth || 900)))`
    public static func points(forWidth width: Double) -> Int {
        let w = JS.isTruthy(width) ? width : 900
        return Int(min(1200, max(200, JS.round(w))))
    }

    /// What to ask the hub for: the window's edges rounded to whole milliseconds, and the points
    /// that fit the width.
    public func request(forWidth width: Double) -> HistoryRequest {
        HistoryRequest(from: JS.round(from), to: JS.round(to), points: HistoryWindow.points(forWidth: width))
    }
}

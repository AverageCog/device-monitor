import Foundation

/// The time range of the Advanced screen (the #advRange buttons of public/index.html).
public enum AdvancedRange: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    /// What the dashboard starts with, and falls back to for a stored value it does not know.
    public static let `default` = AdvancedRange.week

    /// The stored preference (`advRange`), or the default for anything else.
    public init(stored: String?) {
        self = stored.flatMap(AdvancedRange.init(rawValue:)) ?? .default
    }

    public var id: String { rawValue }

    /// The button's caption.
    public var label: String {
        switch self {
        case .day: "24 h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    /// "last 7 days": the line under "Energy used" when the data covers the whole range.
    public var sinceLabel: String {
        switch self {
        case .day: "last 24 hours"
        case .week: "last 7 days"
        case .month: "last 30 days"
        }
    }

    /// The chart's heading.
    public var chartTitle: String {
        self == .day ? "Energy per hour" : "Energy per day"
    }

    /// How many buckets the range is cut into: hours for 24 h, days otherwise.
    public var bucketCount: Int {
        switch self {
        case .day: 24
        case .week: 7
        case .month: 30
        }
    }

    /// Bucket edges in local time, exactly as the dashboard computes them (function advBounds):
    /// the hours up to the end of the current one, or the days up to the coming midnight. One more
    /// edge than there are buckets, in milliseconds since 1970.
    ///
    /// The dashboard steps through wall-clock times, so days around a clock change are 23 or 25
    /// hours long. In the 24 h range the hour a clock change skips comes out as an empty bucket:
    /// two equal edges, which the hub refuses. Ask the hub with `requestBounds` instead.
    public func bounds(now: Double, timeZone: TimeZone) -> [Double] {
        var end = JSLocalDate(time: now, zone: timeZone)
        var out: [Double] = []
        if self == .day {
            // end.setMinutes(0, 0, 0); end.setHours(end.getHours() + 1);
            end.setLocal(end.local - end.local.jsModulo(JSLocalDate.hour))
            end.setLocal(end.local + JSLocalDate.hour)
            // for (let i = 24; i >= 0; i--) { const d = new Date(end); d.setHours(end.getHours() - i); … }
            for i in stride(from: 24, through: 0, by: -1) {
                var d = end
                d.setLocal(end.local - Double(i) * JSLocalDate.hour)
                out.append(d.time)
            }
        } else {
            // end.setHours(24, 0, 0, 0);
            end.setLocal(end.local - end.local.jsModulo(JSLocalDate.day) + JSLocalDate.day)
            // … d.setDate(end.getDate() - i);
            for i in stride(from: bucketCount, through: 0, by: -1) {
                var d = end
                d.setLocal(end.local - Double(i) * JSLocalDate.day)
                out.append(d.time)
            }
        }
        return out
    }

    /// The edges to send as `GET /api/energy?bounds=`: `bounds(now:timeZone:)` without the repeated
    /// edge of a skipped hour, so the list is strictly increasing as the hub requires. Everything
    /// drawn afterwards goes by the bounds the hub echoes back.
    public func requestBounds(now: Double, timeZone: TimeZone = .current) -> [Double] {
        var out: [Double] = []
        for edge in bounds(now: now, timeZone: timeZone) where out.last.map({ edge > $0 }) ?? true {
            out.append(edge)
        }
        return out
    }
}

/// When the Advanced screen refreshes itself (openAdvanced and advLive in public/index.html).
public enum AdvancedRefresh {
    /// The totals are fetched again this often while the screen is open, in seconds.
    public static let reloadInterval: TimeInterval = 60
    /// The live "now" figures follow reports at most this often, in seconds.
    public static let liveInterval: TimeInterval = 1

    /// function advLive as a value: a report asks for a redraw; one is scheduled a second later
    /// unless one is already waiting, and reports in between ride along with it.
    public struct LiveThrottle: Sendable, Equatable {
        /// When the waiting redraw is due (ms since 1970), or nil when none is scheduled.
        public private(set) var due: Double?

        public init() {}

        /// A report arrived. Returns the time to redraw at when a redraw has to be scheduled, nil
        /// when one is already waiting.
        public mutating func reportArrived(now: Double) -> Double? {
            guard due == nil else { return nil }
            due = now + AdvancedRefresh.liveInterval * 1000
            return due
        }

        /// The scheduled redraw ran (or the screen went away).
        public mutating func redrawn() {
            due = nil
        }
    }
}

/// The few `Date` operations advBounds uses, with JavaScript's rules for wall-clock times that a
/// clock change repeats or skips.
struct JSLocalDate {
    static let hour = 3_600_000.0
    static let day = 86_400_000.0

    /// Milliseconds since 1970 (the Date's time value).
    private(set) var time: Double
    let zone: TimeZone

    // new Date(value): a time value is a whole number of milliseconds.
    init(time: Double, zone: TimeZone) {
        self.time = time.rounded(.towardZero)
        self.zone = zone
    }

    /// LocalTime(t): the wall clock, as milliseconds on a time line without offsets.
    var local: Double { time + offset(at: time) }

    /// Sets the wall clock, as the setters do after changing their fields (MakeDate, then UTC()).
    mutating func setLocal(_ local: Double) {
        time = utc(fromLocal: local)
    }

    private func offset(at time: Double) -> Double {
        Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: time / 1000))) * 1000
    }

    /// UTC(t) of ECMA-262: a wall-clock time that occurs twice (clocks went back) or not at all
    /// (clocks went forward) is read with the offset in force before the change. So 01:30 on the
    /// night clocks go back is the first 01:30, and a skipped 02:30 lands an hour later, on 03:30.
    private func utc(fromLocal local: Double) -> Double {
        // A day either side is far enough to be on opposite sides of a change near `local`,
        // whatever the zone's offset.
        let former = offset(at: local - Self.day), latter = offset(at: local + Self.day)
        if former == latter { return local - former }
        if offset(at: local - former) == former { return local - former }
        if offset(at: local - latter) == latter { return local - latter }
        return local - former
    }
}

extension Double {
    /// A remainder that is never negative, for times before 1970.
    fileprivate func jsModulo(_ divisor: Double) -> Double {
        let remainder = truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }
}

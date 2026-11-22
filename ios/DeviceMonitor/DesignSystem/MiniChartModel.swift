import SwiftUI

/// One sample of a `MiniChart` series.
nonisolated struct MiniChartPoint: Equatable, Sendable {
    /// Milliseconds since the Unix epoch, as in the hub's history points (`t`).
    var t: Double
    /// Percentage, 0–100. `nil` breaks the line (no reading in that sample).
    var value: Double?

    init(t: Double, value: Double?) {
        self.t = t
        self.value = value
    }

    init(date: Date, value: Double?) {
        self.init(t: date.timeIntervalSince1970 * 1000, value: value)
    }
}

/// One line of a `MiniChart`.
nonisolated struct MiniChartSeries: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var color: Color
    /// In ascending time order. Series of one chart are expected to share their sample times, as the
    /// keys of one history point do.
    var points: [MiniChartPoint]

    init(id: String, label: String, color: Color, points: [MiniChartPoint]) {
        self.id = id
        self.label = label
        self.color = color
        self.points = points
    }
}

/// The sample under the crosshair while scrubbing a `MiniChart`.
nonisolated struct MiniChartSelection: Equatable, Sendable {
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        /// The series' id.
        let id: String
        let label: String
        let color: Color
        let value: Double
    }

    /// Time of the nearest sample, in milliseconds since the Unix epoch.
    var t: Double
    /// The series that have a reading in that sample, in series order.
    var entries: [Entry]
    /// Horizontal position of the crosshair from the chart's leading edge, for placing a tooltip.
    var x: CGFloat
    /// Width of the chart, for keeping a tooltip inside it.
    var chartWidth: CGFloat

    var date: Date { Date(timeIntervalSince1970: t / 1000) }
}

/// Plot geometry and hit-testing of a `MiniChart`: the arithmetic of `drawChart()` in
/// public/index.html, kept free of views so it can be reasoned about and reused.
nonisolated struct MiniChartGeometry: Equatable, Sendable {
    let size: CGSize
    let padLeading: CGFloat
    let padTrailing: CGFloat
    let padTop: CGFloat
    let padBottom: CGFloat
    let windowStart: Double
    let windowSpan: Double

    /// - Parameter axisFontSize: The dashboard pads for a 10 px axis font; the paddings grow with it.
    init(size: CGSize, windowEnd: Double, windowSpan: Double, axisFontSize: CGFloat = 10) {
        self.size = size
        let k = axisFontSize / 10
        // 30 px in the dashboard; "100%" is wider in San Francisco than in Segoe UI.
        padLeading = (34 * k).rounded()
        padTrailing = 4
        padTop = (6 * k).rounded()
        padBottom = (6 * k).rounded()
        self.windowSpan = max(1, windowSpan)
        windowStart = windowEnd - max(1, windowSpan)
    }

    var plotWidth: CGFloat { max(0, size.width - padLeading - padTrailing) }
    var plotHeight: CGFloat { max(0, size.height - padTop - padBottom) }
    var plot: CGRect { CGRect(x: padLeading, y: padTop, width: plotWidth, height: plotHeight) }

    func x(_ t: Double) -> CGFloat {
        padLeading + CGFloat((t - windowStart) / windowSpan) * plotWidth
    }

    func y(_ percent: Double) -> CGFloat {
        padTop + plotHeight - CGFloat(min(100, max(0, percent)) / 100) * plotHeight
    }

    func time(atX x: CGFloat) -> Double {
        guard plotWidth > 0 else { return windowStart }
        return windowStart + Double((x - padLeading) / plotWidth) * windowSpan
    }

    /// The sample nearest to a touch at `x`, with the readings of every series in that sample.
    /// `nil` when there is no sample inside the window.
    func selection(atX x: CGFloat, in series: [MiniChartSeries]) -> MiniChartSelection? {
        let target = time(atX: x)
        var best: Double?
        for line in series {
            guard let index = Self.nearestIndex(in: line.points, to: target) else { continue }
            let t = line.points[index].t
            if let current = best, abs(current - target) <= abs(t - target) { continue }
            best = t
        }
        guard let best, best >= windowStart else { return nil }
        let entries: [MiniChartSelection.Entry] = series.compactMap { line in
            guard let index = Self.nearestIndex(in: line.points, to: best) else { return nil }
            let point = line.points[index]
            // Only the same sample counts: a neighbouring reading would be a different moment.
            guard abs(point.t - best) < 0.5, let value = point.value else { return nil }
            return MiniChartSelection.Entry(id: line.id, label: line.label, color: line.color, value: value)
        }
        return MiniChartSelection(t: best, entries: entries, x: self.x(best), chartWidth: size.width)
    }

    /// Index of the point closest in time to `t` (binary search; `points` ascend by time).
    static func nearestIndex(in points: [MiniChartPoint], to t: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].t < t { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(points[low - 1].t - t) <= abs(points[low].t - t) { return low - 1 }
        return low
    }

    /// The pause that counts as a gap for history sampled every `resolution` milliseconds
    /// (`Math.max(10000, resolution * 3)`).
    static func gapInterval(resolution: Double) -> Double {
        max(10_000, resolution * 3)
    }

    /// The line of one series: points before the window and missing readings lift the pen, and so
    /// does a pause longer than `gapInterval` (the device was offline).
    func path(for points: [MiniChartPoint], gapInterval: Double) -> Path {
        var path = Path()
        var penDown = false
        var previous = 0.0
        for point in points {
            guard point.t >= windowStart, let value = point.value else {
                penDown = false
                continue
            }
            if penDown, point.t - previous > gapInterval { penDown = false }
            let position = CGPoint(x: x(point.t), y: y(value))
            if penDown {
                path.addLine(to: position)
            } else {
                path.move(to: position)
            }
            penDown = true
            previous = point.t
        }
        return path
    }
}

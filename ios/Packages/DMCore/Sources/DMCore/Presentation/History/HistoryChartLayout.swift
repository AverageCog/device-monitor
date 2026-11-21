import Foundation

/// Where the dashboard puts things on a history chart's canvas (PAD, hvX, hvT and the y mapping of
/// drawHvChart in public/index.html): a 58-point gutter on the left for the value labels, 22
/// points under the plot for the time labels.
///
/// The models keep times and values in data space; a view that draws its own chart can use this
/// to place them exactly as the dashboard does, and to turn a touch into a time.
public struct HistoryChartLayout: Sendable, Equatable {
    public struct Padding: Sendable, Equatable {
        public let left: Double, right: Double, top: Double, bottom: Double
    }

    // const PAD = { l: 58, r: 10, t: 8, b: 22 };
    public static let padding = Padding(left: 58, right: 10, top: 8, bottom: 22)
    /// Height of a chart's canvas on the dashboard.
    public static let height: Double = 170
    /// Radius of the dot drawn on each line at the point under the pointer.
    public static let markerRadius: Double = 4
    /// Opacity of a peak band, over the series colour.
    public static let bandOpacity: Double = 0.14

    /// Width of the whole chart, gutter included.
    public let width: Double
    public let height: Double
    /// The window's edges, in milliseconds.
    public let from: Double
    public let to: Double

    public init(width: Double, height: Double = HistoryChartLayout.height, from: Double, to: Double) {
        self.width = width
        self.height = height
        self.from = from
        self.to = to
    }

    public var plotWidth: Double { width - HistoryChartLayout.padding.left - HistoryChartLayout.padding.right }
    public var plotHeight: Double { height - HistoryChartLayout.padding.top - HistoryChartLayout.padding.bottom }

    // function hvX(t, W) { return PAD.l + (t - hv.from) / (hv.to - hv.from) * (W - PAD.l - PAD.r); }
    public func x(_ t: Double) -> Double {
        HistoryChartLayout.padding.left + (t - from) / (to - from) * plotWidth
    }

    // function hvT(x, W) { return hv.from + (x - PAD.l) / (W - PAD.l - PAD.r) * (hv.to - hv.from); }
    public func time(atX x: Double) -> Double {
        from + (x - HistoryChartLayout.padding.left) / plotWidth * (to - from)
    }

    /// Vertical position of a value on a chart whose axis runs from 0 to `yMax`. The value is in
    /// the unit the chart shows, as the models give it.
    ///
    /// `const y = v => PAD.t + ch_ - (conv(v) - yMin) / (yMax - yMin) * ch_;`
    public func y(_ value: Double, yMax: Double) -> Double {
        HistoryChartLayout.padding.top + plotHeight - value / yMax * plotHeight
    }

    /// Vertical position of grid level `index` of 0…4, bottom to top, before the dashboard snaps
    /// it to a pixel: `PAD.t + ch_ - ch_ * i / 4`.
    public func gridY(_ index: Int) -> Double {
        HistoryChartLayout.padding.top + plotHeight - plotHeight * Double(index) / 4
    }
}

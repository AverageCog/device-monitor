import DMCore
import SwiftUI
import UIKit

extension MetricTint {
    /// The palette colour of a history series, tile or tooltip row.
    nonisolated var historyColor: Color {
        switch self {
        case .cpu: Theme.cpu
        case .gpu: Theme.gpu
        case .mem: Theme.mem
        case .secondary: Theme.textSecondary
        }
    }
}

/// Where things go on a history chart drawn in a view: the dashboard's own layout
/// (`HistoryChartLayout`: a 58-point gutter for the value labels, 22 points under the plot for the
/// times, 170 points high), enlarged as a whole when the axis text is.
///
/// At the default text size one point here is one CSS pixel there. With larger text the gutter,
/// the room under the plot and the distance between time labels all grow with the labels, so
/// nothing collides; positions handed to the presentation layer are divided by `scale` first.
nonisolated struct HistoryChartGeometry: Equatable, Sendable {
    /// Size of the chart's view, in points.
    let size: CGSize
    /// Axis text size over the dashboard's 10 pixels.
    let scale: CGFloat
    /// The same chart in the dashboard's coordinates.
    let layout: HistoryChartLayout

    init(size: CGSize, scale: CGFloat, from: Double, to: Double) {
        let scale = max(0.1, scale)
        self.size = size
        self.scale = scale
        layout = HistoryChartLayout(width: Double(size.width / scale), height: Double(size.height / scale), from: from, to: to)
    }

    /// Height of a chart whose axis text is `scale` times the dashboard's.
    static func height(scale: CGFloat) -> CGFloat {
        CGFloat(HistoryChartLayout.height) * scale
    }

    /// False while there is nothing to map: no room for a plot, or a window without a span.
    var isDrawable: Bool {
        layout.plotWidth > 0 && layout.plotHeight > 0 && layout.to > layout.from
    }

    var plot: CGRect {
        CGRect(
            x: CGFloat(HistoryChartLayout.padding.left) * scale,
            y: CGFloat(HistoryChartLayout.padding.top) * scale,
            width: CGFloat(layout.plotWidth) * scale,
            height: CGFloat(layout.plotHeight) * scale
        )
    }

    func x(_ t: Double) -> CGFloat {
        CGFloat(layout.x(t)) * scale
    }

    /// A value in the unit the chart shows, on an axis from 0 to `yMax`.
    func y(_ value: Double, yMax: Double) -> CGFloat {
        guard yMax > 0 else { return plot.maxY }
        return CGFloat(layout.y(value, yMax: yMax)) * scale
    }

    func gridY(_ index: Int) -> CGFloat {
        CGFloat(layout.gridY(index)) * scale
    }

    /// A horizontal position in this view as the presentation layer counts it.
    func layoutX(_ x: CGFloat) -> Double {
        Double(x / scale)
    }

    /// Top of the time labels: `H - PAD.b + 6`.
    var timeLabelTop: CGFloat {
        CGFloat(layout.height - HistoryChartLayout.padding.bottom + 6) * scale
    }

    /// Right edge of the value labels: `PAD.l - 6`.
    var valueLabelTrailing: CGFloat {
        CGFloat(HistoryChartLayout.padding.left - 6) * scale
    }
}

/// The time labels under the charts, thinned out until they fit.
///
/// The dashboard writes at least three labels however narrow the chart is, and on a phone the
/// long ones ("Fri, Nov 20 10:50 AM") run into each other. Here the count drops to what has room,
/// down to the two ends, and below that the text shrinks.
nonisolated struct HistoryTimeAxis: Equatable, Sendable {
    let ticks: [HistoryTimeTick]
    /// Size of the label text; smaller than asked for only when two labels do not fit.
    let fontSize: CGFloat

    @MainActor
    init(model: HistoryModel, geometry: HistoryChartGeometry, fontSize: CGFloat) {
        guard geometry.isDrawable else {
            ticks = []
            self.fontSize = fontSize
            return
        }
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        func width(_ label: String) -> CGFloat {
            (label as NSString).size(withAttributes: [.font: font]).width
        }
        let clearance = 8 * geometry.scale
        // nx = Math.max(2, Math.min(7, Math.floor((W - PAD.l) / 140)))
        var divisions = HistoryModel.timeDivisions(chartWidth: geometry.layout.width)
        while true {
            let candidate = model.timeTicks(divisions: divisions)
            let widths = candidate.map { width($0.label) }
            var overflow: CGFloat = 0
            var previousEnd = -CGFloat.infinity
            for (tick, labelWidth) in zip(candidate, widths) {
                let x = geometry.x(tick.t)
                let start: CGFloat
                switch tick.alignment {
                case .leading: start = x
                case .center: start = x - labelWidth / 2
                case .trailing: start = x - labelWidth
                }
                overflow = max(overflow, previousEnd + clearance - start)
                previousEnd = start + labelWidth
            }
            if overflow <= 0 {
                ticks = candidate
                self.fontSize = fontSize
                return
            }
            if divisions <= 1 {
                // Only the two ends are left: make them share the plot's width.
                let needed = widths.reduce(0, +) + clearance
                ticks = candidate
                self.fontSize = max(6, fontSize * min(1, geometry.plot.width / max(1, needed)))
                return
            }
            divisions -= 1
        }
    }
}

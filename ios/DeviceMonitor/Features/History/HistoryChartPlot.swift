import DMCore
import SwiftUI

/// The still part of a history chart, drawn as `drawHvChart` in public/index.html draws it: five
/// grid lines with a label on every other one, the time labels, and per series the shaded band
/// between average and peak under a 2-point line that breaks where readings are missing.
///
/// One `Canvas` pass over what the presentation layer computed. It is drawn again only when the
/// data or the size changes: the crosshair and the selection live in `HistoryChartMarks`, so a
/// finger moving across five charts of 1200 points each strokes none of them again.
struct HistoryChartPlot: View {
    let chart: HistoryChartModel
    let geometry: HistoryChartGeometry
    let timeAxis: HistoryTimeAxis
    /// Size of the value labels.
    let fontSize: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext) {
        let geometry = geometry
        guard geometry.isDrawable else { return }
        let plot = geometry.plot
        let pixel = max(1, displayScale)
        // `Math.round(y) + 0.5`: centre a one-point line on whole device pixels.
        func crisp(_ value: CGFloat) -> CGFloat { ((value - 0.5) * pixel).rounded() / pixel + 0.5 }

        // grid + y labels
        let gutter = max(1, geometry.valueLabelTrailing - 2)
        for level in chart.gridLevels {
            let y = crisp(geometry.gridY(level.index))
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(level.isBaseline ? Theme.axis : Theme.grid), lineWidth: 1)
            guard let label = level.label else { continue }
            let text = context.resolve(axisText(label, size: fontSize))
            let width = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
            // A label wider than the gutter ("1000 KB/s" at a large text size) is set smaller, not cut.
            let fitted = width > gutter ? context.resolve(axisText(label, size: fontSize * gutter / width)) : text
            context.draw(fitted, at: CGPoint(x: geometry.valueLabelTrailing, y: y), anchor: .trailing)
        }

        // x labels
        for tick in timeAxis.ticks {
            let anchor: UnitPoint
            switch tick.alignment {
            case .leading: anchor = .topLeading
            case .center: anchor = .top
            case .trailing: anchor = .topTrailing
            }
            context.draw(axisText(tick.label, size: timeAxis.fontSize), at: CGPoint(x: geometry.x(tick.t), y: geometry.timeLabelTop), anchor: anchor)
        }

        var lines = context
        // The dashboard clips to the plot exactly, which shaves half the line off at 0 and 100 %.
        lines.clip(to: Path(plot.insetBy(dx: 0, dy: -1.5)))
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        for series in chart.series {
            let color = series.tint.historyColor
            // peak band (avg -> max), only when points are aggregated
            for band in series.bands {
                var area = Path()
                for (index, point) in band.enumerated() {
                    let position = CGPoint(x: geometry.x(point.t), y: geometry.y(point.high, yMax: chart.yMax))
                    if index == 0 { area.move(to: position) } else { area.addLine(to: position) }
                }
                for point in band.reversed() {
                    area.addLine(to: CGPoint(x: geometry.x(point.t), y: geometry.y(point.low, yMax: chart.yMax)))
                }
                area.closeSubpath()
                lines.fill(area, with: .color(color.opacity(HistoryChartLayout.bandOpacity)))
            }
            var path = Path()
            // A run of one point draws nothing on the dashboard either.
            for run in series.lines where run.count > 1 {
                for (index, point) in run.enumerated() {
                    let position = CGPoint(x: geometry.x(point.t), y: geometry.y(point.value, yMax: chart.yMax))
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
            }
            lines.stroke(path, with: .color(color), style: stroke)
        }
    }

    private func axisText(_ label: String, size: CGFloat) -> Text {
        Text(verbatim: label)
            .font(.system(size: size).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
    }
}

/// What moves on a history chart while it is touched: the stretch being selected, the crosshair
/// at the reading nearest the finger, and a dot on each line there. Every chart shows the same
/// moment (`hv.hoverT`, `hv.drag`).
struct HistoryChartMarks: View {
    let controller: HistoryController
    let chart: HistoryChartModel
    let geometry: HistoryChartGeometry

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let tooltip = controller.tooltip
        let selection = controller.selection
        Canvas { context, _ in
            draw(in: &context, tooltip: tooltip, selection: selection)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, tooltip: HistoryTooltipModel?, selection: HistoryChartSelection?) {
        guard geometry.isDrawable else { return }
        let plot = geometry.plot

        // drag selection
        if let selection {
            let times = selection.times(from: geometry.layout.from, to: geometry.layout.to)
            // const x1 = Math.max(PAD.l, …), x2 = Math.min(W - PAD.r, …);
            let x1 = max(plot.minX, geometry.x(times.start)), x2 = min(plot.maxX, geometry.x(times.end))
            if x2 > x1 {
                context.fill(Path(CGRect(x: x1, y: plot.minY, width: x2 - x1, height: plot.height)), with: .color(Theme.accent.opacity(0.18)))
            }
        }

        // crosshair + dots (shared across charts)
        guard let tooltip else { return }
        let pixel = max(1, displayScale)
        let x = geometry.x(tooltip.t)
        let crispX = ((x - 0.5) * pixel).rounded() / pixel + 0.5
        var crosshair = Path()
        crosshair.move(to: CGPoint(x: crispX, y: plot.minY))
        crosshair.addLine(to: CGPoint(x: crispX, y: plot.maxY))
        context.stroke(crosshair, with: .color(Theme.textMuted), lineWidth: 1)
        let radius = CGFloat(HistoryChartLayout.markerRadius)
        for row in tooltip.rows(for: chart.kind) {
            let y = geometry.y(row.y, yMax: chart.yMax)
            let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(row.tint.historyColor))
            context.stroke(dot, with: .color(Theme.surface1), lineWidth: 2)
        }
    }
}

/// The read-out beside the crosshair (`.tip`): the time of the reading, then one row per series
/// with its colour, name, value in semibold and, where the point is an average, the peak in muted text.
struct HistoryTooltipView: View {
    let title: String
    let rows: [HistoryTooltipRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 2)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(row.tint.historyColor)
                        .frame(width: 8, height: 2)
                    Text("\(row.label) \(Text(row.value).fontWeight(.semibold))\(Text(row.peak.map { " " + $0 } ?? "").foregroundStyle(Theme.textMuted))")
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
        .dmFont(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .dmSurface(Theme.inset, radius: Theme.Radius.control)
        // The read-out floats over the chart and grows as far as the axis text does; larger, it
        // would cover the plot it is about.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Puts the tooltip beside the crosshair, on the other side when it would leave the chart, and
/// never outside it. Horizontally this is the dashboard's rule; vertically the tooltip takes the
/// place of the title and legend rather than sit over the plot, where a finger would hide it.
struct HistoryTooltipPlacement: Layout {
    /// How far the tooltip reaches up into the card's padding, to keep it off the plot.
    static let lift: CGFloat = 8

    /// The moment the crosshair marks.
    var time: Double
    var from: Double
    var to: Double
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let geometry = HistoryChartGeometry(size: bounds.size, scale: scale, from: from, to: to)
        let crosshair = geometry.x(time)
        // tip.style.left = (px + 12 + tw > W ? px - tw - 12 : px + 12) + 'px';
        let beside = crosshair + 12 + size.width > bounds.width ? crosshair - size.width - 12 : crosshair + 12
        // Kept inside the chart, and off the value labels for as long as it is narrower than the plot.
        let trailing = max(0, bounds.width - size.width)
        let x = min(trailing, max(min(geometry.plot.minX, trailing), beside))
        tooltip.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY - Self.lift), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

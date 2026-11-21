import Accessibility
import DMCore
import SwiftUI
import UIKit

/// The chart panel (`.hv-chart` of #advView): "Energy per day", the devices that used energy, and
/// the stacked bars.
struct AdvancedChartPanel: View {
    let controller: AdvancedController
    /// A bar to select as soon as there is a chart (`-dm-advanced-bucket`).
    let preselected: AdvancedDebugOptions.Bucket?

    /// `adv.hover`: the bucket that is picked out.
    @State private var selection: Int?
    @State private var hasPreselected = false
    @State private var titleHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .footnote) private var legendLine: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var scaledAxis: CGFloat = DMTextStyle.axis.size
    /// About what a tooltip and its gap to the bar take, at the current text size.
    @ScaledMetric(relativeTo: .footnote) private var tooltipRoom: CGFloat = 264
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func bucket(_ index: Int?, of chart: AdvancedChartModel?) -> AdvancedChartModel.Bucket? {
        guard let index, let chart, chart.buckets.indices.contains(index) else { return nil }
        return chart.buckets[index]
    }

    var body: some View {
        let chart = controller.chart
        let picked = Self.bucket(selection, of: chart)
        // Every bar has a free side when the canvas holds two tooltips and their gaps; the
        // tooltip's own text stops growing at the first accessibility size.
        let fitsBeside = width >= 2 * min(tooltipRoom, 400)
        // Otherwise the tooltip takes the place of the title and the legend, which it repeats.
        let hidesHeader = picked != nil && !fitsBeside
        VStack(alignment: .leading, spacing: 0) {
            Group {
                Text(controller.chartTitle)
                    .dmFont(.panelTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("advanced-chart-title")
                // `.hv-chart .legend { margin: 6px 0 4px }`; a line is kept free while there is nothing
                // to list, so the bars do not jump down when the totals arrive.
                FlowLayout(spacing: 14, lineSpacing: Theme.Spacing.xs) {
                    ForEach(controller.legend) { item in
                        LegendItem(item.name, color: item.color.color)
                            .accessibilityIdentifier("advanced-chart-legend-\(item.deviceID)")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: legendLine, alignment: .topLeading)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .opacity(hidesHeader ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hidesHeader)
            if let chart {
                AdvancedEnergyChart(title: controller.chartTitle, chart: chart, selection: $selection)
            } else {
                AdvancedChartPlaceholder(controller: controller)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .topLeading) {
            if let chart, let picked {
                AdvancedTooltipPlacement(
                    chart: chart, index: picked.index, zoom: AdvancedEnergyChart.zoom(axisSize: scaledAxis),
                    fitsBeside: fitsBeside, titleHeight: titleHeight
                ) {
                    AdvancedChartTooltip(tooltip: picked.tooltip)
                }
                .allowsHitTesting(false)
            }
        }
        .padding(Theme.Layout.panelPadding)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        // Another range is another set of buckets.
        .onChange(of: controller.range) { selection = nil }
        .onChange(of: chart?.buckets.count, initial: true) { _, count in
            guard let count else { return }
            if let selected = selection, selected >= count { selection = nil }
            if !hasPreselected, let preselected {
                hasPreselected = true
                switch preselected {
                case .index(let index): selection = index < count ? index : nil
                case .last: selection = count - 1
                }
            }
        }
    }
}

/// Stands where the bars will be while the totals are on their way, or could not be had.
private struct AdvancedChartPlaceholder: View {
    let controller: AdvancedController

    @ScaledMetric(relativeTo: .caption2) private var scaledAxis: CGFloat = DMTextStyle.axis.size

    var body: some View {
        ZStack {
            if controller.failure != nil {
                Text(AdvancedStrings.loadFailed)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .tint(Theme.textMuted)
                    // "Loading…", in the words the usage table uses.
                    .accessibilityLabel(controller.usage.emptyText ?? "")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AdvancedEnergyChart.height(axisSize: scaledAxis))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("advanced-chart-placeholder")
    }
}

/// The stacked bars, drawn the way drawAdvChart draws them: the model's geometry on a canvas.
/// Touching a bar, or dragging across the bars, picks a bucket out: the others dim, and the panel
/// shows its figures. A second touch on it, or one beside the plot, lets go.
struct AdvancedEnergyChart: View {
    let title: String
    let chart: AdvancedChartModel
    @Binding var selection: Int?

    /// The bar a pointer picked out by being over it, for as long as the selection is still the
    /// pointer's doing: nil once a touch has chosen a bar, and when no pointer is over one.
    @State private var hovered: Int?
    @ScaledMetric(relativeTo: .caption2) private var scaledAxis: CGFloat = DMTextStyle.axis.size
    @Environment(\.displayScale) private var displayScale

    private typealias Plot = AdvancedChartModel.Layout

    /// Axis labels follow the text size up to a point.
    private static func axisSize(_ scaled: CGFloat) -> CGFloat { min(scaled, 16) }

    /// `#advChart { height: 200px }`, growing with its labels.
    static func height(axisSize scaled: CGFloat) -> CGFloat {
        200 * axisSize(scaled) / DMTextStyle.axis.size
    }

    /// The model lays the canvas out for a 10-point axis font. With larger text the whole chart
    /// is drawn that much larger: the model sees a canvas that is `zoom` times smaller, so it
    /// also labels fewer bars.
    static func zoom(axisSize scaled: CGFloat) -> CGFloat {
        axisSize(scaled) / DMTextStyle.axis.size
    }

    private var zoom: CGFloat { Self.zoom(axisSize: scaledAxis) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .overlay {
                AdvancedChartTouchSurface { x in
                    touch(at: x, canvasWidth: width)
                } onDrag: { x in
                    drag(to: x, canvasWidth: width)
                }
            }
            .onContinuousHover { phase in
                // A pointer picks out the bar under it, and lets go when it leaves (pointermove,
                // pointerleave). A bar that a touch chose is not the pointer's to move or let go.
                guard selection == nil || selection == hovered else { return }
                switch phase {
                case .active(let point): hovered = bucket(at: point.x, canvasWidth: width)
                case .ended: hovered = nil
                }
                selection = hovered
            }
        }
        .frame(height: Self.height(axisSize: scaledAxis))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            step(direction)
        }
        .accessibilityChartDescriptor(AdvancedEnergyChartDescriptor(title: title, chart: chart))
        .accessibilityIdentifier("advanced-chart")
        .sensoryFeedback(.selection, trigger: selection)
    }

    // MARK: Picking a bucket

    /// The bucket under `x`, nil beside the plot (the dashboard's pointermove handler).
    private func bucket(at x: CGFloat, canvasWidth: CGFloat) -> Int? {
        chart.bucketIndex(atX: Double(x / zoom), canvasWidth: Double(canvasWidth / zoom))
    }

    private func touch(at x: CGFloat, canvasWidth: CGFloat) {
        let index = bucket(at: x, canvasWidth: canvasWidth)
        // A second touch lets go of the bar the first one chose. The bar under a pointer is
        // picked out before the click comes: that click is its first touch, and keeps it.
        let isSecondTouch = index == selection && index != hovered
        hovered = nil
        selection = isSecondTouch ? nil : index
    }

    /// A finger that slides past either end of the plot keeps the nearest bucket.
    private func drag(to x: CGFloat, canvasWidth: CGFloat) {
        let width = Double(canvasWidth / zoom)
        let inside = min(max(Double(x / zoom), Plot.left), max(Plot.left, width - Plot.right - 0.01))
        guard let index = chart.bucketIndex(atX: inside, canvasWidth: width) else { return }
        hovered = nil
        if index != selection { selection = index }
    }

    /// VoiceOver's swipe up and down walks through the buckets.
    private func step(_ direction: AccessibilityAdjustmentDirection) {
        guard let last = chart.buckets.indices.last else { return }
        hovered = nil
        guard let current = selection else {
            selection = last
            return
        }
        switch direction {
        case .increment: selection = min(last, current + 1)
        case .decrement: selection = max(0, current - 1)
        @unknown default: break
        }
    }

    /// The picked-out bucket, or the newest one: "Friday, Nov 20 (so far): 37.3 kWh, $11.77".
    private var spokenValue: String {
        let picked = selection.flatMap { chart.buckets.indices.contains($0) ? chart.buckets[$0] : nil }
        return (picked ?? chart.buckets.last)?.spokenSummary ?? ""
    }

    // MARK: Drawing

    // function drawAdvChart
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let zoom = zoom
        let width = Double(size.width / zoom), height = Double(size.height / zoom)
        let plotHeight = height - Plot.top - Plot.bottom
        guard width > Plot.left + Plot.right, plotHeight > 0, !chart.buckets.isEmpty else { return }
        let pixel = max(1, displayScale)
        // Centre one-point lines on whole device pixels so they stay crisp.
        func crisp(_ value: CGFloat) -> CGFloat { ((value - 0.5) * pixel).rounded() / pixel + 0.5 }
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: CGFloat(x) * zoom, y: CGFloat(y) * zoom) }
        let font = DMTextStyle.axis.font(size: Self.axisSize(scaledAxis))

        for tick in chart.ticks {
            let y = crisp(CGFloat(Plot.top + plotHeight - plotHeight * tick.fraction) * zoom)
            var line = Path()
            line.move(to: CGPoint(x: CGFloat(Plot.left) * zoom, y: y))
            line.addLine(to: CGPoint(x: CGFloat(width - Plot.right) * zoom, y: y))
            context.stroke(line, with: .color(tick.isBaseline ? Theme.axis : Theme.grid), lineWidth: 1)
            if let label = tick.label {
                context.draw(
                    Text(verbatim: label).font(font).foregroundStyle(Theme.textMuted),
                    at: CGPoint(x: CGFloat(Plot.left - 6) * zoom, y: y), anchor: .trailing)
            }
        }

        let barWidth = chart.barWidth(canvasWidth: width)
        for bucket in chart.buckets {
            let centre = chart.barCenterX(at: bucket.index, canvasWidth: width)
            if chart.showsLabel(at: bucket.index, canvasWidth: width) {
                context.draw(
                    Text(verbatim: bucket.label).font(font).foregroundStyle(Theme.textMuted),
                    at: point(centre, height - Plot.bottom + 6), anchor: .top)
            }
            let opacity = selection == nil || selection == bucket.index ? 1 : Plot.dimmedOpacity
            var y = Plot.top + plotHeight
            for segment in bucket.segments {
                let segmentHeight = segment.fraction * plotHeight
                guard segmentHeight > 0 else { continue }
                // `fillRect(cx - bw / 2, y - h, bw, Math.max(0.5, h - 1))`: a hairline between the segments.
                let origin = point(centre - barWidth / 2, y - segmentHeight)
                let rect = CGRect(
                    x: origin.x, y: origin.y, width: CGFloat(barWidth) * zoom,
                    height: CGFloat(max(0.5, segmentHeight - 1)) * zoom)
                context.fill(Path(rect), with: .color(segment.color.color.opacity(opacity)))
                y -= segmentHeight
            }
        }
    }
}

// MARK: - Tooltip

/// What the dashboard shows beside a hovered bar (`#advTip`): the bucket, each device's energy
/// and cost, and the total.
private struct AdvancedChartTooltip: View {
    let tooltip: AdvancedChartModel.Tooltip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tooltip.title)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.s, verticalSpacing: 1) {
                ForEach(tooltip.rows) { row in
                    line(row.name, energy: row.energy, cost: row.cost, color: row.color.color)
                }
                line(AdvancedChartModel.Tooltip.totalLabel, energy: tooltip.totalEnergy, cost: tooltip.totalCost, color: .clear)
            }
        }
        .dmFont(.caption)
        // A read-out that floats over the page stays a read-out at the largest text sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .dmSurface(Theme.inset, radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("advanced-chart-tooltip")
    }

    private func line(_ name: String, energy: String, cost: String, color: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(color)
                    .frame(width: 8, height: 2)
                Text(name)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Text(energy)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .gridColumnAlignment(.trailing)
            Text(cost)
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .fixedSize()
                .gridColumnAlignment(.trailing)
        }
    }
}

/// Places the tooltip over the panel, whose content it is given as bounds (title, legend, canvas).
///
/// With room for it, where the dashboard puts it: under the title, beside the bar, on the side
/// the model chooses (`.hv-chart .tip { top: 40px }`). On a canvas too narrow for that (a phone)
/// it takes the top of the panel instead, in place of the title and the legend; it stays as near
/// the bar as the panel allows, and a finger on the bars does not cover it.
private struct AdvancedTooltipPlacement: Layout {
    var chart: AdvancedChartModel
    var index: Int
    var zoom: CGFloat
    var fitsBeside: Bool
    var titleHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first, bounds.width > 0 else { return }
        let size = tooltip.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let beside = CGFloat(chart.tooltipLeft(
            at: index, canvasWidth: Double(bounds.width / zoom), tooltipWidth: Double(size.width / zoom))) * zoom
        let x = min(max(0, bounds.width - size.width), max(0, beside))
        // On a phone, a little of the panel's own padding as well: every point less over the bars counts.
        let y = fitsBeside ? titleHeight + 6 : -6
        tooltip.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

// MARK: - Touch

/// Reports taps and sideways drags on the plot. A drag that starts up or down is left to the
/// page's scrolling (`touch-action: pan-y` on the dashboard's canvas), which SwiftUI's own drag
/// gesture cannot promise inside a scroll view.
private struct AdvancedChartTouchSurface: UIViewRepresentable {
    var onTap: (CGFloat) -> Void
    var onDrag: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: AdvancedChartTouchSurface

        init(surface: AdvancedChartTouchSurface) {
            self.surface = surface
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            surface.onTap(recognizer.location(in: recognizer.view).x)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: surface.onDrag(recognizer.location(in: recognizer.view).x)
            default: break
            }
        }

        /// Only a drag that sets off sideways is the chart's; the scroll view keeps the rest.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

// MARK: - VoiceOver

/// Describes the chart to VoiceOver's audio graph and data browser: a series per device over
/// the buckets.
private nonisolated struct AdvancedEnergyChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let chart: AdvancedChartModel

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: title, summary: nil, xAxis: bucketAxis, yAxis: energyAxis, additionalAxes: [], series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = title
        descriptor.xAxis = bucketAxis
        descriptor.yAxis = energyAxis
        descriptor.series = series
    }

    private var bucketAxis: AXCategoricalDataAxisDescriptor {
        AXCategoricalDataAxisDescriptor(title: "Time", categoryOrder: chart.buckets.map(\.longLabel))
    }

    private var energyAxis: AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(
            title: "Energy", range: 0...max(chart.yMax, 0.001), gridlinePositions: chart.ticks.map(\.kWh)
        ) { value in
            Format.fmtKwh(value)
        }
    }

    private var series: [AXDataSeriesDescriptor] {
        // Devices in the order their segments first appear, which is dashboard order.
        var names: [(id: String, name: String)] = []
        for segment in chart.buckets.flatMap(\.segments) where !names.contains(where: { $0.id == segment.deviceID }) {
            names.append((segment.deviceID, segment.name))
        }
        return names.map { device in
            let points = chart.buckets.map { bucket in
                AXDataPoint(x: bucket.longLabel, y: bucket.segments.first { $0.deviceID == device.id }?.kWh ?? 0)
            }
            return AXDataSeriesDescriptor(name: device.name, isContinuous: false, dataPoints: points)
        }
    }
}

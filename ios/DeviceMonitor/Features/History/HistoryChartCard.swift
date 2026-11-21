import Accessibility
import DMCore
import SwiftUI

/// One chart of the History page (`.hv-chart`): title, legend, and the plot with what is drawn on
/// it while it is touched.
///
/// The card itself reads nothing that changes while a finger is on a chart; `HistoryChartMarks`,
/// the tooltip and the accessibility value do, each in a body of its own.
struct HistoryChartCard: View {
    let chart: HistoryChartModel
    /// The page the chart belongs to: its window is the time axis every chart shares.
    let model: HistoryModel
    let controller: HistoryController

    @ScaledMetric(relativeTo: .caption2) private var scaledAxisFontSize: CGFloat = DMTextStyle.axis.size

    /// Axis text follows Dynamic Type up to a point; the chart's gutter and height grow with it.
    private var axisFontSize: CGFloat { min(scaledAxisFontSize, 16) }
    private var scale: CGFloat { axisFontSize / DMTextStyle.axis.size }

    var body: some View {
        let scale = scale
        VStack(alignment: .leading, spacing: 0) {
            HistoryChartHeader(controller: controller, chart: chart)
            GeometryReader { proxy in
                let geometry = HistoryChartGeometry(size: proxy.size, scale: scale, from: model.from, to: model.to)
                ZStack {
                    HistoryChartPlot(
                        chart: chart, geometry: geometry,
                        timeAxis: HistoryTimeAxis(model: model, geometry: geometry, fontSize: axisFontSize),
                        fontSize: axisFontSize
                    )
                    HistoryChartMarks(controller: controller, chart: chart, geometry: geometry)
                    HistoryChartTouchSurface { touch in
                        handle(touch, in: geometry)
                    }
                    .accessibilityHidden(true)
                }
                // With a pointer (an iPad's trackpad) the crosshair follows it, as on the dashboard.
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): _ = handle(.hover(x: location.x), in: geometry)
                    case .ended: _ = handle(.pointEnded, in: geometry)
                    }
                }
            }
            .frame(height: HistoryChartGeometry.height(scale: scale))
        }
        .overlay {
            HistoryChartTooltip(controller: controller, chart: chart, from: model.from, to: model.to, scale: scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.panelPadding)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .modifier(HistoryChartAccessibility(controller: controller, chart: chart, model: model))
    }

    /// Hands a touch to the controller, in the coordinates the presentation layer counts in.
    private func handle(_ touch: HistoryChartTouch, in geometry: HistoryChartGeometry) -> Bool {
        let chartWidth = geometry.layout.width
        switch touch {
        case .point(let x):
            controller.point(at: geometry.layoutX(x), chartWidth: chartWidth)
        case .hover(let x):
            controller.point(at: geometry.layoutX(x), chartWidth: chartWidth, holding: false)
        case .pointEnded:
            controller.endPointing()
        case .selectionBegan(let start, let x):
            controller.beginSelection(from: geometry.layoutX(start), to: geometry.layoutX(x), chartWidth: chartWidth)
        case .selectionMoved(let x):
            controller.moveSelection(to: geometry.layoutX(x))
        case .selectionEnded(let commit):
            return controller.endSelection(commit: commit)
        case .pinchBegan(let x):
            controller.beginPinch(at: geometry.layoutX(x), chartWidth: chartWidth)
        case .pinchMoved(let scale):
            controller.movePinch(scale: Double(scale))
        case .pinchEnded(let scale, let commit):
            return controller.endPinch(scale: Double(scale), commit: commit)
        case .doubleTap:
            return controller.resetZoomIfZoomed()
        }
        return false
    }
}

/// Title and legend of a chart. While a moment is marked they make way for the tooltip, which
/// names the same series and has nowhere else to go that a finger does not cover.
private struct HistoryChartHeader: View {
    let controller: HistoryController
    let chart: HistoryChartModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isCovered = controller.tooltip.map { !$0.rows(for: chart.kind).isEmpty } ?? false
        VStack(alignment: .leading, spacing: 0) {
            Text(chart.title)
                .dmFont(.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            LegendRow(chart.series.map { (label: $0.label, color: $0.tint.historyColor) })
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isCovered ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isCovered)
    }
}

/// The tooltip of one chart, when the marked moment has a reading for it.
private struct HistoryChartTooltip: View {
    let controller: HistoryController
    let chart: HistoryChartModel
    let from: Double
    let to: Double
    let scale: CGFloat

    var body: some View {
        if let tooltip = controller.tooltip {
            // if (rows.length) { … tip.style.display = 'block'; }
            let rows = tooltip.rows(for: chart.kind)
            if !rows.isEmpty {
                HistoryTooltipPlacement(time: tooltip.t, from: from, to: to, scale: scale) {
                    HistoryTooltipView(title: tooltip.title, rows: rows)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// A chart card for VoiceOver: one element named after the chart, whose value is the reading at
/// the marked moment (the newest one until it is moved), adjustable through time, with an audio
/// graph, and with the zoom as actions.
private struct HistoryChartAccessibility: ViewModifier {
    let controller: HistoryController
    let chart: HistoryChartModel
    let model: HistoryModel

    @AccessibilityFocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chart.title)
            .accessibilityValue(controller.spokenValue(for: chart))
            .accessibilityAdjustableAction { controller.step($0) }
            .accessibilityAction(named: "Zoom in") { controller.zoomInForAccessibility() }
            .modifier(ResetAction(controller: controller))
            .accessibilityChartDescriptor(HistoryChartDescriptor(chart: chart, from: model.from, to: model.to))
            .accessibilityFocused($isFocused)
            .onChange(of: isFocused) { _, isFocused in
                if !isFocused { controller.endPointing() }
            }
            .accessibilityIdentifier("history-chart-\(chart.kind.rawValue)")
    }

    private struct ResetAction: ViewModifier {
        let controller: HistoryController

        func body(content: Content) -> some View {
            if controller.window.showsReset {
                content.accessibilityAction(named: HistoryWindow.resetTitle) { controller.resetZoom() }
            } else {
                content
            }
        }
    }
}

/// Describes a chart to VoiceOver's audio graph and data browser.
private nonisolated struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    let chart: HistoryChartModel
    let from: Double
    let to: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: chart.title, summary: nil, xAxis: timeAxis, yAxis: valueAxis, additionalAxes: [], series: dataSeries)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = chart.title
        descriptor.xAxis = timeAxis
        descriptor.yAxis = valueAxis
        descriptor.series = dataSeries
    }

    private var timeAxis: AXNumericDataAxisDescriptor {
        let span = to - from
        return AXNumericDataAxisDescriptor(title: "Time", range: from...max(from + 1, to), gridlinePositions: []) { t in
            Format.timeLabel(t, span)
        }
    }

    private var valueAxis: AXNumericDataAxisDescriptor {
        let chart = chart
        return AXNumericDataAxisDescriptor(title: chart.title, range: 0...max(1, chart.yMax), gridlinePositions: chart.gridLevels.map(\.value)) { value in
            chart.axisLabel(value)
        }
    }

    private var dataSeries: [AXDataSeriesDescriptor] {
        chart.series.map { series in
            AXDataSeriesDescriptor(
                name: series.label, isContinuous: true,
                dataPoints: series.lines.joined().map { AXDataPoint(x: $0.t, y: $0.value) }
            )
        }
    }
}

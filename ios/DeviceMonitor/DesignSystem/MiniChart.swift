import Accessibility
import SwiftUI
import UIKit

/// The small chart of a device card, ported from `drawChart()` in public/index.html: a fixed
/// 0–100 % axis with grid lines and labels at 0 / 50 / 100 %, up to three 2-point lines, gaps where
/// the device was not reporting, and a crosshair with dots while scrubbing.
///
/// Touch and hold, then drag, to scrub: holding first leaves a quick swipe to the surrounding scroll
/// view. The nearest sample is reported through `selection`; show it with `chartTooltip(for:)`.
///
/// Drawing is one `Canvas` pass over the points, so it is cheap to refresh every two seconds.
struct MiniChart: View {
    private let series: [MiniChartSeries]
    private let windowEnd: Double
    private let windowSpan: Double
    private let gapInterval: Double
    @Binding private var selection: MiniChartSelection?
    private let height: CGFloat
    private let label: String
    private let onTap: (() -> Void)?

    /// Where the finger is, as a fraction of the chart's width (the dashboard's `hover`).
    @State private var scrubFraction: Double?
    @ScaledMetric(relativeTo: .caption2) private var scaledAxisFontSize: CGFloat = DMTextStyle.axis.size
    @Environment(\.displayScale) private var displayScale

    /// Axis labels follow Dynamic Type up to a point, and the chart grows with them so the three
    /// labels never collide.
    private var axisFontSize: CGFloat { min(scaledAxisFontSize, 16) }
    private var scaledHeight: CGFloat { height * axisFontSize / DMTextStyle.axis.size }

    /// - Parameters:
    ///   - series: Lines to draw, first at the back. Times are milliseconds since the Unix epoch.
    ///   - windowEnd: Right edge of the time axis, normally now.
    ///   - windowSpan: Length of the time axis in milliseconds; the window is `[end - span, end]`.
    ///   - gapInterval: Consecutive readings further apart than this are not connected. See
    ///     `MiniChartGeometry.gapInterval(resolution:)`.
    ///   - selection: Set to the sample under the crosshair while scrubbing, `nil` otherwise.
    ///   - height: Height at the default text size; 64 matches the dashboard.
    ///   - accessibilityLabel: What the chart shows, for VoiceOver.
    ///   - scrubPreview: Starts with the crosshair at this fraction of the width. For previews and
    ///     screenshots.
    ///   - onTap: Called for a tap (the dashboard opens the device's history).
    init(
        series: [MiniChartSeries],
        windowEnd: Double,
        windowSpan: Double,
        gapInterval: Double = 10_000,
        selection: Binding<MiniChartSelection?> = .constant(nil),
        height: CGFloat = 64,
        accessibilityLabel: String = "Usage chart",
        scrubPreview: Double? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.series = series
        self.windowEnd = windowEnd
        self.windowSpan = windowSpan
        self.gapInterval = gapInterval
        _selection = selection
        self.height = height
        self.label = accessibilityLabel
        self.onTap = onTap
        _scrubFraction = State(initialValue: scrubPreview)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = MiniChartGeometry(size: proxy.size, windowEnd: windowEnd, windowSpan: windowSpan, axisFontSize: axisFontSize)
            // Recomputed on every refresh, so the crosshair follows the data while the finger rests.
            let current = scrubFraction.flatMap { geometry.selection(atX: CGFloat($0) * proxy.size.width, in: series) }
            Canvas { context, _ in
                draw(in: &context, geometry: geometry, selection: current)
            }
            .overlay {
                ScrubSurface(isTapEnabled: onTap != nil) { x in
                    scrubFraction = x.map { Double($0 / max(1, proxy.size.width)) }
                } onTap: {
                    onTap?()
                }
            }
            .onChange(of: current, initial: true) { _, newValue in
                selection = newValue
            }
        }
        .frame(height: scaledHeight)
        .onDisappear { selection = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(latestSummary)
        .accessibilityChartDescriptor(MiniChartDescriptor(title: label, series: series, windowStart: windowEnd - windowSpan, windowEnd: windowEnd))
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
        .accessibilityAction { onTap?() }
    }

    /// "CPU 28%, GPU 81%, Memory 46%": the most recent reading of each line.
    private var latestSummary: String {
        let parts = series.compactMap { line -> String? in
            guard let value = line.points.last(where: { $0.value != nil })?.value else { return nil }
            return "\(line.label) \(Theme.percentText(value))"
        }
        return parts.isEmpty ? "No data" : parts.joined(separator: ", ")
    }

    private func draw(in context: inout GraphicsContext, geometry: MiniChartGeometry, selection: MiniChartSelection?) {
        guard geometry.plotWidth > 0, geometry.plotHeight > 0 else { return }
        let scale = max(1, displayScale)
        // Centre one-point lines on whole device pixels so they stay crisp.
        func crisp(_ value: CGFloat) -> CGFloat { ((value - 0.5) * scale).rounded() / scale + 0.5 }

        for level in [0.0, 50, 100] {
            let y = crisp(geometry.y(level))
            var line = Path()
            line.move(to: CGPoint(x: geometry.padLeading, y: y))
            line.addLine(to: CGPoint(x: geometry.size.width - geometry.padTrailing, y: y))
            context.stroke(line, with: .color(level == 0 ? Theme.axis : Theme.grid), lineWidth: 1)
            context.draw(
                Text("\(Int(level))%").font(.system(size: axisFontSize)).foregroundStyle(Theme.textMuted),
                at: CGPoint(x: geometry.padLeading - 6, y: geometry.y(level)),
                anchor: .trailing
            )
        }

        var lines = context
        lines.clip(to: Path(geometry.plot.insetBy(dx: -1, dy: -2)))
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        for line in series {
            lines.stroke(geometry.path(for: line.points, gapInterval: gapInterval), with: .color(line.color), style: stroke)
        }

        guard let selection else { return }
        let x = crisp(selection.x)
        var crosshair = Path()
        crosshair.move(to: CGPoint(x: x, y: geometry.padTop))
        crosshair.addLine(to: CGPoint(x: x, y: geometry.padTop + geometry.plotHeight))
        context.stroke(crosshair, with: .color(Theme.textMuted), lineWidth: 1)
        for entry in selection.entries {
            let dot = Path(ellipseIn: CGRect(x: selection.x - 4, y: geometry.y(entry.value) - 4, width: 8, height: 8))
            context.fill(dot, with: .color(entry.color))
            context.stroke(dot, with: .color(Theme.surface1), lineWidth: 2)
        }
    }
}

/// A transparent view that reports press-and-drag positions and taps.
///
/// UIKit's long-press recogniser gives the touch position from the moment the hold is recognised and
/// then keeps the enclosing scroll view from panning; a quick swipe never reaches it. SwiftUI's
/// sequenced gestures have no position until the finger moves.
private struct ScrubSurface: UIViewRepresentable {
    var isTapEnabled: Bool
    var onScrub: (CGFloat?) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = 0.18
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
        context.coordinator.tap?.isEnabled = isTapEnabled
    }

    final class Coordinator: NSObject {
        var surface: ScrubSurface
        weak var tap: UITapGestureRecognizer?
        private let feedback = UISelectionFeedbackGenerator()

        init(surface: ScrubSurface) {
            self.surface = surface
        }

        @objc func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                feedback.selectionChanged()
                surface.onScrub(recognizer.location(in: recognizer.view).x)
            case .changed:
                surface.onScrub(recognizer.location(in: recognizer.view).x)
            default:
                surface.onScrub(nil)
            }
        }

        @objc func handleTap() {
            surface.onTap()
        }
    }
}

/// Describes the chart to VoiceOver's audio graph and data browser.
private nonisolated struct MiniChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let series: [MiniChartSeries]
    let windowStart: Double
    let windowEnd: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: title, summary: nil, xAxis: timeAxis, yAxis: percentAxis, additionalAxes: [], series: dataSeries)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = title
        descriptor.xAxis = timeAxis
        descriptor.series = dataSeries
    }

    private var timeAxis: AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: "Time", range: windowStart...max(windowStart + 1, windowEnd), gridlinePositions: []) { t in
            Date(timeIntervalSince1970: t / 1000).formatted(date: .omitted, time: .standard)
        }
    }

    private var percentAxis: AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: "Percent", range: 0...100, gridlinePositions: [0, 50, 100]) { value in
            Theme.percentText(value)
        }
    }

    private var dataSeries: [AXDataSeriesDescriptor] {
        series.map { line in
            let points = line.points.compactMap { point -> AXDataPoint? in
                guard point.t >= windowStart, let value = point.value else { return nil }
                return AXDataPoint(x: point.t, y: value)
            }
            return AXDataSeriesDescriptor(name: line.label, isContinuous: true, dataPoints: points)
        }
    }
}

/// One line of a `ChartTooltip`.
nonisolated struct ChartTooltipRow: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var value: String
    /// Extra text after the value, e.g. the temperature at that moment.
    var detail: String?
    var color: Color

    init(id: String? = nil, label: String, value: String, detail: String? = nil, color: Color) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.detail = detail
        self.color = color
    }
}

/// The floating read-out of a scrubbed chart (`.tip`): a muted time line, then one row per series
/// with its colour, label and bold value.
struct ChartTooltip: View {
    private let title: String
    private let rows: [ChartTooltipRow]

    init(title: String, rows: [ChartTooltipRow]) {
        self.title = title
        self.rows = rows
    }

    /// Rows for a `MiniChart` selection, with percentages formatted like the gauges.
    init(title: String, selection: MiniChartSelection) {
        self.init(title: title, rows: selection.entries.map {
            ChartTooltipRow(id: $0.id, label: $0.label, value: Theme.percentText($0.value), color: $0.color)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 2)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(row.color)
                        .frame(width: 8, height: 2)
                    Text("\(row.label) ") + Text(row.value).fontWeight(.semibold) + Text(row.detail.map { " · \($0)" } ?? "")
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
        .dmFont(.caption)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .dmSurface(Theme.inset, radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// Where `chartTooltip(for:)` puts the tooltip.
nonisolated enum ChartTooltipPlacement: Sendable {
    /// Just above the chart, clear of the finger.
    case above
    /// Over the top of the chart, where the dashboard puts it for a mouse.
    case inside
}

extension View {
    /// Overlays a tooltip beside the crosshair of a scrubbed `MiniChart`, flipping to the other side
    /// near the trailing edge and never leaving the chart's width (the dashboard's placement).
    /// Apply to the `MiniChart` itself.
    func chartTooltip<Tooltip: View>(
        for selection: MiniChartSelection?,
        placement: ChartTooltipPlacement = .above,
        @ViewBuilder content: (MiniChartSelection) -> Tooltip
    ) -> some View {
        overlay {
            if let selection {
                ChartTooltipLayout(crosshairX: selection.x, placement: placement) {
                    content(selection)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// Places the tooltip relative to the crosshair. The arithmetic is the dashboard's:
/// `left = min(W - tw, max(0, px + 12 > W - tw ? px - tw - 12 : px + 12))`.
private struct ChartTooltipLayout: Layout {
    var crosshairX: CGFloat
    var placement: ChartTooltipPlacement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(.unspecified)
        let room = bounds.width - size.width
        let beside = crosshairX + 12 > room ? crosshairX - size.width - 12 : crosshairX + 12
        let x = min(room, max(0, beside))
        let y = placement == .above ? -size.height - 4 : 2
        tooltip.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

#Preview("Mini chart") {
    @Previewable @State var selection: MiniChartSelection?
    let end = Date.now.timeIntervalSince1970 * 1000
    let points: (Double, Double) -> [MiniChartPoint] = { base, swing in
        (0..<300).map { index in
            let t = end - Double(299 - index) * 2000
            // A pause in the middle shows how gaps are drawn.
            let value: Double? = (140..<160).contains(index) ? nil : base + swing * sin(Double(index) / 14)
            return MiniChartPoint(t: t, value: value)
        }
    }
    DMCard {
        LegendRow([("CPU", Theme.cpu), ("GPU", Theme.gpu), ("Memory", Theme.mem)])
        MiniChart(
            series: [
                MiniChartSeries(id: "cpu", label: "CPU", color: Theme.cpu, points: points(22, 9)),
                MiniChartSeries(id: "gpu", label: "GPU", color: Theme.gpu, points: points(78, 12)),
                MiniChartSeries(id: "mem", label: "Memory", color: Theme.mem, points: points(46, 1)),
            ],
            windowEnd: end,
            windowSpan: 10 * 60_000,
            selection: $selection,
            scrubPreview: 0.6
        )
        .chartTooltip(for: selection) { ChartTooltip(title: "2m 4s ago", selection: $0) }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}

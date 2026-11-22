import DMCore
import SwiftUI

/// The chart of a card with its legend and range (`.chart` and `drawChart` in public/index.html).
/// `CardChartModel` decides the window, the lines and the tooltip; `MiniChart` draws them.
///
/// The chart redraws when its device reports and on every heartbeat of the hub, so the time axis
/// keeps sliding while nothing else changes (`for (const id of devices.keys()) drawChart(id)`).
struct DashboardCardChart: View {
    let deviceID: String
    let series: CardSeries

    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @State private var selection: MiniChartSelection?
    @State private var window = DashboardChartWindow()

    var body: some View {
        let range = CardChartRange(rawValue: store.range(for: deviceID).rawValue) ?? .default
        let now = window.end(for: series, range: range, heartbeat: store.lastStatusAt, clock: store.clock)
        let model = CardChartModel(points: series.points, range: range, now: now, resolution: series.resolution)
        let unit = preferences.temperatureUnit
        VStack(spacing: 6) {
            LegendRow(CardChartModel.legend.map { (label: $0.label, color: $0.tint.dashboardColor) }) {
                DashboardRangeMenu(deviceID: deviceID, range: range)
            }
            // The range menu's reach extends over the top of the chart…
            .zIndex(1)
            MiniChart(
                series: Self.lines(of: model),
                windowEnd: model.end,
                windowSpan: range.duration,
                gapInterval: model.gap,
                selection: $selection,
                accessibilityLabel: "\(DashboardStrings.chart), \(range.label)",
                scrubPreview: Self.scrubPreview,
                onTap: { router.openHistory(deviceID: deviceID) }
            )
            .accessibilityHint(DeviceCardText.chartHint)
            .accessibilityIdentifier(DashboardID.chart(deviceID))
            .chartTooltip(for: selection) { selection in
                if let tooltip = model.tooltip(at: selection.t, unit: unit) {
                    ChartTooltip(title: tooltip.time, rows: tooltip.rows.map { row in
                        ChartTooltipRow(id: row.metric.rawValue, label: row.label, value: row.valueText, detail: row.temperature, color: row.tint.dashboardColor)
                    })
                }
            }
            // …and while scrubbing, the tooltip goes over the legend.
            .zIndex(selection == nil ? 0 : 2)
        }
    }

    /// One line per series of the model. Every sample is passed on, readings or not: a sample
    /// without one lifts the pen, exactly where the model breaks its segments.
    private static func lines(of model: CardChartModel) -> [MiniChartSeries] {
        model.series.map { line in
            MiniChartSeries(
                id: line.metric.rawValue, label: line.label, color: line.tint.dashboardColor,
                points: model.points.map { MiniChartPoint(t: $0.t, value: $0.value(line.metric)) })
        }
    }

    private static var scrubPreview: Double? {
        #if DEBUG
        DashboardDebugOptions.current.scrub
        #else
        nil
        #endif
    }
}

/// When a chart's window ends. The dashboard takes `Date.now()` every time it draws a chart, and it
/// draws when the device reports and on the hub's heartbeat. Here that is the clock's time when
/// the chart last had one of those reasons to redraw, kept until the next: a redraw for any other
/// reason, a finger scrubbing for one, finds the same window and the same sample under it.
private final class DashboardChartWindow {
    private struct Reason: Equatable {
        var heartbeat: Double?
        var range: CardChartRange
        var resolution: Double
        var count: Int
        var first: Double?
        var last: Double?
    }

    private var reason: Reason?
    private var end = 0.0

    func end(for series: CardSeries, range: CardChartRange, heartbeat: Double?, clock: any HubClock) -> Double {
        let current = Reason(
            heartbeat: heartbeat, range: range, resolution: series.resolution, count: series.points.count,
            first: series.points.first?.t, last: series.points.last?.t)
        if current != reason {
            reason = current
            end = clock.now
        }
        return end
    }
}

/// The range of a card's chart, in the legend (`.range-sel`): the current choice in muted text with
/// a chevron, opening a menu of the three ranges. The choice is the store's to keep and to load.
private struct DashboardRangeMenu: View {
    let deviceID: String
    let range: CardChartRange

    @Environment(HubStore.self) private var store

    /// How far the touch target extends beyond the text, which is 16 points tall.
    private static let reach: CGFloat = 15

    var body: some View {
        Menu {
            Picker(DeviceCardText.rangePickerLabel, selection: choice) {
                ForEach(CardChartRange.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(range.label)
                    .dmFont(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .fixedSize()
            .foregroundStyle(Theme.textMuted)
            .padding(.vertical, Self.reach)
            .padding(.horizontal, Theme.Spacing.s)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -Self.reach)
        .padding(.horizontal, -Theme.Spacing.s)
        .sensoryFeedback(.selection, trigger: range)
        .accessibilityLabel(DeviceCardText.rangePickerLabel)
        .accessibilityValue(range.label)
        .accessibilityIdentifier(DashboardID.range(deviceID))
    }

    private var choice: Binding<CardChartRange> {
        Binding {
            range
        } set: { chosen in
            // setRange(id, r): remembers the choice, empties the chart and fetches the series.
            guard chosen != range, let stored = HistoryRange(rawValue: chosen.rawValue) else { return }
            store.setRange(stored, for: deviceID)
        }
    }
}

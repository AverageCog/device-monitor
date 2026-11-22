import Foundation

/// How far back a card's chart reaches. Each card has its own setting (RANGE_MS, RANGE_LABEL).
public enum CardChartRange: String, Sendable, Hashable, CaseIterable, Codable {
    case tenMinutes = "10m"
    case oneHour = "1h"
    case sixHours = "6h"

    /// What a card shows until its range is changed, unless the old dashboard-wide setting says otherwise.
    public static let `default` = CardChartRange.tenMinutes
    /// The `points` a card asks the hub for on the longer ranges (`?range=1h&points=360`).
    public static let historyPoints = 360
    /// The longer ranges are loaded again this often, in milliseconds.
    public static let reloadInterval: Double = 120_000
    /// Resolution of the samples a card on ten minutes is fed live.
    public static let liveResolution: Double = 2000

    /// The name stored in preferences and sent as `range=`.
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tenMinutes: "last 10 min"
        case .oneHour: "last 60 min"
        case .sixHours: "last 6 hours"
        }
    }

    /// Width of the window in milliseconds.
    public var duration: Double {
        switch self {
        case .tenMinutes: 10 * 60e3
        case .oneHour: 60 * 60e3
        case .sixHours: 6 * 3600e3
        }
    }

    /// Ten minutes is drawn from raw samples as they arrive; the longer ranges come from the hub's
    /// history, averaged per minute.
    public var isLive: Bool { self == .tenMinutes }

    /// The range of a card, given what is stored for it and the old dashboard-wide setting.
    ///
    /// `rangeOf = id => RANGE_MS[cardRanges[id]] ? cardRanges[id] : DEFAULT_RANGE`, with
    /// `DEFAULT_RANGE = RANGE_MS[store.get('range')] ? store.get('range') : '10m'`.
    public static func resolve(card: String?, dashboard: String? = nil) -> CardChartRange {
        card.flatMap(CardChartRange.init(rawValue:)) ?? dashboard.flatMap(CardChartRange.init(rawValue:)) ?? .default
    }
}

/// One of the three lines of a card's chart.
public struct CardChartSeries: Sendable, Equatable, Identifiable {
    public let metric: HistoryPoint.Metric
    /// "CPU", "GPU" or "Memory".
    public let label: String
    public let tint: MetricTint
    /// Runs of samples to join with a line; from one run to the next the line is broken (the device
    /// was offline, or had no reading). A run of a single sample draws nothing on the dashboard.
    public let segments: [[CardChartPoint]]

    public var id: HistoryPoint.Metric { metric }
}

public struct CardChartPoint: Sendable, Equatable {
    /// Milliseconds since 1970.
    public let t: Double
    /// Percent, 0–100.
    public let value: Double

    public init(t: Double, value: Double) {
        self.t = t
        self.value = value
    }

    public var date: Date { Date(hubTime: t) }
}

/// A horizontal line of a card's chart with its label ("0%", "50%", "100%").
public struct CardChartAxisLevel: Sendable, Equatable {
    public let value: Double
    public let label: String
    /// The line at 0 is drawn in the axis colour, the others in the grid colour.
    public let isBaseline: Bool
}

/// A legend entry.
public struct CardChartLegendItem: Sendable, Equatable, Identifiable {
    public let metric: HistoryPoint.Metric
    public let label: String
    public let tint: MetricTint

    public var id: HistoryPoint.Metric { metric }
}

/// The small chart on a card (drawChart in public/index.html): CPU, GPU and memory load over the
/// card's range, on one axis from 0 to 100 %, ending now.
///
/// Times and values are in data space. `CardChartLayout` maps them the way the dashboard does.
public struct CardChartModel: Sendable, Equatable {
    /// CPU, GPU, Memory: the legend always names all three, also for a device without a GPU.
    public static let legend: [CardChartLegendItem] = seriesTable.map { CardChartLegendItem(metric: $0.metric, label: $0.label, tint: $0.tint) }
    public static let axisLevels: [CardChartAxisLevel] = [0, 50, 100].map { CardChartAxisLevel(value: $0, label: JS.string($0) + "%", isBaseline: $0 == 0) }

    // const SERIES = [['cpu', 'CPU', '--cpu'], ['gpu', 'GPU', '--gpu'], ['mem', 'Memory', '--mem']];
    static let seriesTable: [(metric: HistoryPoint.Metric, label: String, tint: MetricTint)] = [(.cpu, "CPU", .cpu), (.gpu, "GPU", .gpu), (.mem, "Memory", .mem)]

    public let range: CardChartRange
    /// Left edge of the window: `now - range.duration`.
    public let start: Double
    /// Right edge of the window: the `now` the model was made with.
    public let end: Double
    public var startDate: Date { Date(hubTime: start) }
    public var endDate: Date { Date(hubTime: end) }
    /// Two samples further apart than this are not joined: `max(10 s, 3 × resolution)`.
    public let gap: Double
    /// The samples the model was made from, untouched: the tooltip looks through all of them.
    public let points: [HistoryPoint]
    /// CPU, GPU, Memory. GPU is left out when no sample has a GPU reading. A series is listed even
    /// when none of its samples fall in the window. Samples newer than `end` (a device whose
    /// clock runs ahead) are kept: the dashboard draws them past the right edge.
    public let series: [CardChartSeries]

    /// - Parameters:
    ///   - points: the card's samples, oldest first: the live samples on ten minutes, the points of
    ///     `GET /api/history/<id>?range=…&points=360` on the longer ranges.
    ///   - resolution: width of one point in milliseconds: 2000 for live samples, else what the
    ///     hub's answer says.
    public init(points: [HistoryPoint], range: CardChartRange, now: Double = Date().hubTime, resolution: Double = CardChartRange.liveResolution) {
        // const r = rangeOf(id), span = RANGE_MS[r], tEnd = Date.now(), tStart = tEnd - span;
        let tStart = now - range.duration
        // const gap = Math.max(10000, ser.resolution * 3);
        let gap = max(10000, resolution * 3)
        self.range = range
        self.points = points
        self.gap = gap
        end = now
        start = tStart

        // const hasGpu = hist.some(s => s.gpu != null);
        let hasGpu = points.contains { $0.gpu != nil }
        series = CardChartModel.seriesTable.compactMap { entry in
            if entry.metric == .gpu && !hasGpu { return nil }
            var segments = [[CardChartPoint]]()
            var pen = false, prevT = 0.0
            for s in points {
                // if (s.t < tStart || s[key] == null) { pen = false; continue; }
                guard !(s.t < tStart), let value = s.value(entry.metric) else {
                    pen = false
                    continue
                }
                // if (pen && s.t - prevT > gap) pen = false;  // gap when device was offline
                if pen && s.t - prevT > gap { pen = false }
                if pen {
                    segments[segments.count - 1].append(CardChartPoint(t: s.t, value: value))
                } else {
                    segments.append([CardChartPoint(t: s.t, value: value)])
                }
                pen = true
                prevT = s.t
            }
            return CardChartSeries(metric: entry.metric, label: entry.label, tint: entry.tint, segments: segments)
        }
    }

    /// The sample a scrub position lands on: the one nearest in time, the earlier of two equally
    /// near. nil without samples, and when the nearest one is older than the window.
    public func nearestSample(to time: Double) -> HistoryPoint? {
        // let best = null; for (const s of hist) if (!best || Math.abs(s.t - tH) < Math.abs(best.t - tH)) best = s;
        var best: HistoryPoint?
        for s in points {
            if let current = best, !(abs(s.t - time) < abs(current.t - time)) { continue }
            best = s
        }
        // if (best && best.t >= tStart)
        guard let best, best.t >= start else { return nil }
        return best
    }

    /// What the dashboard shows next to the pointer: the nearest sample's time and its readings.
    /// nil when there is nothing to point at.
    public func tooltip(at time: Double, unit: TemperatureUnit, locale: Locale = .current, timeZone: TimeZone = .current) -> CardChartTooltipModel? {
        guard let best = nearestSample(to: time) else { return nil }
        let rows = CardChartModel.seriesTable.compactMap { entry -> CardChartTooltipRow? in
            guard let value = best.value(entry.metric) else { return nil }
            // ${k === 'cpu' && best.cpuTemp != null ? ' · ' + fmtTemp(best.cpuTemp) : ''}${k === 'gpu' && best.gpuTemp != null ? ' · ' + fmtTemp(best.gpuTemp) : ''}
            let celsius: Double? = entry.metric == .cpu ? best.cpuTemp : entry.metric == .gpu ? best.gpuTemp : nil
            return CardChartTooltipRow(
                metric: entry.metric, label: entry.label, tint: entry.tint, value: value,
                valueText: Format.fmtPct(value), temperature: celsius.map { Format.fmtTemp($0, unit) }
            )
        }
        return CardChartTooltipModel(
            t: best.t,
            time: Format.cardTooltipTime(best.t, live: range == .tenMinutes, now: end, locale: locale, timeZone: timeZone),
            rows: rows
        )
    }
}

/// The tooltip of a card's chart.
public struct CardChartTooltipModel: Sendable, Equatable {
    /// Time of the sample: where the vertical marker goes.
    public let t: Double
    public var date: Date { Date(hubTime: t) }
    /// "now", "12s ago", "3m 5s ago" on the ten-minute range; a clock time ("2:17 PM") on the others.
    public let time: String
    /// One row per reading the sample has, in the order CPU, GPU, Memory. Can be empty: the
    /// dashboard then shows the time alone.
    public let rows: [CardChartTooltipRow]
}

public struct CardChartTooltipRow: Sendable, Equatable, Identifiable {
    public let metric: HistoryPoint.Metric
    public let label: String
    public let tint: MetricTint
    /// The reading in percent: where the dot on the line goes.
    public let value: Double
    /// "28%", set in bold on the dashboard.
    public let valueText: String
    /// The part's temperature at that moment ("59°C"), for CPU and GPU when the sample has one.
    public let temperature: String?

    public var id: HistoryPoint.Metric { metric }

    /// The row as one line: "CPU 28% · 59°C", "Memory 43%".
    public var text: String {
        label + " " + valueText + (temperature.map { " \u{B7} " + $0 } ?? "")
    }
}

/// Where the dashboard puts things on a card's chart canvas (drawChart): a 30-point gutter on the
/// left for the labels, the plot ending four points from the right edge.
public struct CardChartLayout: Sendable, Equatable {
    public struct Padding: Sendable, Equatable {
        public let left: Double, right: Double, top: Double, bottom: Double
    }

    // const padL = 30, padR = 4, padT = 6, padB = 6;
    public static let padding = Padding(left: 30, right: 4, top: 6, bottom: 6)
    /// Height of the canvas on the dashboard.
    public static let height: Double = 64

    public let width: Double
    public let height: Double
    /// The window's edges, in milliseconds.
    public let start: Double
    public let end: Double

    public init(width: Double, height: Double = CardChartLayout.height, start: Double, end: Double) {
        self.width = width
        self.height = height
        self.start = start
        self.end = end
    }

    public init(width: Double, height: Double = CardChartLayout.height, model: CardChartModel) {
        self.init(width: width, height: height, start: model.start, end: model.end)
    }

    public var plotWidth: Double { width - CardChartLayout.padding.left - CardChartLayout.padding.right }
    public var plotHeight: Double { height - CardChartLayout.padding.top - CardChartLayout.padding.bottom }

    // const x = t => padL + (t - tStart) / span * cw;
    public func x(_ t: Double) -> Double {
        CardChartLayout.padding.left + (t - start) / (end - start) * plotWidth
    }

    // const y = v => padT + ch - (v / 100) * ch;
    public func y(_ value: Double) -> Double {
        CardChartLayout.padding.top + plotHeight - (value / 100) * plotHeight
    }

    /// The time under a horizontal position: `tStart + ((hover * W - padL) / cw) * span`.
    public func time(atX x: Double) -> Double {
        start + ((x - CardChartLayout.padding.left) / plotWidth) * (end - start)
    }
}

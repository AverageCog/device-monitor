import Foundation

/// The history page for one device and one window of time (loadHistory, renderTiles, buildHvCharts
/// and drawHvChart in public/index.html): the peak tiles and the charts that have data.
///
/// Times are milliseconds since 1970 and values are in the unit they are shown in (temperatures
/// converted), so a view only has to scale them. `HistoryChartLayout` scales them the dashboard's way.
public struct HistoryModel: Sendable, Equatable {
    /// What the page says in place of the charts when the window holds no reading at all.
    public static let emptyText = "No history for this time range yet. Data is recorded while the device is online."
    /// The dashboard's note under the charts, written for a mouse.
    public static let pointerHint = "Hover to inspect \u{B7} drag across a chart to zoom in \u{B7} double-click to reset. Shaded bands show the peak within each interval."
    /// The part of that note that holds for any input.
    public static let bandsHint = "Shaded bands show the peak within each interval."

    /// The window the charts span. It is the window that was asked for, not the first and last point.
    public let from: Double
    public let to: Double
    /// Width of one point in milliseconds, as the hub's answer says: up to 2500 for raw samples.
    public let resolution: Double
    /// Two points further apart than this are not joined: `max(10 s, 3 × resolution)`.
    public let gap: Double
    public let unit: TemperatureUnit
    /// The points the model was made from: the tooltip looks through all of them.
    public let points: [HistoryPoint]
    /// CPU, GPU, Memory, CPU temp, GPU temp, GPU power: those the window has a reading for.
    public let tiles: [HistoryTileModel]
    /// Utilization, Temperature, GPU power, Network, Disk I/O: those the window has a reading for.
    public let charts: [HistoryChartModel]

    /// `emptyText` when there is no chart to show.
    public var emptyText: String? { charts.isEmpty ? HistoryModel.emptyText : nil }

    public var span: Double { to - from }
    public var fromDate: Date { Date(hubTime: from) }
    public var toDate: Date { Date(hubTime: to) }

    public init(response: HistoryResponse, window: HistoryWindow, unit: TemperatureUnit) {
        self.init(points: response.points, resolution: response.resolution, from: window.from, to: window.to, unit: unit)
    }

    /// - Parameters:
    ///   - points: the hub's answer, oldest first.
    ///   - resolution: the answer's `resolution` (the dashboard takes a minute when it is missing;
    ///     `HistoryResponse` already does).
    ///   - from, to: the window that was asked for.
    public init(points: [HistoryPoint], resolution: Double, from: Double, to: Double, unit: TemperatureUnit) {
        self.points = points
        self.resolution = resolution
        self.from = from
        self.to = to
        self.unit = unit
        // const gap = Math.max(10e3, hv.resolution * 3);
        let gap = max(10e3, resolution * 3)
        self.gap = gap
        tiles = HistoryTileModel.Kind.allCases.compactMap { HistoryTileModel(kind: $0, points: points, unit: unit) }
        charts = HistoryChartModel.Kind.allCases.compactMap { HistoryChartModel(kind: $0, points: points, gap: gap, unit: unit) }
    }

    // MARK: Time axis

    /// How many stretches the time axis is divided into on a chart `chartWidth` wide (gutter
    /// included): one label per 140 points, at least 2 stretches and at most 7.
    ///
    /// `nx = Math.max(2, Math.min(7, Math.floor((W - PAD.l) / 140)))`
    public static func timeDivisions(chartWidth: Double) -> Int {
        let fit = ((chartWidth - HistoryChartLayout.padding.left) / 140).rounded(.down)
        return fit.isNaN ? 2 : Int(max(2, min(7, fit)))
    }

    /// The labels under a chart `chartWidth` wide: evenly spaced from the left edge of the window
    /// to the right one. They show the time for windows up to 36 hours, day and time up to 8 days
    /// and the day alone beyond that.
    public func timeTicks(chartWidth: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> [HistoryTimeTick] {
        timeTicks(divisions: HistoryModel.timeDivisions(chartWidth: chartWidth), locale: locale, timeZone: timeZone)
    }

    /// The same for a view that decides the number of stretches itself.
    public func timeTicks(divisions: Int, locale: Locale = .current, timeZone: TimeZone = .current) -> [HistoryTimeTick] {
        let nx = max(1, divisions), span = to - from
        // for (let i = 0; i <= nx; i++) { const t = hv.from + span * i / nx … ctx.textAlign = i === 0 ? 'left' : i === nx ? 'right' : 'center'; ctx.fillText(timeLabel(t, span), …) }
        return (0...nx).map { i in
            let t = from + span * Double(i) / Double(nx)
            return HistoryTimeTick(
                index: i, t: t, label: Format.timeLabel(t, span, locale: locale, timeZone: timeZone),
                alignment: i == 0 ? .leading : i == nx ? .trailing : .center
            )
        }
    }

    // MARK: Pointing at a moment

    /// The point nearest to a time, the earlier of two equally near. nil without points.
    public func nearestPoint(to time: Double) -> HistoryPoint? {
        // let best = null; for (const p of P) if (!best || Math.abs(p.t - hv.hoverT) < Math.abs(best.t - hv.hoverT)) best = p;
        var best: HistoryPoint?
        for p in points {
            if let current = best, !(abs(p.t - time) < abs(current.t - time)) { continue }
            best = p
        }
        return best
    }

    /// How far a point may be from the pointer and still be picked: the gap between points, or a
    /// fiftieth of the window if that is more.
    public var tooltipReach: Double { max(gap, span / 50) }

    /// What all charts show for a time under the pointer: a marker at the nearest point and that
    /// point's readings. nil when no point is within reach, and when there is no chart to show it on.
    public func tooltip(at time: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> HistoryTooltipModel? {
        // if (best && Math.abs(best.t - hv.hoverT) <= Math.max(gap, span / 50))
        guard !charts.isEmpty, let best = nearestPoint(to: time), abs(best.t - time) <= tooltipReach else { return nil }
        return HistoryTooltipModel(
            t: best.t,
            title: Format.historyTooltipTime(best.t, resolution: resolution, locale: locale, timeZone: timeZone) + Format.historyResolutionSuffix(resolution),
            charts: charts.map { chart in
                HistoryTooltipModel.ChartRows(kind: chart.kind, rows: chart.series.compactMap { chart.tooltipRow(for: $0, at: best) })
            }
        )
    }
}

/// A label under a history chart.
public struct HistoryTimeTick: Sendable, Equatable, Identifiable {
    public enum Alignment: Sendable, Equatable {
        /// The first label starts at its position, the last one ends at it, the others are centred on it.
        case leading, center, trailing
    }

    public let index: Int
    public let t: Double
    public let label: String
    public let alignment: Alignment

    public var id: Int { index }
    public var date: Date { Date(hubTime: t) }
}

/// A tile above the charts: the highest value in the window, with the average under it.
public struct HistoryTileModel: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case cpu, gpu, mem, cpuTemp, gpuTemp, gpuPower

        var metric: HistoryPoint.Metric {
            switch self {
            case .cpu: .cpu
            case .gpu: .gpu
            case .mem: .mem
            case .cpuTemp: .cpuTemp
            case .gpuTemp: .gpuTemp
            case .gpuPower: .gpuPower
            }
        }
    }

    public let kind: Kind
    /// "CPU", "GPU", "Memory", "CPU temp", "GPU temp", "GPU power"; the dashboard shows it in capitals.
    public let label: String
    /// Colour of the small mark in front of the label.
    public let tint: MetricTint
    /// The peak, formatted: "39%", "75°C", "396 W".
    public let value: String
    /// "peak · avg 24%".
    public let detail: String
    /// The numbers behind the texts, as the hub gave them (temperatures in °C).
    public let peak: Double
    public let average: Double

    public var id: Kind { kind }

    /// nil when no point has a reading for the tile.
    init?(kind: Kind, points: [HistoryPoint], unit: TemperatureUnit) {
        // const stats = key => { let sum = 0, n = 0, peak = null;
        //   for (const p of P) { const v = p[key], m = p[key + 'Max'] ?? v; if (v != null) { sum += v; n++; } if (m != null && (peak == null || m > peak)) peak = m; }
        //   return n ? { avg: sum / n, peak } : null; };
        var sum = 0.0, n = 0.0, peak: Double?
        for p in points {
            let v = p.value(kind.metric), m = p.peak(kind.metric) ?? v
            if let v {
                sum += v
                n += 1
            }
            if let m, peak.map({ m > $0 }) ?? true { peak = m }
        }
        guard n > 0, let peak else { return nil }
        self.kind = kind
        self.peak = peak
        average = sum / n
        let format: (Double) -> String
        switch kind {
        case .cpu:
            label = "CPU"
            tint = .cpu
            format = { Format.fmtPct($0) }
        case .gpu:
            label = "GPU"
            tint = .gpu
            format = { Format.fmtPct($0) }
        case .mem:
            label = "Memory"
            tint = .mem
            format = { Format.fmtPct($0) }
        case .cpuTemp:
            label = "CPU temp"
            tint = .cpu
            format = { Format.fmtTemp($0, unit) }
        case .gpuTemp:
            label = "GPU temp"
            tint = .gpu
            format = { Format.fmtTemp($0, unit) }
        case .gpuPower:
            label = "GPU power"
            tint = .gpu
            format = { JS.string(JS.round($0)) + " W" }
        }
        // <div class="v">${fmt(s.peak)}</div><div class="s">peak · ${avgLabel} ${fmt(s.avg)}</div>
        value = format(peak)
        detail = "peak \u{B7} avg " + format(average)
    }
}

/// One chart of the history page (an entry of HV_CHARTS, as drawHvChart draws it).
public struct HistoryChartModel: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case utilization, temperature, gpuPower, network, diskIO
    }

    public let kind: Kind
    /// "Utilization", "Temperature", "GPU power", "Network", "Disk I/O".
    public let title: String
    /// The unit temperatures are shown in. It matters to the temperature chart only.
    public let unit: TemperatureUnit
    /// The chart's lines, in legend order. Only series with a reading in the window are listed.
    public let series: [HistoryChartSeries]
    /// Top of the value axis; the bottom is always 0. 100 for utilization; for the others the
    /// highest value or peak in the window plus a tenth, rounded up to a round number.
    public let yMax: Double
    /// Five horizontal lines from 0 to `yMax`, bottom to top. Every other one carries a label.
    public let gridLevels: [HistoryChartGridLevel]

    public var id: Kind { kind }

    /// A value of this chart as its tooltip writes it: "39%", "167°F", "396 W", "4.6 MB/s".
    /// Temperatures are given in °C, as the hub reports them.
    public func valueText(_ value: Double) -> String {
        switch kind {
        case .utilization: Format.fmtPct(value)
        case .temperature: Format.fmtTemp(value, unit)
        case .gpuPower: JS.string(JS.round(value)) + " W"
        case .network, .diskIO: Format.fmtRate(value)
        }
    }

    /// A value on the axis as its label writes it: "50%", "120°", "250 W", "5 MB/s". Temperatures
    /// are given in the unit shown, like the grid levels.
    public func axisLabel(_ value: Double) -> String {
        HistoryChartModel.axisLabel(kind, value)
    }

    /// A value as the hub reports it, in the unit the chart shows (`conv`): only temperatures change.
    public func displayValue(_ value: Double) -> Double {
        kind == .temperature ? Format.toF(value, unit) : value
    }

    // const HV_CHARTS = [ { title: 'Utilization', max: 100, series: [['cpu', 'CPU', '--cpu'], …] … }, … ];
    private static func configuration(_ kind: Kind) -> (title: String, max: Double?, series: [(HistoryPoint.Metric, String, MetricTint)]) {
        switch kind {
        case .utilization: ("Utilization", 100, [(.cpu, "CPU", .cpu), (.gpu, "GPU", .gpu), (.mem, "Memory", .mem)])
        case .temperature: ("Temperature", nil, [(.cpuTemp, "CPU", .cpu), (.gpuTemp, "GPU", .gpu)])
        case .gpuPower: ("GPU power", nil, [(.gpuPower, "GPU", .gpu)])
        case .network: ("Network", nil, [(.rx, "Download", .cpu), (.tx, "Upload", .gpu)])
        case .diskIO: ("Disk I/O", nil, [(.dr, "Read", .cpu), (.dw, "Write", .gpu)])
        }
    }

    /// nil when no point has a reading for any of the chart's series.
    init?(kind: Kind, points P: [HistoryPoint], gap: Double, unit: TemperatureUnit) {
        let cfg = HistoryChartModel.configuration(kind)
        // series: c.series.filter(([k]) => hv.points.some(p => p[k] != null))
        let present = cfg.series.filter { entry in P.contains { $0.value(entry.0) != nil } }
        guard !present.isEmpty else { return nil }
        self.kind = kind
        self.unit = unit
        title = cfg.title
        let conv: (Double) -> Double = { kind == .temperature ? Format.toF($0, unit) : $0 }

        // let yMin = 0, yMax = cfg.max;
        // if (!yMax) { let hi = 0; for (const p of P) for (const [k] of cfg.series) { const v = p[k + 'Max'] ?? p[k]; if (v != null) hi = Math.max(hi, conv(v)); } yMax = niceMax(hi * 1.1); }
        let yMax: Double
        if let fixed = cfg.max {
            yMax = fixed
        } else {
            var hi = 0.0
            for p in P {
                for entry in present {
                    if let v = p.peak(entry.0) ?? p.value(entry.0) { hi = max(hi, conv(v)) }
                }
            }
            yMax = Format.niceMax(hi * 1.1)
        }
        self.yMax = yMax

        series = present.map { entry in
            let k = entry.0
            // Peak band (average up to the peak), only when points are aggregated:
            // if (P.some(p => p[k + 'Max'] != null && p[k] != null && p[k + 'Max'] > p[k] + 0.5)) { … }
            var bands = [[HistoryChartBandPoint]]()
            if P.contains(where: { p in
                guard let peak = p.peak(k), let value = p.value(k) else { return false }
                return peak > value + 0.5
            }) {
                var seg = [HistoryChartBandPoint]()
                var prevT = 0.0
                // const flush = () => { if (seg.length > 1) { …fill… } seg = []; };
                func flush() {
                    if seg.count > 1 { bands.append(seg) }
                    seg = []
                }
                // for (const p of P) { if (p[k] == null || (seg.length && p.t - prevT > gap)) flush(); if (p[k] != null) { seg.push(p); prevT = p.t; } }
                for p in P {
                    let value = p.value(k)
                    if value == nil || (!seg.isEmpty && p.t - prevT > gap) { flush() }
                    if let value {
                        seg.append(HistoryChartBandPoint(t: p.t, low: conv(value), high: conv(p.peak(k) ?? value)))
                        prevT = p.t
                    }
                }
                flush()
            }

            // ctx.beginPath(); let pen = false, prevT = 0;
            // for (const p of P) { if (p[k] == null) { pen = false; continue; } if (pen && p.t - prevT > gap) pen = false; pen ? lineTo : moveTo; pen = true; prevT = p.t; }
            var lines = [[HistoryChartPoint]]()
            var pen = false, prevT = 0.0
            for p in P {
                guard let value = p.value(k) else {
                    pen = false
                    continue
                }
                if pen && p.t - prevT > gap { pen = false }
                if pen {
                    lines[lines.count - 1].append(HistoryChartPoint(t: p.t, value: conv(value)))
                } else {
                    lines.append([HistoryChartPoint(t: p.t, value: conv(value))])
                }
                pen = true
                prevT = p.t
            }
            return HistoryChartSeries(metric: k, label: entry.1, tint: entry.2, lines: lines, bands: bands)
        }

        // for (let i = 0; i <= 4; i++) { const v = yMin + (yMax - yMin) * i / 4 … if (i % 2 === 0) fillText(cfg.axis(v)) }
        var levels = [HistoryChartGridLevel]()
        for i in 0...4 {
            let v = yMax * Double(i) / 4
            levels.append(HistoryChartGridLevel(index: i, value: v, label: i % 2 == 0 ? HistoryChartModel.axisLabel(kind, v) : nil))
        }
        gridLevels = levels
    }

    private static func axisLabel(_ kind: Kind, _ value: Double) -> String {
        switch kind {
        case .utilization: JS.string(value) + "%"
        case .temperature: JS.string(JS.round(value)) + "\u{B0}"
        case .gpuPower: JS.string(JS.round(value)) + " W"
        case .network, .diskIO: Format.fmtBytes(value, 0) + "/s"
        }
    }

    /// The tooltip's row for one series at a point; nil when the point has no reading for it.
    func tooltipRow(for series: HistoryChartSeries, at best: HistoryPoint) -> HistoryTooltipRow? {
        guard let value = best.value(series.metric) else { return nil }
        // const peak = best[k + 'Max'] != null && best[k + 'Max'] > best[k] + 0.5 ? ` <span class="hint">peak ${cfg.fmt(best[k + 'Max'])}</span>` : '';
        let peak = best.peak(series.metric).flatMap { $0 > value + 0.5 ? "peak " + valueText($0) : nil }
        return HistoryTooltipRow(
            metric: series.metric, label: series.label, tint: series.tint,
            value: valueText(value), peak: peak, y: displayValue(value)
        )
    }
}

/// One line of a history chart, with the band between its average and its peak.
public struct HistoryChartSeries: Sendable, Equatable, Identifiable {
    public let metric: HistoryPoint.Metric
    /// The legend's name for it: "CPU", "Download", "Read"…
    public let label: String
    public let tint: MetricTint
    /// Runs of points to join with a line. From one run to the next the line is broken: the device
    /// was off, or had no reading. A run of one point draws nothing on the dashboard.
    public let lines: [[HistoryChartPoint]]
    /// Shaded bands between the average (`low`) and the peak (`high`) of each point, one per run of
    /// at least two points. Empty unless some peak in the window is more than half a unit above
    /// its average, which only happens once the hub has averaged several samples into a point.
    public let bands: [[HistoryChartBandPoint]]

    public var id: HistoryPoint.Metric { metric }
}

public struct HistoryChartPoint: Sendable, Equatable {
    public let t: Double
    /// In the unit the chart shows.
    public let value: Double

    public init(t: Double, value: Double) {
        self.t = t
        self.value = value
    }

    public var date: Date { Date(hubTime: t) }
}

public struct HistoryChartBandPoint: Sendable, Equatable {
    public let t: Double
    /// The point's average.
    public let low: Double
    /// The peak within the point's interval; the average again where the hub kept no peak.
    public let high: Double

    public init(t: Double, low: Double, high: Double) {
        self.t = t
        self.low = low
        self.high = high
    }

    public var date: Date { Date(hubTime: t) }
}

/// A horizontal line of a history chart.
public struct HistoryChartGridLevel: Sendable, Equatable, Identifiable {
    /// 0 at the bottom to 4 at the top.
    public let index: Int
    public let value: Double
    /// The label at the left of the line; the second and fourth line have none.
    public let label: String?

    public var id: Int { index }
    /// The bottom line is drawn in the axis colour, the others in the grid colour.
    public var isBaseline: Bool { index == 0 }
}

/// What the charts show for the moment under the pointer (the crosshair and tooltip of
/// drawHvChart). All charts mark the same point.
public struct HistoryTooltipModel: Sendable, Equatable {
    public struct ChartRows: Sendable, Equatable, Identifiable {
        public let kind: HistoryChartModel.Kind
        /// One row per series with a reading at the point. Empty when the chart has none there:
        /// the dashboard then draws the marker on that chart, but no tooltip.
        public let rows: [HistoryTooltipRow]

        public var id: HistoryChartModel.Kind { kind }
    }

    /// Time of the point: where the vertical marker goes on every chart.
    public let t: Double
    public var date: Date { Date(hubTime: t) }
    /// "Fri 2:17:44 PM" for raw samples, else without seconds and with the width of a point:
    /// "Fri 2:17 PM · 5 min avg", "Thu 9:00 AM · 2 h avg".
    public let title: String
    /// One entry per chart of the model, in the same order.
    public let charts: [ChartRows]

    public func rows(for kind: HistoryChartModel.Kind) -> [HistoryTooltipRow] {
        charts.first { $0.kind == kind }?.rows ?? []
    }
}

public struct HistoryTooltipRow: Sendable, Equatable, Identifiable {
    public let metric: HistoryPoint.Metric
    public let label: String
    public let tint: MetricTint
    /// The reading, set in bold on the dashboard: "24%", "59°C", "4.6 MB/s".
    public let value: String
    /// "peak 39%", muted, when the peak within the point's interval is more than half a unit above
    /// its average.
    public let peak: String?
    /// The reading in the unit the chart shows: where the dot on the line goes.
    public let y: Double

    public var id: HistoryPoint.Metric { metric }

    /// The row as one line: "CPU 24% peak 39%".
    public var text: String {
        label + " " + value + (peak.map { " " + $0 } ?? "")
    }
}

import Foundation

/// Everything the Advanced screen shows, worked out the way the dashboard's renderAdv and
/// drawAdvChart do (public/index.html): same sums, same rounding, same words.
///
/// Build a new one whenever an input changes: the devices (live "now" figures; throttle with
/// `AdvancedRefresh.LiveThrottle`), the hub's totals (`GET /api/energy`, again every
/// `AdvancedRefresh.reloadInterval`), the price, the range, the unit, or the clock.
public struct AdvancedModel: Sendable, Equatable {
    /// One of the four figures at the top.
    public struct Tile: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case drawingNow, energyUsed, cost, perMonth
        }

        public let kind: Kind
        /// "Drawing now", "Energy used", "Cost", "Per month"
        public let label: String
        /// "1.81 kW"; "…" while the totals are loading.
        public let value: String
        /// "$13.76 a day at this rate"
        public let sub: String

        public var id: Kind { kind }
    }

    /// The line between the tiles and the chart: "Electricity price **$0.316/kWh** · Typical home
    /// rate for California." with a "Change…" button that opens the price editor.
    public struct PriceRow: Sendable, Hashable {
        public let label: String
        /// The emphasised part.
        public let value: String
        public let source: String
        public let changeLabel: String

        /// The whole line as plain text.
        public var text: String { "\(label) \(value) \u{B7} \(source)" }
    }

    public struct LegendItem: Sendable, Hashable, Identifiable {
        public let deviceID: String
        public let name: String
        public let color: AdvancedSeriesColor

        public var id: String { deviceID }
    }

    /// A device's row in the power table.
    public struct PowerRow: Sendable, Hashable, Identifiable {
        public let deviceID: String
        public let name: String
        public let color: AdvancedSeriesColor
        /// "285 W", or "offline" (shown muted) when the device is not reporting.
        public let now: String
        public let isOffline: Bool
        public let average: String
        public let peak: String
        public let energy: String
        public let cost: String
        /// "89%", or empty when the hub has no totals for the device.
        public let share: String
        /// The same share for a bar, 0–1.
        public let shareFraction: Double
        /// How the device's power is known: "CPU and GPU measured", "Estimated from load", "–".
        public let source: String
        /// The split behind the current reading, which the dashboard shows on hover: "CPU 40 W ·
        /// GPU 191 W · rest of system ~25 W · power supply losses ~29 W". Empty while offline.
        public let breakdown: String

        public var id: String { deviceID }
    }

    public struct PowerTable: Sendable, Hashable {
        public static let headers = ["Device", "Now", "Average", "Peak", "Energy", "Cost", "Share", "Power reading"]

        public let rows: [PowerRow]
        /// "All devices"
        public let totalLabel: String
        public let totalNow: String
        /// "…" while loading.
        public let totalEnergy: String
        public let totalCost: String
        /// "No power data yet." when there are no rows; then the table has no header or footer.
        public let emptyText: String?
    }

    /// Two figures the dashboard writes as "36% / 84%", the second one muted.
    public struct Pair: Sendable, Hashable {
        public let primary: String
        public let secondary: String

        public var text: String { "\(primary) / \(secondary)" }
    }

    /// A device's row in the usage table.
    public struct UsageRow: Sendable, Hashable, Identifiable {
        public let deviceID: String
        public let name: String
        public let color: AdvancedSeriesColor
        /// Time online, "47 h" or "7.5 h".
        public let online: String
        /// That time as a share of the range so far, "30%" (muted).
        public let onlineShare: String
        /// Average and peak.
        public let cpu: Pair
        public let gpu: Pair
        public let memory: String
        /// Peak CPU and GPU temperature, in the user's unit.
        public let peakTemperatures: Pair
        public let downloaded: String
        public let uploaded: String
        public let diskRead: String
        public let diskWritten: String

        public var id: String { deviceID }
    }

    public struct UsageTable: Sendable, Hashable {
        public static let headers = ["Device", "Online", "CPU avg / peak", "GPU avg / peak", "Memory avg", "Peak temp CPU / GPU", "Downloaded", "Uploaded", "Disk read", "Disk written"]

        public let rows: [UsageRow]
        /// "Loading…" before the first totals arrive, "No data for this time range yet." after.
        public let emptyText: String?
    }

    public static let title = "Advanced"
    public static let electricityHeading = "Electricity"
    public static let usageHeading = "Usage"
    /// The paragraph at the bottom of the screen (#advNote).
    public static let note = "Power is estimated \"at the wall\". NVIDIA GPU power is measured, and CPU power is measured where the device has a sensor (LibreHardwareMonitor on Windows, NVIDIA Grace or RAPL on Linux). Otherwise it's estimated from load. Motherboard, memory, drives, fans and power-supply losses are always estimated. Expect totals within about 20% of a plug-in power meter. Energy is only counted while the hub is running and the device is reporting."
    /// Stands in for a figure that is still loading.
    public static let loadingValue = "\u{2026}"

    public let range: AdvancedRange
    /// True until the hub's totals for this range have arrived.
    public let isLoading: Bool
    public let tiles: [Tile]
    public let price: PriceRow
    public let chartTitle: String
    /// The devices that used energy in the range.
    public let legend: [LegendItem]
    /// Nil while loading: the dashboard leaves the chart blank.
    public let chart: AdvancedChartModel?
    public let power: PowerTable
    public let usage: UsageTable

    /// - Parameters:
    ///   - devices: the hub's devices in the order the store keeps them (they are sorted by
    ///     `order` here, ties and missing orders keeping the store's order, as on the dashboard).
    ///   - energy: the answer to `GET /api/energy` for this range, nil while it is loading or after
    ///     the range changed.
    ///   - price: `EnergyPrice(saved:timeZone:locale:)` of the hub's saved price.
    ///   - now: the current time, ms since 1970.
    public init(
        devices: [Device], energy: EnergyResponse?, price: EnergyPrice, range: AdvancedRange, unit: TemperatureUnit,
        now: Double, locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        let rows = Self.rows(devices: devices, energy: energy)
        let labels = AdvancedLabels(range: range, locale: locale, timeZone: timeZone)
        let money = { (value: Double) in Format.money(value, price.currency, locale: locale) }
        let loaded = energy != nil
        let dataBounds = energy.flatMap { $0.bounds.count >= 2 ? $0.bounds : nil }
        let bounds = dataBounds ?? range.bounds(now: now, timeZone: timeZone)
        let end = min(now, bounds[bounds.count - 1])

        let nowW = rows.reduce(0.0) { $0 + Self.truthy($1.now?.watts) }
        let kwh = rows.reduce(0.0) { $0 + Self.truthy($1.summary?.wh) } / 1000
        // The hub prices each minute at the rate in force then; without a saved price, use the guessed flat rate.
        let devCost = { (s: UsageSummary) in s.cost ?? s.wh / 1000 * price.rate }
        let cost = rows.reduce(0.0) { $0 + ($1.summary.map(devCost) ?? 0) }
        let first = rows.reduce(Double.infinity) { min($0, $1.summary?.firstData ?? .infinity) }
        let since = max(bounds[0], first)
        let covered = first.isFinite ? end - since : 0
        let partial = first.isFinite && first > bounds[0] + (bounds[1] - bounds[0])
        let sinceLabel = partial ? "since " + labels.dateAndTime(first) : range.sinceLabel
        let monthKwh = covered >= 3600e3 ? kwh / covered * 30.44 * 86400e3 : nowW * 24 * 30.44 / 1000
        // What this usage pattern actually pays per kWh.
        let monthRate = covered >= 3600e3 && kwh > 0 ? cost / kwh : price.dayRate

        let costSub: String
        if price.isTimeOfUse {
            costSub = kwh > 0 ? "avg \(Format.fmtKwhPrice(cost / kwh, price.currency, locale: locale))/kWh with your time-of-use rates" : "with your time-of-use rates"
        } else {
            costSub = "at " + price.priceText(locale: locale)
        }
        let energyText = loaded ? Format.fmtKwh(kwh, locale: locale) : Self.loadingValue
        let costText = loaded ? money(cost) : Self.loadingValue

        self.range = range
        isLoading = !loaded
        tiles = [
            Tile(kind: .drawingNow, label: "Drawing now", value: Format.fmtW(nowW),
                 sub: "\(money(nowW / 1000 * 24 * price.dayRate)) a day at \(price.isTimeOfUse ? "your rates" : "this rate")"),
            Tile(kind: .energyUsed, label: "Energy used", value: energyText, sub: sinceLabel),
            Tile(kind: .cost, label: "Cost", value: costText, sub: costSub),
            Tile(kind: .perMonth, label: "Per month", value: loaded ? money(monthKwh * monthRate) : Self.loadingValue,
                 sub: "\u{2248} \(Format.fmtKwh(monthKwh, locale: locale)) \(covered >= 3600e3 ? "at the recent average" : "at the current draw")"),
        ]
        self.price = PriceRow(label: "Electricity price", value: price.priceText(locale: locale), source: price.source, changeLabel: "Change\u{2026}")

        // Power table
        let total = kwh * 1000 == 0 ? 1 : kwh * 1000
        let powerRows = rows.filter { ($0.summary?.minutes ?? 0) != 0 || $0.now != nil }.map { row in
            let s = row.summary, e = row.now
            let share = s.map { JS.round($0.wh / total * 100) }
            return PowerRow(
                deviceID: row.device.id, name: row.device.displayName, color: row.color,
                now: e.map { Format.fmtW($0.watts) } ?? "offline", isOffline: e == nil,
                average: Format.fmtW(s?.stats.power?.avg), peak: Format.fmtW(s?.stats.power?.peak),
                energy: s.map { Format.fmtKwh($0.wh / 1000, locale: locale) } ?? Format.dash, cost: s.map { money(devCost($0)) } ?? Format.dash,
                share: share.map { JS.string($0) + "%" } ?? "", shareFraction: share.map { max(0, min(1, $0 / 100)) } ?? 0,
                source: Self.powerSource(e ?? row.device.latest?.powerEst), breakdown: Self.powerBreakdown(e)
            )
        }
        power = PowerTable(
            rows: powerRows, totalLabel: "All devices", totalNow: Format.fmtW(nowW), totalEnergy: energyText, totalCost: costText,
            emptyText: powerRows.isEmpty ? "No power data yet." : nil
        )

        // Usage table
        let span = max(60e3, end - bounds[0])
        let usageRows = rows.compactMap { row -> UsageRow? in
            guard let s = row.summary, s.minutes != 0 else { return nil }
            let minutes = Double(s.minutes)
            let stat = { (value: Double?, format: (Double?) -> String) in value == nil ? Format.dash : format(value) }
            let temp = { (value: Double?) in Format.fmtTemp(value, unit) }
            return UsageRow(
                deviceID: row.device.id, name: row.device.displayName, color: row.color,
                online: Format.hours(minutes), onlineShare: JS.string(min(100, JS.round(minutes * 60e3 / span * 100))) + "%",
                cpu: Pair(primary: stat(s.stats.cpu?.avg, Format.fmtPct), secondary: stat(s.stats.cpu?.peak, Format.fmtPct)),
                gpu: Pair(primary: stat(s.stats.gpu?.avg, Format.fmtPct), secondary: stat(s.stats.gpu?.peak, Format.fmtPct)),
                memory: stat(s.stats.mem?.avg, Format.fmtPct),
                peakTemperatures: Pair(primary: stat(s.stats.cpuTemp?.peak, temp), secondary: stat(s.stats.gpuTemp?.peak, temp)),
                downloaded: Format.fmtBytes(s.bytes.rx), uploaded: Format.fmtBytes(s.bytes.tx),
                diskRead: Format.fmtBytes(s.bytes.dr), diskWritten: Format.fmtBytes(s.bytes.dw)
            )
        }
        usage = UsageTable(rows: usageRows, emptyText: usageRows.isEmpty ? (loaded ? "No data for this time range yet." : "Loading\u{2026}") : nil)

        // Chart
        chartTitle = range.chartTitle
        let chartRows = rows.filter { Self.truthy($0.summary?.wh) != 0 }
        legend = chartRows.map { LegendItem(deviceID: $0.device.id, name: $0.device.displayName, color: $0.color) }
        if let dataBounds {
            chart = Self.chart(rows: chartRows, bounds: dataBounds, price: price, now: now, labels: labels, money: money, locale: locale)
        } else {
            chart = nil
        }
    }

    // MARK: Rows

    private struct Row {
        let device: Device
        let summary: UsageSummary?
        let color: AdvancedSeriesColor
        /// The live estimate; nil while the device is offline.
        let now: PowerEstimate?
    }

    // function advRows
    private static func rows(devices: [Device], energy: EnergyResponse?) -> [Row] {
        let byID = Dictionary((energy?.devices ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        // Array.prototype.sort is stable: devices without an order keep the order they came in, last.
        let sorted = devices.enumerated().sorted { a, b in
            let x = a.element.order ?? 1_000_000_000, y = b.element.order ?? 1_000_000_000
            return x != y ? x < y : a.offset < b.offset
        }
        return sorted.enumerated().map { position, entry in
            let d = entry.element
            return Row(device: d, summary: byID[d.id], color: .color(at: position), now: d.online ? d.latest?.powerEst : nil)
        }
    }

    /// `x || 0`: missing, zero and NaN all count as nothing.
    private static func truthy(_ value: Double?) -> Double {
        guard let value, !value.isNaN else { return 0 }
        return value
    }

    // function powerSource
    static func powerSource(_ e: PowerEstimate?) -> String {
        guard let e else { return Format.dash }
        if e.cpuMeasured && e.gpuMeasured { return "CPU and GPU measured" }
        if e.gpuMeasured { return "GPU measured, CPU estimated" }
        return e.cpuMeasured ? "CPU measured, rest estimated" : "Estimated from load"
    }

    // const powerBreakdown = e => e ? `CPU ${Math.round(e.cpu)} W${e.cpuMeasured ? '' : ' (est.)'} · GPU … ` : '';
    static func powerBreakdown(_ e: PowerEstimate?) -> String {
        guard let e else { return "" }
        let watts = { (value: Double) in JS.string(JS.round(value)) }
        return "CPU \(watts(e.cpu)) W\(e.cpuMeasured ? "" : " (est.)") \u{B7} GPU \(watts(e.gpu)) W\(e.gpuEstimated ? " (est.)" : "")"
            + " \u{B7} rest of system ~\(JS.string(e.rest)) W \u{B7} power supply losses ~\(watts(e.losses)) W"
    }

    // MARK: Chart

    // function drawAdvChart, without the drawing.
    private static func chart(
        rows: [Row], bounds: [Double], price: EnergyPrice, now: Double, labels: AdvancedLabels,
        money: (Double) -> String, locale: Locale
    ) -> AdvancedChartModel {
        let n = bounds.count - 1
        // A summary with fewer buckets than the bounds counts as having used nothing there.
        let wh = { (row: Row, i: Int) -> Double in
            guard let buckets = row.summary?.buckets, i < buckets.count else { return 0 }
            return buckets[i]
        }
        let bucketCost = { (row: Row, i: Int) -> Double in
            if let costs = row.summary?.costBuckets, i < costs.count { return costs[i] }
            return wh(row, i) / 1000 * price.rate
        }
        let totals = (0..<n).map { i in rows.reduce(0.0) { $0 + wh($1, i) } / 1000 }
        let yMax = Format.niceMax(max(totals.max() ?? 0, 0.001) * 1.1)
        let buckets = (0..<n).map { i -> AdvancedChartModel.Bucket in
            let used = rows.filter { wh($0, i) > 0 }
            let long = labels.bucket(bounds[i], next: bounds[i + 1], long: true)
            let soFar = bounds[i + 1] > now
            let tooltip = AdvancedChartModel.Tooltip(
                title: long + (soFar ? " (so far)" : ""),
                rows: used.map { row in
                    AdvancedChartModel.TooltipRow(
                        deviceID: row.device.id, name: row.device.displayName, color: row.color,
                        energy: Format.fmtKwh(wh(row, i) / 1000, locale: locale), cost: money(bucketCost(row, i))
                    )
                },
                totalEnergy: Format.fmtKwh(totals[i], locale: locale),
                totalCost: money(rows.reduce(0.0) { $0 + bucketCost($1, i) })
            )
            return AdvancedChartModel.Bucket(
                index: i, start: bounds[i], end: bounds[i + 1],
                label: labels.bucket(bounds[i], next: bounds[i + 1], long: false), longLabel: long,
                segments: used.map { row in
                    let kWh = wh(row, i) / 1000
                    return AdvancedChartModel.Segment(deviceID: row.device.id, name: row.device.displayName, color: row.color, kWh: kWh, fraction: kWh / yMax)
                },
                totalKWh: totals[i], isSoFar: soFar, tooltip: tooltip
            )
        }
        let ticks = (0...4).map { i -> AdvancedChartModel.Tick in
            let value = yMax * Double(i) / 4
            // +(yMax * i / 4).toFixed(2) + ' kWh'
            let label = i % 2 == 0 ? JS.string(Double(JS.toFixed(value, 2)) ?? value) + " kWh" : nil
            return AdvancedChartModel.Tick(kWh: value, fraction: Double(i) / 4, label: label, isBaseline: i == 0)
        }
        return AdvancedChartModel(buckets: buckets, yMax: yMax, ticks: ticks)
    }
}

/// The dates and times of the Advanced screen. The fields are the ones the dashboard asks
/// `toLocaleString` for; how a locale arranges them is up to the system, as it is in a browser.
struct AdvancedLabels {
    let range: AdvancedRange
    let locale: Locale
    let timeZone: TimeZone

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: locale.calendar, timeZone: timeZone)
    }

    // new Date(t): fractions of a millisecond are dropped; anything beyond ±8.64e15 is invalid.
    private func date(_ t: Double) -> Date? {
        guard t.isFinite, abs(t) <= 8.64e15 else { return nil }
        return Date(timeIntervalSince1970: t.rounded(.towardZero) / 1000)
    }

    private func format(_ t: Double, _ style: Date.FormatStyle) -> String {
        date(t)?.formatted(style) ?? Format.invalidDate
    }

    // toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
    func dateAndTime(_ t: Double) -> String {
        format(t, style.month(.abbreviated).day(.defaultDigits).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    // function advBucketLabel
    func bucket(_ start: Double, next: Double, long: Bool) -> String {
        if range == .day {
            guard long else { return format(start, style.hour(.defaultDigits(amPM: .abbreviated))) }
            let time = style.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
            return "\(format(start, style.weekday(.abbreviated))) \(format(start, time))\u{2013}\(format(next, time))"
        }
        if long { return format(start, style.weekday(.wide).month(.abbreviated).day(.defaultDigits)) }
        return format(start, range == .week ? style.weekday(.abbreviated).day(.defaultDigits) : style.month(.abbreviated).day(.defaultDigits))
    }
}

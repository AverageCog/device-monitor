import Foundation
import Testing
@testable import DMCore

/// presentation/history/pages.json and ticks.json: the tiles, charts, time labels and tooltips of
/// the real history page (renderTiles, buildHvCharts, drawHvChart), read off its canvases.
@Suite struct HistoryPageFixtureTests {
    struct Pages: Decodable {
        struct Tile: Decodable, Equatable {
            let label: String
            let color: String
            let value: String
            let sub: String
        }

        struct AxisLabel: Decodable {
            let text: String
            let y: Double
        }

        struct TimeLabel: Decodable {
            let text: String
            let x: Double
            let align: String
        }

        struct GridLine: Decodable {
            let y: Double
            let baseline: Bool
        }

        struct Chart: Decodable {
            let title: String
            /// `[label, colour]` per series.
            let legend: [[String]]
            let yLabels: [AxisLabel]
            let bands: [String: [[CanvasPoint]]]
            let lines: [String: [[CanvasPoint]]]
        }

        struct Expected: Decodable {
            let tiles: [Tile]
            let empty: String?
            let xLabels: [TimeLabel]
            let grid: [GridLine]
            let charts: [Chart]
        }

        struct Hover: Decodable {
            struct Tip: Decodable {
                /// `[label, value, peak or null, colour]`.
                struct Row: Decodable {
                    let label: String
                    let value: String
                    let peak: String?
                    let color: String

                    init(from decoder: Decoder) throws {
                        var items = try decoder.unkeyedContainer()
                        label = try items.decode(String.self)
                        value = try items.decode(String.self)
                        peak = try items.decode(String?.self)
                        color = try items.decode(String.self)
                    }
                }

                let time: String
                let rows: [Row]
            }

            struct OnChart: Decodable {
                let tip: Tip?
                let crosshair: Double?
                let dots: [CanvasDot]
            }

            let t: Double
            /// nil when the dashboard drew no marker and no tooltip on any chart.
            let charts: [OnChart]?
        }

        struct Case: Decodable {
            let label: String
            let unit: String
            let width: Double
            let height: Double
            let from: Double
            let to: Double
            let resolution: Double
            let points: DashColumnarPoints
            let expected: Expected
            let hovers: [Hover]
        }

        struct Meta: Decodable {
            let pad: [String: Double]
        }

        let meta: Meta
        let cases: [Case]
    }

    struct Ticks: Decodable {
        struct Case: Decodable {
            let from: Double
            let to: Double
            let width: Double
            let labels: [Pages.TimeLabel]
        }

        let cases: [Case]
    }

    let pages: Pages
    private let enUS = DashFixture.enUS, zone = DashFixture.losAngeles

    init() throws {
        pages = try DashFixture.decode(Pages.self, "history/pages.json")
    }

    private func model(_ c: Pages.Case) throws -> HistoryModel {
        HistoryModel(points: try c.points.points(), resolution: c.resolution, from: c.from, to: c.to, unit: DashFixture.unit(c.unit))
    }

    private func layout(_ c: Pages.Case) -> HistoryChartLayout {
        HistoryChartLayout(width: c.width, height: c.height, from: c.from, to: c.to)
    }

    @Test func tiles() throws {
        var failures = [String]()
        var count = 0
        for c in pages.cases {
            let model = try model(c)
            let mine = model.tiles.map { Pages.Tile(label: $0.label, color: "var(\($0.tint.cssVariable))", value: $0.value, sub: $0.detail) }
            if mine != c.expected.tiles { failures.append("\(c.label):\n   app       \(mine.map { "\($0.label) \($0.value) (\($0.sub)) \($0.color)" })\n   dashboard \(c.expected.tiles.map { "\($0.label) \($0.value) (\($0.sub)) \($0.color)" })") }
            if Set(model.tiles.map(\.id)).count != model.tiles.count { failures.append("\(c.label): tile ids repeat") }
            count += mine.count
        }
        DashFixture.report(failures, of: pages.cases.count)
        #expect(count > 150)
    }

    @Test func chartsPresentAndTheirAxes() throws {
        var failures = [String]()
        var empty = 0, charts = 0
        for c in pages.cases {
            let model = try model(c), layout = layout(c)
            if model.emptyText != c.expected.empty { failures.append("\(c.label): empty text \(model.emptyText ?? "none"), dashboard \(c.expected.empty ?? "none")") }
            if c.expected.empty != nil { empty += 1 }
            if model.charts.map(\.title) != c.expected.charts.map(\.title) {
                failures.append("\(c.label): charts \(model.charts.map(\.title)), dashboard \(c.expected.charts.map(\.title))")
                continue
            }
            if Set(model.charts.map(\.id)).count != model.charts.count { failures.append("\(c.label): chart ids repeat") }
            for (chart, expected) in zip(model.charts, c.expected.charts) {
                charts += 1
                let name = "\(c.label), \(chart.title)"
                let legend = chart.series.map { [$0.label, "var(\($0.tint.cssVariable))"] }
                if legend != expected.legend { failures.append("\(name): legend \(legend), dashboard \(expected.legend)") }
                // Labels on every other line, at the pixel the line is snapped to.
                let labelled = chart.gridLevels.filter { $0.label != nil }
                let sameLabels = labelled.count == expected.yLabels.count && zip(labelled, expected.yLabels).allSatisfy {
                    $0.label == $1.text && DashFixture.near($1.y, DashFixture.snapped(layout.gridY($0.index))) && chart.axisLabel($0.value) == $1.text
                }
                if !sameLabels { failures.append("\(name): axis \(chart.gridLevels.map { $0.label ?? "-" }) up to \(chart.yMax), dashboard \(expected.yLabels.map(\.text))") }
                let sameGrid = chart.gridLevels.count == c.expected.grid.count && zip(chart.gridLevels, c.expected.grid).allSatisfy {
                    DashFixture.near($1.y, DashFixture.snapped(layout.gridY($0.index))) && $0.isBaseline == $1.baseline && $0.value == chart.yMax * Double($0.index) / 4
                }
                if !sameGrid || chart.gridLevels.map(\.index) != [0, 1, 2, 3, 4] { failures.append("\(name): grid lines differ") }
                if chart.kind == .utilization && chart.yMax != 100 { failures.append("\(name): utilization runs to \(chart.yMax)") }
            }
        }
        DashFixture.report(failures, of: pages.cases.count)
        #expect(empty >= 2 && charts > 150)
        #expect(HistoryModel.emptyText == "No history for this time range yet. Data is recorded while the device is online.")
    }

    @Test func linesAndPeakBands() throws {
        var failures = [String]()
        var lineRuns = 0, bandRuns = 0, withBands = 0, withoutBands = 0, converted = 0
        for c in pages.cases {
            let model = try model(c), layout = layout(c)
            guard model.charts.count == c.expected.charts.count else {
                failures.append("\(c.label): \(model.charts.count) charts, dashboard \(c.expected.charts.count)")
                continue
            }
            for (chart, expected) in zip(model.charts, c.expected.charts) {
                if Set(chart.series.map(\.tint.rawValue)) != Set(expected.lines.keys) {
                    failures.append("\(c.label), \(chart.title): lines for \(chart.series.map(\.label)), dashboard \(expected.lines.keys.sorted())")
                    continue
                }
                if chart.kind == .temperature && c.unit == "F" { converted += 1 }
                for series in chart.series {
                    let name = "\(c.label), \(chart.title) \(series.label)"
                    let lines = series.lines.map { $0.map { CanvasPoint(x: layout.x($0.t), y: layout.y($0.value, yMax: chart.yMax)) } }
                    let wanted = expected.lines[series.tint.rawValue] ?? []
                    if !CanvasPoint.same(lines, wanted) { failures.append("\(name): line runs of \(CanvasPoint.shape(lines)), dashboard \(CanvasPoint.shape(wanted)) (axis to \(chart.yMax))") }
                    lineRuns += lines.count

                    // seg.forEach(… y(p[k + 'Max'] ?? p[k])) forwards, then y(seg[i][k]) backwards, closed.
                    let bands = series.bands.map { run in
                        run.map { CanvasPoint(x: layout.x($0.t), y: layout.y($0.high, yMax: chart.yMax)) } + run.reversed().map { CanvasPoint(x: layout.x($0.t), y: layout.y($0.low, yMax: chart.yMax)) }
                    }
                    let wantedBands = expected.bands[series.tint.rawValue] ?? []
                    if !CanvasPoint.same(bands, wantedBands) { failures.append("\(name): band runs of \(CanvasPoint.shape(bands)), dashboard \(CanvasPoint.shape(wantedBands))") }
                    if series.bands.contains(where: { $0.count < 2 }) || series.lines.contains(where: \.isEmpty) { failures.append("\(name): a run too short to draw") }
                    bandRuns += bands.count
                    if bands.isEmpty { withoutBands += 1 } else { withBands += 1 }
                }
            }
        }
        DashFixture.report(failures, of: pages.cases.count)
        #expect(lineRuns > 400 && bandRuns > 60 && withBands > 40 && withoutBands > 150 && converted >= 8)
    }

    @Test func timeLabelsUnderEachPage() throws {
        var failures = [String]()
        for c in pages.cases where !c.expected.charts.isEmpty {
            let model = try model(c)
            if let problem = compare(model.timeTicks(chartWidth: c.width, locale: enUS, timeZone: zone), c.expected.xLabels, layout(c)) { failures.append("\(c.label): \(problem)") }
        }
        DashFixture.report(failures, of: pages.cases.count)
    }

    @Test func timeLabelsByWidthAndSpan() throws {
        let ticks = try DashFixture.decode(Ticks.self, "history/ticks.json")
        var failures = [String]()
        var counts = Set<Int>(), forms = Set<Int>()
        for c in ticks.cases {
            let model = HistoryModel(points: [], resolution: 60_000, from: c.from, to: c.to, unit: .celsius)
            let mine = model.timeTicks(chartWidth: c.width, locale: enUS, timeZone: zone)
            if let problem = compare(mine, c.labels, HistoryChartLayout(width: c.width, from: c.from, to: c.to)) { failures.append("\(c.to - c.from) ms on \(c.width): \(problem)") }
            if HistoryModel.timeDivisions(chartWidth: c.width) != c.labels.count - 1 { failures.append("\(c.width) wide: \(HistoryModel.timeDivisions(chartWidth: c.width)) divisions, dashboard \(c.labels.count - 1)") }
            counts.insert(c.labels.count)
            forms.insert(c.labels[0].text.split(separator: " ").count)
        }
        DashFixture.report(failures, of: ticks.cases.count)
        // Three to eight labels; a time alone, a day with a time, a day alone.
        #expect(counts == [3, 4, 5, 6, 7, 8] && forms == [2, 5, 3])
        #expect(HistoryModel.timeDivisions(chartWidth: 0) == 2 && HistoryModel.timeDivisions(chartWidth: .nan) == 2 && HistoryModel.timeDivisions(chartWidth: .infinity) == 7)
        #expect(HistoryModel(points: [], resolution: 60_000, from: 0, to: 3_600_000, unit: .celsius).timeTicks(divisions: 4, locale: enUS, timeZone: zone).map(\.t) == [0, 900_000, 1_800_000, 2_700_000, 3_600_000])
    }

    private func compare(_ ticks: [HistoryTimeTick], _ labels: [Pages.TimeLabel], _ layout: HistoryChartLayout) -> String? {
        let texts = ticks.map { DashFixture.fold($0.label) }
        if texts != labels.map(\.text) { return "labels \(texts), dashboard \(labels.map(\.text))" }
        // ctx.textAlign = i === 0 ? 'left' : i === nx ? 'right' : 'center'
        let alignments = ticks.map { $0.alignment == .leading ? "left" : $0.alignment == .trailing ? "right" : "center" }
        if alignments != labels.map(\.align) { return "alignment \(alignments)" }
        if !zip(ticks, labels).allSatisfy({ DashFixture.near(layout.x($0.t), $1.x) }) { return "positions \(ticks.map { layout.x($0.t) }), dashboard \(labels.map(\.x))" }
        return ticks.map(\.index) == Array(ticks.indices) ? nil : "indices"
    }

    @Test func tooltipsAndMarkers() throws {
        var failures = [String]()
        var total = 0, shown = 0, withPeak = 0, markerOnly = 0, titles = Set<String>()
        for c in pages.cases {
            let model = try model(c), layout = layout(c)
            for hover in c.hovers {
                total += 1
                let name = "\(c.label) at \(hover.t)"
                let tooltip = model.tooltip(at: hover.t, locale: enUS, timeZone: zone)
                guard let expected = hover.charts else {
                    // Nothing drawn: no point within reach, or no chart to draw on.
                    if let tooltip { failures.append("\(name): a tooltip at \(tooltip.t) where the dashboard shows none") }
                    continue
                }
                guard let tooltip, tooltip.charts.count == expected.count, tooltip.charts.map(\.kind) == model.charts.map(\.kind) else {
                    failures.append("\(name): no tooltip, or not one entry per chart")
                    continue
                }
                shown += 1
                for ((rows, wanted), chart) in zip(zip(tooltip.charts, expected), model.charts) {
                    let on = "\(name), \(chart.title)"
                    // The marker is on every chart, also on one that has nothing to say about the point.
                    if wanted.crosshair.map({ DashFixture.near($0, DashFixture.snapped(layout.x(tooltip.t))) }) != true { failures.append("\(on): marker at \(layout.x(tooltip.t)), dashboard \(String(describing: wanted.crosshair))") }
                    let dots = rows.rows.map { CanvasDot(color: $0.tint.cssVariable, at: CanvasPoint(x: layout.x(tooltip.t), y: layout.y($0.y, yMax: chart.yMax))) }
                    if !CanvasDot.same(dots, wanted.dots) { failures.append("\(on): dots \(dots), dashboard \(wanted.dots)") }
                    if tooltip.rows(for: chart.kind) != rows.rows { failures.append("\(on): rows(for:) disagrees") }
                    guard let tip = wanted.tip else {
                        if !rows.rows.isEmpty { failures.append("\(on): rows \(rows.rows.map(\.text)) where the dashboard shows no tooltip") }
                        markerOnly += 1
                        continue
                    }
                    if DashFixture.fold(tooltip.title) != tip.time { failures.append("\(on): title \"\(tooltip.title)\", dashboard \"\(tip.time)\"") }
                    titles.insert(String(tip.time.split(separator: "\u{B7}").dropFirst().joined()))
                    let same = rows.rows.count == tip.rows.count && zip(rows.rows, tip.rows).allSatisfy {
                        $0.label == $1.label && $0.value == $1.value && $0.peak == $1.peak && DashFixture.tint($1.color) == $0.tint
                    }
                    if !same { failures.append("\(on): rows \(rows.rows.map(\.text)), dashboard \(tip.rows.map { "\($0.label) \($0.value)" + ($0.peak.map { " " + $0 } ?? "") })") }
                    if tip.rows.contains(where: { $0.peak != nil }) { withPeak += 1 }
                }
            }
        }
        DashFixture.report(failures, of: total)
        #expect(shown > 250 && total - shown > 80 && withPeak > 250 && markerOnly >= 4)
        // Raw samples carry no note; averaged points say how wide they are.
        #expect(titles.isSuperset(of: ["", " 1 min avg", " 30 min avg", " 1 h avg", " 2 h avg", " 24 h avg"]))
    }

    @Test func theMarkerIsOnTheNearestPointWithinReach() throws {
        var checked = 0
        for c in pages.cases {
            let model = try model(c)
            #expect(model.gap == max(10_000, 3 * c.resolution) && model.tooltipReach == max(model.gap, (c.to - c.from) / 50))
            for hover in c.hovers {
                guard let tooltip = model.tooltip(at: hover.t, locale: enUS, timeZone: zone) else { continue }
                let nearest = try #require(model.nearestPoint(to: hover.t))
                #expect(nearest.t == tooltip.t && abs(nearest.t - hover.t) <= model.tooltipReach && tooltip.date == Date(hubTime: tooltip.t))
                checked += 1
            }
        }
        #expect(checked > 250)
        #expect(HistoryModel(points: [], resolution: 2000, from: 0, to: 1, unit: .celsius).nearestPoint(to: 0) == nil)
    }

    @Test func layoutIsTheDashboards() {
        #expect(pages.meta.pad == ["l": HistoryChartLayout.padding.left, "r": HistoryChartLayout.padding.right, "t": HistoryChartLayout.padding.top, "b": HistoryChartLayout.padding.bottom])
        #expect(pages.cases.allSatisfy { $0.height == HistoryChartLayout.height })
        for c in pages.cases.prefix(8) {
            let layout = layout(c)
            for x in [0, 58, 123.25, c.width] {
                #expect(abs(layout.x(layout.time(atX: x)) - x) < 1e-6)
            }
            #expect(layout.plotWidth == c.width - HistoryChartLayout.padding.left - HistoryChartLayout.padding.right)
            #expect(layout.plotHeight == c.height - HistoryChartLayout.padding.top - HistoryChartLayout.padding.bottom)
        }
    }

    @Test func aChartFormatsItsOwnValues() throws {
        // The tooltip rows and the axis labels checked above come from these two functions.
        var rows = 0
        for c in pages.cases {
            let model = try model(c)
            for chart in model.charts {
                for level in chart.gridLevels {
                    #expect(level.label == nil || level.label == chart.axisLabel(level.value))
                }
                #expect(chart.unit == model.unit && (chart.kind == .temperature || chart.displayValue(37.5) == 37.5))
                for point in model.points {
                    guard let tooltip = model.tooltip(at: point.t, locale: enUS, timeZone: zone), tooltip.t == point.t else { continue }
                    for row in tooltip.rows(for: chart.kind) {
                        guard let raw = model.nearestPoint(to: point.t)?.value(row.metric) else { continue }
                        #expect(row.value == chart.valueText(raw) && row.y == chart.displayValue(raw))
                        #expect(row.text == row.label + " " + row.value + (row.peak.map { " " + $0 } ?? ""))
                        rows += 1
                    }
                }
            }
        }
        #expect(rows > 1500)
    }
}

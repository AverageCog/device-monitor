import Foundation
import Testing
@testable import DMCore

/// presentation/dashboard/card-chart.json: what the real drawChart put on a card's canvas (lines,
/// labels, the hover marker) and in its tooltip, for captured and constructed series.
@Suite struct CardChartFixtureTests {
    struct Chart: Decodable {
        struct Option: Decodable {
            let id: String
            let label: String
            let selected: Bool
            let ms: Double
        }

        struct LegendItem: Decodable {
            let label: String
            let color: String
        }

        struct Meta: Decodable {
            let options: [Option]
            let legend: [LegendItem]
            let seriesRequests: [String]
            let refreshIntervals: [Double]
        }

        struct Stored: Decodable {
            let range: String?
            let cards: [String: String?]
            let `default`: String
            let resolved: [String: String]
        }

        struct Label: Decodable {
            let text: String
            let x: Double
            let y: Double
        }

        struct GridLine: Decodable {
            let y: Double
            let baseline: Bool
        }

        struct Tip: Decodable {
            struct Row: Decodable {
                let text: String
                let label: String
                let value: String
                let color: String
            }

            struct Content: Decodable {
                let time: String
                let rows: [Row]
            }

            /// Pointer position as a fraction of the canvas width.
            let hover: Double
            let tip: Content?
            let crosshair: Double?
            let dots: [CanvasDot]
        }

        struct Expected: Decodable {
            let labels: [Label]
            let grid: [GridLine]
            let lines: [String: [[CanvasPoint]]]
            let tips: [Tip]
        }

        struct Case: Decodable {
            let label: String
            let unit: String
            let range: String
            let now: Double
            let resolution: Double
            let width: Double
            let height: Double
            let points: DashColumnarPoints
            let expected: Expected
        }

        let meta: Meta
        let stored: [Stored]
        let cases: [Case]
    }

    let chart: Chart

    init() throws {
        chart = try DashFixture.decode(Chart.self, "dashboard/card-chart.json")
    }

    private func model(_ c: Chart.Case) throws -> CardChartModel {
        CardChartModel(points: try c.points.points(), range: try #require(CardChartRange(rawValue: c.range)), now: c.now, resolution: c.resolution)
    }

    @Test func rangeOptions() {
        let options = chart.meta.options
        #expect(CardChartRange.allCases.map(\.id) == options.map(\.id))
        #expect(CardChartRange.allCases.map(\.label) == options.map(\.label))
        #expect(CardChartRange.allCases.map(\.duration) == options.map(\.ms))
        #expect(options.filter(\.selected).map(\.id) == [CardChartRange.default.id])
        #expect(CardChartRange.allCases.map(\.isLive) == [true, false, false])
        // loadSeries: `/api/history/${id}?range=${want}&points=360`, again every two minutes.
        #expect(chart.meta.seriesRequests == CardChartRange.allCases.filter { !$0.isLive }.map { "/api/history/chart?range=\($0.id)&points=\(CardChartRange.historyPoints)" })
        #expect(chart.meta.refreshIntervals == [CardChartRange.reloadInterval])
        #expect(CardChartModel.legend.map(\.label) == chart.meta.legend.map(\.label))
        #expect(CardChartModel.legend.map(\.tint) == chart.meta.legend.map { DashFixture.tint($0.color) })
        #expect(CardChartModel.legend.map(\.metric) == [.cpu, .gpu, .mem])
    }

    @Test func aStoredRangeIsReadBackLikeTheDashboardDoes() {
        #expect(chart.stored.count >= 12)
        for row in chart.stored {
            #expect(CardChartRange.resolve(card: nil, dashboard: row.range).id == row.default, "stored range \(row.range ?? "none")")
            for (card, resolved) in row.resolved {
                let stored = row.cards[card] ?? nil
                #expect(CardChartRange.resolve(card: stored, dashboard: row.range).id == resolved, "card \(stored ?? "none"), dashboard-wide \(row.range ?? "none")")
            }
        }
        #expect(CardChartRange.resolve(card: nil) == .tenMinutes)
    }

    @Test func axis() throws {
        var failures = [String]()
        for c in chart.cases {
            let layout = CardChartLayout(width: c.width, height: c.height, model: try model(c))
            let levels = CardChartModel.axisLevels
            // ctx.fillText(v + '%', padL - 6, y(v)); the line sits at Math.round(y(v)) + 0.5.
            let labels = zip(levels, c.expected.labels).allSatisfy { $0.label == $1.text && $1.x == CardChartLayout.padding.left - 6 && DashFixture.near($1.y, layout.y($0.value)) }
            let lines = zip(levels, c.expected.grid).allSatisfy { DashFixture.near($1.y, DashFixture.snapped(layout.y($0.value))) && $0.isBaseline == $1.baseline }
            if levels.count != c.expected.labels.count || levels.count != c.expected.grid.count || !labels || !lines { failures.append("\(c.label): the axis differs") }
        }
        DashFixture.report(failures, of: chart.cases.count)
    }

    @Test func lines() throws {
        var failures = [String]()
        var joined = 0, broken = 0, withoutGPU = 0
        for c in chart.cases {
            let model = try model(c)
            let layout = CardChartLayout(width: c.width, height: c.height, model: model)
            if Set(model.series.map(\.metric.rawValue)) != Set(c.expected.lines.keys) {
                failures.append("\(c.label): draws \(model.series.map(\.metric.rawValue)), dashboard \(c.expected.lines.keys.sorted())")
                continue
            }
            if model.series.map(\.metric) != [HistoryPoint.Metric.cpu, .gpu, .mem].filter({ c.expected.lines[$0.rawValue] != nil }) { failures.append("\(c.label): series out of order") }
            if c.expected.lines["gpu"] == nil { withoutGPU += 1 }
            for series in model.series {
                let mine = series.segments.map { $0.map { CanvasPoint(x: layout.x($0.t), y: layout.y($0.value)) } }
                let wanted = c.expected.lines[series.metric.rawValue] ?? []
                if !CanvasPoint.same(mine, wanted) { failures.append("\(c.label), \(series.label): runs of \(CanvasPoint.shape(mine)), dashboard \(CanvasPoint.shape(wanted))") }
                if series.segments.contains(where: \.isEmpty) { failures.append("\(c.label), \(series.label): an empty run") }
                if series.label != CardChartModel.legend.first(where: { $0.metric == series.metric })?.label || series.tint != CardChartModel.legend.first(where: { $0.metric == series.metric })?.tint { failures.append("\(c.label), \(series.label): legend and series disagree") }
                joined += series.segments.filter { $0.count > 1 }.count
                broken += max(0, series.segments.count - 1)
            }
            if model.start != c.now - (CardChartRange(rawValue: c.range)?.duration ?? 0) || model.end != c.now || model.gap != max(10000, c.resolution * 3) { failures.append("\(c.label): window or gap") }
        }
        DashFixture.report(failures, of: chart.cases.count)
        #expect(joined > 60 && broken > 60 && withoutGPU >= 4)
    }

    @Test func tooltips() throws {
        var failures = [String]()
        var total = 0, shown = 0, relative = 0, clock = 0, withTemperature = 0
        for c in chart.cases {
            let model = try model(c)
            let layout = CardChartLayout(width: c.width, height: c.height, model: model)
            for tip in c.expected.tips {
                total += 1
                let name = "\(c.label) at \(tip.hover)"
                // refs.hover = (e.clientX - r.left) / r.width; … tH = tStart + ((hover * W - padL) / cw) * span
                let time = layout.time(atX: tip.hover * c.width)
                let tooltip = model.tooltip(at: time, unit: DashFixture.unit(c.unit), locale: DashFixture.enUS, timeZone: DashFixture.losAngeles)
                guard let expected = tip.tip else {
                    if tooltip != nil { failures.append("\(name): a tooltip where the dashboard shows none") }
                    if tip.crosshair != nil || !tip.dots.isEmpty { failures.append("\(name): the dashboard drew a marker without a tooltip") }
                    continue
                }
                guard let tooltip else {
                    failures.append("\(name): no tooltip, dashboard \"\(expected.time)\"")
                    continue
                }
                shown += 1
                if DashFixture.fold(tooltip.time) != expected.time { failures.append("\(name): time \"\(tooltip.time)\", dashboard \"\(expected.time)\"") }
                if expected.time.hasSuffix("ago") || expected.time == "now" { relative += 1 } else { clock += 1 }
                if tooltip.rows.map(\.text) != expected.rows.map(\.text) || tooltip.rows.map(\.label) != expected.rows.map(\.label) || tooltip.rows.map(\.valueText) != expected.rows.map(\.value) {
                    failures.append("\(name): rows \(tooltip.rows.map(\.text)), dashboard \(expected.rows.map(\.text))")
                }
                if tooltip.rows.map(\.tint) != expected.rows.map({ DashFixture.tint($0.color) }) { failures.append("\(name): row colours") }
                if tooltip.rows.contains(where: { $0.temperature != nil }) { withTemperature += 1 }
                // The marker: a vertical line snapped to a pixel at the sample's time, and a dot on each line.
                if tip.crosshair.map({ DashFixture.near($0, DashFixture.snapped(layout.x(tooltip.t))) }) != true { failures.append("\(name): marker at \(layout.x(tooltip.t)), dashboard \(String(describing: tip.crosshair))") }
                let dots = tooltip.rows.map { CanvasDot(color: $0.tint.cssVariable, at: CanvasPoint(x: layout.x(tooltip.t), y: layout.y($0.value))) }
                if !CanvasDot.same(dots, tip.dots) { failures.append("\(name): dots \(dots), dashboard \(tip.dots)") }
                if model.nearestSample(to: time)?.t != tooltip.t || tooltip.date != Date(hubTime: tooltip.t) { failures.append("\(name): nearestSample and tooltip disagree") }
            }
        }
        DashFixture.report(failures, of: total)
        #expect(shown > 500 && total - shown >= 15 && relative > 300 && clock > 100 && withTemperature > 400)
    }

    @Test func positionsAndTimesConvertBothWays() {
        for c in chart.cases.prefix(8) {
            let layout = CardChartLayout(width: c.width, height: c.height, start: c.now - 600_000, end: c.now)
            for x in [0, 30, 100.5, c.width] {
                #expect(abs(layout.x(layout.time(atX: x)) - x) < 1e-6)
            }
            #expect(layout.plotWidth == c.width - CardChartLayout.padding.left - CardChartLayout.padding.right)
            #expect(layout.plotHeight == c.height - CardChartLayout.padding.top - CardChartLayout.padding.bottom)
        }
        #expect(chart.cases.allSatisfy { $0.height == CardChartLayout.height })
    }

    @Test func aTooltipRowIsItsParts() throws {
        // "CPU 28% \u{B7} 59\u{B0}C": label, reading and, where the sample has one, the temperature.
        var rows = 0
        for c in chart.cases {
            let model = try model(c)
            let layout = CardChartLayout(width: c.width, height: c.height, model: model)
            for tip in c.expected.tips {
                guard let expected = tip.tip, let tooltip = model.tooltip(at: layout.time(atX: tip.hover * c.width), unit: DashFixture.unit(c.unit), locale: DashFixture.enUS, timeZone: DashFixture.losAngeles) else { continue }
                for (row, wanted) in zip(tooltip.rows, expected.rows) {
                    let parts = wanted.text.components(separatedBy: " \u{B7} ")
                    #expect(parts.first == row.label + " " + row.valueText && (parts.count > 1 ? parts[1] : nil) == row.temperature)
                    rows += 1
                }
            }
        }
        #expect(rows > 1000)
    }
}

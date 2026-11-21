import Foundation
import Testing
@testable import DMCore

/// AdvancedModel against render.json: every scenario's tiles, price line, tables, chart, tooltips
/// and pointer hits must be what the dashboard put on its page for the same inputs.
@Suite struct AdvancedModelTests {
    private typealias F = AdvancedFixtures

    private func model(_ scenario: F.Scenario, in file: F.Render) throws -> AdvancedModel {
        let zone = try #require(TimeZone(identifier: scenario.tz), "\(scenario.tz)")
        let unit = try #require(TemperatureUnit(rawValue: scenario.unit))
        let price = EnergyPrice(saved: scenario.saved, guessedRegion: PriceRegions.guess(timeZoneIdentifier: scenario.tz, languageTag: scenario.language))
        return AdvancedModel(
            devices: try scenario.devices(in: file), energy: try scenario.energy(in: file), price: price,
            range: AdvancedRange(stored: scenario.range), unit: unit, now: scenario.now, locale: F.enUS, timeZone: zone
        )
    }

    /// Runs `body` for every scenario and reports what it collected, so one bad scenario does not
    /// hide the others.
    private func forEachScenario(
        sourceLocation: SourceLocation = #_sourceLocation, _ body: (F.Scenario, AdvancedModel, F.Page, inout [String]) throws -> Void
    ) throws {
        let file = try F.render()
        #expect(file.scenarios.count >= 55, sourceLocation: sourceLocation)
        var failures: [String] = []
        for scenario in file.scenarios {
            var found: [String] = []
            try body(scenario, try model(scenario, in: file), file.page, &found)
            failures += found.map { "[\(scenario.name)] \($0)" }
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(25).joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    private func check(_ what: String, _ ours: String, _ theirs: String, date: Bool = false, reordered: Bool = false, into failures: inout [String]) {
        let ok = date ? F.sameDate(ours, theirs, reordered: reordered) : F.same(ours, theirs)
        if !ok { failures.append("\(what): ours \"\(ours)\", dashboard \"\(theirs)\"") }
    }

    private func hex(_ color: AdvancedSeriesColor) -> String {
        "#" + JS.padStart(String(color.hex, radix: 16), 6, "0")
    }

    // MARK: Tiles and the price line

    @Test func tiles() throws {
        var partial = 0, loading = 0
        try forEachScenario { scenario, model, _, failures in
            let expected = scenario.out.tiles
            guard model.tiles.count == 4, expected.count == 4 else {
                failures.append("\(model.tiles.count) tiles")
                return
            }
            #expect(model.tiles.map(\.kind) == AdvancedModel.Tile.Kind.allCases)
            for (tile, theirs) in zip(model.tiles, expected) {
                check("\(theirs[0]) label", tile.label, theirs[0], into: &failures)
                check("\(theirs[0]) value", tile.value, theirs[1], into: &failures)
                check("\(theirs[0]) sub", tile.sub, theirs[2], date: tile.kind == .energyUsed, into: &failures)
            }
            if expected[1][2].hasPrefix("since ") { partial += 1 }
            if expected[1][1] == "…" { loading += 1 }
            #expect(model.isLoading == (scenario.energy == nil))
            #expect(scenario.out.rangeOn == [model.range.rawValue])
        }
        #expect(partial >= 10 && loading >= 10)
    }

    @Test func priceLine() throws {
        try forEachScenario { scenario, model, _, failures in
            let expected = scenario.out.price
            check("price label", model.price.label, expected.label, into: &failures)
            check("price value", model.price.value, expected.value, into: &failures)
            check("price source", model.price.source, expected.source, into: &failures)
            check("price button", model.price.changeLabel, expected.button, into: &failures)
            check("price line", model.price.text, expected.text, into: &failures)
        }
    }

    // MARK: Tables

    @Test func powerTable() throws {
        var rows = 0, offline = 0, empty = 0
        try forEachScenario { scenario, model, _, failures in
            let expected = scenario.out.power
            guard let theirs = expected.rows else {
                empty += 1
                check("empty power table", model.power.emptyText ?? "nil", expected.empty ?? "nil", into: &failures)
                if !model.power.rows.isEmpty { failures.append("power rows where the dashboard has none") }
                return
            }
            if model.power.emptyText != nil { failures.append("power table is empty, the dashboard's is not") }
            if AdvancedModel.PowerTable.headers != expected.head { failures.append("power headers \(AdvancedModel.PowerTable.headers)") }
            let foot = [model.power.totalLabel, model.power.totalNow, "", "", model.power.totalEnergy, model.power.totalCost, "", ""]
            for (index, (ours, wanted)) in zip(foot, expected.foot ?? []).enumerated() { check("power footer cell \(index)", ours, wanted, into: &failures) }
            guard model.power.rows.count == theirs.count else {
                failures.append("\(model.power.rows.count) power rows (\(model.power.rows.map(\.name))), the dashboard has \(theirs.count) (\(theirs.map(\.name)))")
                return
            }
            for (row, wanted) in zip(model.power.rows, theirs) {
                rows += 1
                let at = "power row \(wanted.name)"
                check("\(at) name", row.name, wanted.name, into: &failures)
                check("\(at) colour", row.color.token, wanted.color, into: &failures)
                check("\(at) now", row.now, wanted.now, into: &failures)
                if row.isOffline != wanted.nowMuted { failures.append("\(at): offline \(row.isOffline)") }
                if row.isOffline { offline += 1 }
                // The hover text sits on the "now" cell only while there is a reading, and on the source cell always.
                check("\(at) breakdown", row.breakdown, wanted.sourceTitle, into: &failures)
                if let title = wanted.nowTitle { check("\(at) now title", row.breakdown, title, into: &failures) } else if !row.isOffline { failures.append("\(at): a live row without a title") }
                check("\(at) average", row.average, wanted.average, into: &failures)
                check("\(at) peak", row.peak, wanted.peak, into: &failures)
                check("\(at) energy", row.energy, wanted.energy, into: &failures)
                check("\(at) cost", row.cost, wanted.cost, into: &failures)
                check("\(at) share", row.share, wanted.share, into: &failures)
                if row.shareFraction != wanted.shareWidth / 100 { failures.append("\(at): share bar \(row.shareFraction), the dashboard's is \(wanted.shareWidth)%") }
                check("\(at) source", row.source, wanted.source, into: &failures)
            }
        }
        #expect(rows > 150 && offline > 15 && empty >= 3)
    }

    @Test func usageTable() throws {
        var rows = 0, emptyTexts = Set<String>()
        try forEachScenario { scenario, model, _, failures in
            let expected = scenario.out.usage
            guard let theirs = expected.rows else {
                emptyTexts.insert(expected.empty ?? "")
                check("empty usage table", model.usage.emptyText ?? "nil", expected.empty ?? "nil", into: &failures)
                if !model.usage.rows.isEmpty { failures.append("usage rows where the dashboard has none") }
                return
            }
            if model.usage.emptyText != nil { failures.append("usage table is empty, the dashboard's is not") }
            if AdvancedModel.UsageTable.headers != expected.head { failures.append("usage headers \(AdvancedModel.UsageTable.headers)") }
            guard model.usage.rows.count == theirs.count else {
                failures.append("\(model.usage.rows.count) usage rows, the dashboard has \(theirs.count)")
                return
            }
            for (row, wanted) in zip(model.usage.rows, theirs) {
                rows += 1
                let at = "usage row \(wanted.name)"
                check("\(at) name", row.name, wanted.name, into: &failures)
                check("\(at) colour", row.color.token, wanted.color, into: &failures)
                check("\(at) online", row.online, wanted.online[0], into: &failures)
                check("\(at) online share", row.onlineShare, wanted.online[1], into: &failures)
                check("\(at) cpu", row.cpu.primary, wanted.cpu[0], into: &failures)
                check("\(at) cpu peak", "/ " + row.cpu.secondary, wanted.cpu[1], into: &failures)
                check("\(at) gpu", row.gpu.primary, wanted.gpu[0], into: &failures)
                check("\(at) gpu peak", "/ " + row.gpu.secondary, wanted.gpu[1], into: &failures)
                check("\(at) memory", row.memory, wanted.memory, into: &failures)
                check("\(at) cpu temp", row.peakTemperatures.primary, wanted.temps[0], into: &failures)
                check("\(at) gpu temp", "/ " + row.peakTemperatures.secondary, wanted.temps[1], into: &failures)
                check("\(at) downloaded", row.downloaded, wanted.downloaded, into: &failures)
                check("\(at) uploaded", row.uploaded, wanted.uploaded, into: &failures)
                check("\(at) disk read", row.diskRead, wanted.diskRead, into: &failures)
                check("\(at) disk written", row.diskWritten, wanted.diskWritten, into: &failures)
                #expect(row.cpu.text == "\(row.cpu.primary) / \(row.cpu.secondary)")
            }
        }
        #expect(rows > 150)
        #expect(emptyTexts == ["Loading…", "No data for this time range yet."])
    }

    // MARK: Chart

    @Test func chartTitleAndLegend() throws {
        try forEachScenario { scenario, model, _, failures in
            check("chart title", model.chartTitle, scenario.out.chartTitle, into: &failures)
            if model.legend.map({ [$0.color.token, $0.name] }) != scenario.out.legend { failures.append("legend \(model.legend.map { [$0.color.token, $0.name] }), dashboard \(scenario.out.legend)") }
            if (model.chart == nil) != (scenario.out.chart == nil) { failures.append("chart is \(model.chart == nil ? "missing" : "there"), unlike on the dashboard") }
        }
    }

    @Test func chartBarsAxisAndLabels() throws {
        var charts = 0, segments = 0
        try forEachScenario { scenario, model, _, failures in
            guard let expected = scenario.out.chart, let chart = model.chart else { return }
            charts += 1
            for width in expected.widths {
                let at = "at width \(JS.string(width.W))"
                if abs(chart.slotWidth(canvasWidth: width.W) - width.slot) > 1e-9 { failures.append("\(at): slot \(chart.slotWidth(canvasWidth: width.W)), dashboard \(width.slot)") }
                if let bar = width.barWidth, abs(chart.barWidth(canvasWidth: width.W) - bar) > 1e-9 { failures.append("\(at): bar width \(chart.barWidth(canvasWidth: width.W)), dashboard \(bar)") }
                // y axis: a label on every second grid line.
                let labelled = chart.ticks.filter { $0.label != nil }
                if labelled.map({ $0.label ?? "" }) != width.yLabels.map(\.text) { failures.append("\(at): y labels \(labelled.map { $0.label ?? "" }), dashboard \(width.yLabels.map(\.text))") }
                for (tick, wanted) in zip(labelled, width.yLabels) where abs(tick.fraction - wanted.fraction) > 0.003 {   // the dashboard snaps grid lines to whole pixels
                    failures.append("\(at): y label \(wanted.text) at \(tick.fraction), dashboard \(wanted.fraction)")
                }
                // x axis: which buckets carry a label, and what it says.
                let ours = chart.buckets.filter { chart.showsLabel(at: $0.index, canvasWidth: width.W) }
                if ours.map(\.index) != width.xLabels.map(\.index) {
                    failures.append("\(at): x labels on \(ours.map(\.index)), dashboard on \(width.xLabels.map(\.index))")
                } else {
                    for (bucket, wanted) in zip(ours, width.xLabels) { check("\(at) x label \(wanted.index)", bucket.label, wanted.text, date: true, reordered: model.range == .week, into: &failures) }
                }
                guard let bars = width.bars else { continue }
                guard bars.count == chart.buckets.count else {
                    failures.append("\(chart.buckets.count) buckets, dashboard \(bars.count)")
                    continue
                }
                for (bucket, wanted) in zip(chart.buckets, bars) {
                    if bucket.segments.map({ hex($0.color) }) != wanted.map(\.fill) {
                        failures.append("bucket \(bucket.index): segments \(bucket.segments.map { hex($0.color) }), dashboard \(wanted.map(\.fill))")
                        continue
                    }
                    for (segment, bar) in zip(bucket.segments, wanted) {
                        segments += 1
                        if abs(segment.fraction - bar.fraction) > 1e-9 { failures.append("bucket \(bucket.index) \(segment.name): height \(segment.fraction), dashboard \(bar.fraction)") }
                        if abs(segment.kWh / chart.yMax - segment.fraction) > 1e-15 { failures.append("bucket \(bucket.index) \(segment.name): fraction is not kWh / yMax") }
                    }
                    if abs(bucket.segments.reduce(0) { $0 + $1.kWh } - bucket.totalKWh) > 1e-9 { failures.append("bucket \(bucket.index): segments do not add up to the total") }
                }
            }
            #expect(chart.ticks.count == 5)
            #expect(chart.ticks.map(\.fraction) == [0, 0.25, 0.5, 0.75, 1])
            #expect(chart.ticks.map(\.isBaseline) == [true, false, false, false, false])
            #expect(chart.ticks.last?.kWh == chart.yMax)
        }
        #expect(charts >= 40 && segments > 500)
    }

    @Test func tooltips() throws {
        var tips = 0, soFar = 0
        try forEachScenario { scenario, model, page, failures in
            guard let expected = scenario.out.chart, let chart = model.chart else { return }
            guard chart.buckets.count == expected.tips.count else {
                failures.append("\(chart.buckets.count) buckets, \(expected.tips.count) tooltips")
                return
            }
            let width = expected.widths[0].W
            for (bucket, wanted) in zip(chart.buckets, expected.tips) {
                tips += 1
                let at = "tooltip \(bucket.index)"
                check("\(at) title", bucket.tooltip.title, wanted.title, date: true, into: &failures)
                check("\(at) short label", bucket.label, wanted.short, date: true, reordered: model.range == .week, into: &failures)
                if bucket.isSoFar != wanted.title.hasSuffix(" (so far)") { failures.append("\(at): so far \(bucket.isSoFar)") }
                if bucket.isSoFar { soFar += 1 }
                #expect(bucket.tooltip.title == bucket.longLabel + (bucket.isSoFar ? " (so far)" : ""))
                let ours = bucket.tooltip.rows.map { [$0.color.token, $0.name, $0.energy, $0.cost] }
                    + [["transparent", AdvancedChartModel.Tooltip.totalLabel, bucket.tooltip.totalEnergy, bucket.tooltip.totalCost]]
                if ours.count != wanted.rows.count {
                    failures.append("\(at): rows \(ours), dashboard \(wanted.rows)")
                } else {
                    for (mine, theirs) in zip(ours, wanted.rows) {
                        for (a, b) in zip(mine, theirs) where !F.same(a, b) { failures.append("\(at): row \(mine), dashboard \(theirs)") }
                    }
                }
                if abs(chart.tooltipLeft(at: bucket.index, canvasWidth: width, tooltipWidth: page.tipWidth) - wanted.left) > 1e-9 { failures.append("\(at): left edge") }
                #expect(bucket.tooltip.rows.map(\.deviceID) == bucket.segments.map(\.deviceID))
                #expect(bucket.spokenSummary == "\(bucket.tooltip.title): \(bucket.tooltip.totalEnergy), \(bucket.tooltip.totalCost)")
            }
        }
        #expect(tips > 500 && soFar >= 35)
    }

    @Test func pointerFindsTheBucketTheDashboardFinds() throws {
        var points = 0
        try forEachScenario { scenario, model, _, failures in
            guard let expected = scenario.out.chart, let chart = model.chart else { return }
            for hover in expected.hover {
                for point in hover.points {
                    points += 1
                    let ours = chart.bucketIndex(atX: point.x, canvasWidth: hover.W)
                    if ours != point.index { failures.append("x \(point.x) of \(hover.W): bucket \(ours.map(String.init) ?? "none"), dashboard \(point.index.map(String.init) ?? "none")") }
                }
            }
        }
        #expect(points > 1000)
    }

    // MARK: Fixed parts of the page

    @Test func fixedWordingAndColours() throws {
        let page = try F.page()
        #expect(AdvancedModel.note == page.note)
        #expect(AdvancedModel.title == page.title)
        #expect(AdvancedModel.electricityHeading == page.electricity)
        #expect(AdvancedModel.usageHeading == page.usage)
        #expect(AdvancedSeriesColor.cycle.map { [$0.token, hex($0)] } == page.colors)
        #expect(AdvancedSeriesColor.cycle.map(\.index) == Array(0..<8))
        #expect(AdvancedSeriesColor.color(at: 8) == AdvancedSeriesColor.color(at: 0))
        #expect(AdvancedSeriesColor.color(at: 13).token == "--serious")
        #expect(AdvancedChartModel.Layout.left == page.layout.left && AdvancedChartModel.Layout.right == page.layout.right)
        #expect(AdvancedChartModel.Layout.top == page.layout.top && AdvancedChartModel.Layout.bottom == page.layout.bottom)
        #expect(AdvancedChartModel.Layout.dimmedOpacity == page.dimmedAlpha)
        #expect(AdvancedRefresh.reloadInterval * 1000 == page.reloadMs)
        #expect(AdvancedRefresh.liveInterval * 1000 == page.liveMs)
    }

    @Test func boundsWhileLoadingAreTheDashboards() throws {
        let file = try F.render()
        var checked = 0
        for scenario in file.scenarios {
            guard let bounds = scenario.bounds else { continue }
            let zone = try #require(TimeZone(identifier: scenario.tz))
            #expect(AdvancedRange(stored: scenario.range).bounds(now: scenario.now, timeZone: zone) == bounds, "\(scenario.name)")
            checked += 1
        }
        #expect(checked >= 10)
    }

    // MARK: Beyond the recorded scenarios

    @Test func devicesAreOrderedAndColouredAsOnTheDashboard() throws {
        let file = try F.render()
        let scenario = try #require(file.scenarios.first { $0.name == "devices listed out of order" })
        let model = try model(scenario, in: file)
        #expect(model.power.rows.map(\.name) == ["Zero", "One", "Two", "Two again", "No order A", "No order B"])
        #expect(model.power.rows.map(\.color.index) == [0, 1, 2, 3, 4, 5])
    }

    @Test func aSummaryShorterThanTheBoundsCountsAsNothing() throws {
        let bounds = (0...3).map { 1_795_000_000_000 + Double($0) * 3_600_000 }
        let device = Device(id: "a", name: "A", order: 0, online: true)
        let energy = EnergyResponse(bounds: bounds, devices: [UsageSummary(id: "a", wh: 500, buckets: [200, 300], minutes: 90)])
        let model = AdvancedModel(
            devices: [device], energy: energy, price: EnergyPrice(region: "US", currency: "USD", rate: 0.2), range: .day, unit: .celsius,
            now: bounds[3] + 1, locale: F.enUS, timeZone: try #require(TimeZone(identifier: "UTC"))
        )
        let chart = try #require(model.chart)
        #expect(chart.buckets.map(\.totalKWh) == [0.2, 0.3, 0])
        #expect(chart.buckets[2].segments.isEmpty)
        #expect(chart.buckets.allSatisfy { !$0.isSoFar })
        #expect(F.same(chart.buckets[1].tooltip.totalCost, "$0.06"))
    }

    @Test func modelIsAValue() throws {
        let file = try F.render()
        let scenario = try #require(file.scenarios.first)
        #expect(try model(scenario, in: file) == (try model(scenario, in: file)))
    }
}

import Foundation
import Testing
@testable import DMCore

/// Every row of formatting-vectors.json: the Swift port must print what the dashboard's JavaScript
/// printed for the same input.
@Suite struct FormatVectorTests {
    private static let loaded = Result { try FormatVectors.load() }
    private static let enUS = Locale(identifier: "en_US")

    /// The functions this suite checks; `everyRecordedFunctionIsChecked` keeps it honest.
    private static let checked: Set<String> = [
        "Math.round", "String", "toFixed", "toLocaleString", "padStart", "trim",
        "fmtPct", "fmtBytes", "fmtRate", "memPair", "fmtTemp", "toF", "fmtUptime", "ago", "tempStatus",
        "shortCpu", "shortGpu", "niceMax", "fmtW", "fmtKwh", "fmtHour", "hours", "resSuffix",
        "money", "fmtKwhPrice", "clock", "timeLabel", "tooltipTime", "cardTooltipTime",
    ]

    private func rows(_ name: String) throws -> [FormatVectors.Row] {
        let rows = try #require(try Self.loaded.get().cases[name], "No vectors recorded for \(name)")
        #expect(!rows.isEmpty)
        return rows
    }

    private func describe(_ name: String, _ row: FormatVectors.Row) -> String {
        "\(name)(\(row.args.map(\.description).joined(separator: ", ")))" + (row.extra.map { " [\($0)]" } ?? "")
    }

    private func report(_ name: String, _ failures: [String], of total: Int, sourceLocation: SourceLocation) {
        #expect(failures.isEmpty, "\(failures.count) of \(total) rows differ:\n\(failures.prefix(15).joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    /// Compares text results. `foldingSpaces` is only for the rows whose text comes from ICU.
    private func check(
        _ name: String, foldingSpaces: Bool = false, sourceLocation: SourceLocation = #_sourceLocation,
        _ format: (FormatVectors.Row) throws -> String?
    ) throws {
        let rows = try rows(name)
        var failures: [String] = []
        for row in rows {
            let expected = row.out.text
            let actual = try format(row)
            let same = foldingSpaces ? expected.map(FormatVectors.foldSpaces) == actual.map(FormatVectors.foldSpaces) : expected == actual
            if !same { failures.append("\(describe(name, row)) gives \(actual.map { "\"\($0)\"" } ?? "nil"), JavaScript gives \(row.out)") }
        }
        report(name, failures, of: rows.count, sourceLocation: sourceLocation)
    }

    /// Compares numeric results bit for bit (any NaN equals any NaN).
    private func checkNumber(
        _ name: String, sourceLocation: SourceLocation = #_sourceLocation, _ compute: (FormatVectors.Row) throws -> Double
    ) throws {
        let rows = try rows(name)
        var failures: [String] = []
        for row in rows {
            guard case .bits(let bits, let text) = row.out else {
                failures.append("\(describe(name, row)) has no numeric result")
                continue
            }
            let expected = Double(bitPattern: bits), actual = try compute(row)
            if !(actual.bitPattern == bits || (actual.isNaN && expected.isNaN)) {
                failures.append("\(describe(name, row)) gives \(JS.string(actual)) (\(String(actual.bitPattern, radix: 16))), JavaScript gives \(text) (\(String(bits, radix: 16)))")
            }
        }
        report(name, failures, of: rows.count, sourceLocation: sourceLocation)
    }

    private func unit(_ row: FormatVectors.Row, _ index: Int) throws -> TemperatureUnit {
        let raw = try #require(row.text(index))
        return try #require(TemperatureUnit(rawValue: raw))
    }

    private func zone(_ row: FormatVectors.Row) throws -> TimeZone {
        let identifier = try #require(row.extra)
        return try #require(TimeZone(identifier: identifier))
    }

    // MARK: The file itself

    @Test func everyRecordedFunctionIsChecked() throws {
        let vectors = try Self.loaded.get()
        #expect(Set(vectors.cases.keys) == Self.checked)
        #expect(vectors.locale == "en-US")
        #expect(vectors.cases.values.map(\.count).reduce(0, +) > 7000)
    }

    @Test func numbersInTheFileAreReadExactly() throws {
        // The vectors are only as good as the JSON parser: every number must come out as the very
        // double Node had.
        let doubles = try Self.loaded.get().doubles
        #expect(doubles.count > 1000)
        let wrong = doubles.filter { $0.value.bitPattern != $0.bits }
        #expect(wrong.isEmpty, "\(wrong.prefix(10).map { JS.string($0.value) })")
    }

    // MARK: JavaScript primitives

    @Test func mathRound() throws {
        try checkNumber("Math.round") { JS.round(try #require($0.number(0))) }
    }

    @Test func numberToString() throws {
        try check("String") { JS.string(try #require($0.number(0))) }
    }

    @Test func toFixed() throws {
        try check("toFixed") { JS.toFixed(try #require($0.number(0)), Int(try #require($0.number(1)))) }
    }

    @Test func toLocaleString() throws {
        try check("toLocaleString", foldingSpaces: true) { JS.toLocaleString(try #require($0.number(0)), locale: Self.enUS) }
    }

    @Test func padStartAndTrim() throws {
        try check("padStart") { JS.padStart(try #require($0.text(0)), Int(try #require($0.number(1))), try #require($0.text(2))) }
        try check("trim") { JS.trim(try #require($0.text(0))) }
    }

    // MARK: Numbers, sizes, temperatures

    @Test func fmtPct() throws {
        try check("fmtPct") { Format.fmtPct($0.number(0)) }
    }

    @Test func fmtBytes() throws {
        try check("fmtBytes") { row in
            guard row.args.count > 1 else { return Format.fmtBytes(row.number(0)) }
            return Format.fmtBytes(row.number(0), Int(try #require(row.number(1))))
        }
    }

    @Test func fmtRate() throws {
        try check("fmtRate") { Format.fmtRate($0.number(0)) }
    }

    @Test func memPair() throws {
        try check("memPair") { Format.memPair($0.number(0), $0.number(1)) }
    }

    @Test func fmtTemp() throws {
        try check("fmtTemp") { Format.fmtTemp($0.number(0), try unit($0, 1)) }
    }

    @Test func toF() throws {
        try checkNumber("toF") { Format.toF(try #require($0.number(0)), try unit($0, 1)) }
    }

    @Test func tempStatus() throws {
        try check("tempStatus") { Format.tempStatus($0.number(0))?.label }
        // The colour the dashboard pairs with each status (tempStatus in public/index.html).
        let colours: [Format.TempStatus: String] = [.normal: "var(--good)", .warm: "var(--warning)", .hot: "var(--critical)"]
        for row in try rows("tempStatus") {
            #expect(Format.tempStatus(row.number(0)).flatMap { colours[$0] } == row.extra)
        }
    }

    // MARK: Durations

    @Test func fmtUptime() throws {
        try check("fmtUptime") { Format.fmtUptime($0.number(0)) }
    }

    @Test func ago() throws {
        try check("ago") { Format.ago($0.number(0), now: try #require($0.number(1))) }
    }

    @Test func hours() throws {
        try check("hours") { Format.hours(try #require($0.number(0))) }
    }

    // MARK: Hardware names

    @Test func shortCpu() throws {
        try check("shortCpu") { Format.shortCpu($0.text(0)) }
    }

    @Test func shortGpu() throws {
        try check("shortGpu") { Format.shortGpu($0.text(0)) }
    }

    // MARK: Power, energy, money

    @Test func fmtW() throws {
        try check("fmtW") { Format.fmtW($0.number(0)) }
    }

    @Test func fmtKwh() throws {
        try check("fmtKwh", foldingSpaces: true) { Format.fmtKwh($0.number(0), locale: Self.enUS) }
    }

    @Test func money() throws {
        try check("money", foldingSpaces: true) { row in
            let frac = row.number(2).map { Int($0) }
            return Format.money(row.number(0), try #require(row.text(1)), frac, locale: Self.enUS)
        }
    }

    @Test func fmtKwhPrice() throws {
        try check("fmtKwhPrice", foldingSpaces: true) { Format.fmtKwhPrice($0.number(0), try #require($0.text(1)), locale: Self.enUS) }
    }

    @Test func fmtHour() throws {
        try check("fmtHour") { Format.fmtHour(try #require($0.number(0))) }
    }

    // MARK: Charts and times

    @Test func niceMax() throws {
        try checkNumber("niceMax") { row in
            // niceMax(null) and niceMax(undefined) are 1, like any input that is not above zero.
            Format.niceMax(row.number(0) ?? .nan)
        }
    }

    @Test func historyResolutionSuffix() throws {
        try check("resSuffix") { Format.historyResolutionSuffix(try #require($0.number(0))) }
    }

    @Test func clock() throws {
        try check("clock", foldingSpaces: true) { Format.clock(try #require($0.number(0)), locale: Self.enUS, timeZone: try zone($0)) }
    }

    @Test func timeLabel() throws {
        try check("timeLabel", foldingSpaces: true) {
            Format.timeLabel(try #require($0.number(0)), try #require($0.number(1)), locale: Self.enUS, timeZone: try zone($0))
        }
    }

    @Test func historyTooltipTime() throws {
        try check("tooltipTime", foldingSpaces: true) {
            Format.historyTooltipTime(try #require($0.number(0)), resolution: try #require($0.number(1)), locale: Self.enUS, timeZone: try zone($0))
        }
    }

    @Test func cardTooltipTime() throws {
        try check("cardTooltipTime", foldingSpaces: true) {
            // The card's tooltip is relative only on its live ten-minute range.
            Format.cardTooltipTime(
                try #require($0.number(0)), live: try #require($0.text(1)) == "10m", now: try #require($0.number(2)),
                locale: Self.enUS, timeZone: try zone($0)
            )
        }
    }
}

import Foundation
import Testing
@testable import DMCore

/// Fixtures/presentation: what the real dashboard (public/index.html, run in jsdom) showed for the
/// same inputs. Shared by the dashboard and history presentation tests.
enum DashFixture {
    /// The locale and time zone the dashboard ran in when the fixtures were recorded.
    static let enUS = Locale(identifier: "en_US")
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    static func decode<T: Decodable>(_ type: T.Type = T.self, _ path: String) throws -> T {
        try JSONDecoder().decode(type, from: try Fixture.data("presentation/" + path))
    }

    /// ICU text (clock times) is compared with Apple's narrow spaces folded, as in the formatter tests.
    static func fold(_ text: String) -> String {
        FormatVectors.foldSpaces(text)
    }

    /// "var(--cpu)", "--cpu" or "cpu" as the palette role it names.
    static func tint(_ css: String) -> MetricTint? {
        let name = css.replacingOccurrences(of: "var(", with: "").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "--", with: "")
        return MetricTint.allCases.first { $0.cssVariable == "--" + name }
    }

    static func unit(_ letter: String) -> TemperatureUnit {
        letter == "F" ? .fahrenheit : .celsius
    }

    /// Fails once for a whole table, listing the first rows that differ.
    static func report(_ failures: [String], of total: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(total > 0, "The fixture has no rows", sourceLocation: sourceLocation)
        #expect(failures.isEmpty, "\(failures.count) differences in \(total) rows:\n\(failures.prefix(12).joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    /// CanvasPoint positions are recorded to a thousandth.
    static func near(_ a: Double, _ b: Double, tolerance: Double = 0.0011) -> Bool {
        abs(a - b) <= tolerance
    }

    /// `Math.round(v) + 0.5`: how the dashboard snaps a one-pixel line.
    static func snapped(_ v: Double) -> Double {
        JS.round(v) + 0.5
    }
}

/// History points as the fixtures store them: one list of keys, one row of values per point.
struct DashColumnarPoints: Decodable {
    let keys: [String]
    let rows: [[Double?]]

    func points() throws -> [HistoryPoint] {
        let objects = rows.map { row in
            var object = [String: Any]()
            for (key, value) in zip(keys, row) { object[key] = value.map { $0 as Any } ?? NSNull() }
            return object
        }
        return try HubJSON.decode([HistoryPoint].self, from: try JSONSerialization.data(withJSONObject: objects))
    }
}

/// A point on a canvas: `[x, y]`.
struct CanvasPoint: Decodable, Equatable, CustomStringConvertible {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        x = try items.decode(Double.self)
        y = try items.decode(Double.self)
    }

    var description: String { "(\(x), \(y))" }

    func isNear(_ other: CanvasPoint) -> Bool {
        DashFixture.near(x, other.x) && DashFixture.near(y, other.y)
    }

    static func same(_ a: [[CanvasPoint]], _ b: [[CanvasPoint]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.count == $1.count && zip($0, $1).allSatisfy { $0.isNear($1) } }
    }

    static func shape(_ paths: [[CanvasPoint]]) -> String {
        paths.map { String($0.count) }.joined(separator: "/")
    }
}

/// A dot drawn on a line at the hovered point: `[colour, x, y]`.
struct CanvasDot: Decodable, CustomStringConvertible {
    let color: String
    let at: CanvasPoint

    init(color: String, at: CanvasPoint) {
        self.color = color
        self.at = at
    }

    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        color = try items.decode(String.self)
        at = CanvasPoint(x: try items.decode(Double.self), y: try items.decode(Double.self))
    }

    var description: String { "\(color)\(at)" }

    static func same(_ a: [CanvasDot], _ b: [CanvasDot]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { DashFixture.tint($0.color) == DashFixture.tint($1.color) && $0.at.isNear($1.at) }
    }
}

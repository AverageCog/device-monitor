import Foundation
import Testing
@testable import DMCore

/// The `locale:` parameter outside en-US: the Swift ports must print what the dashboard prints in
/// a browser set to that locale (formatting-locales.json, recorded from Node).
@Suite struct FormatLocaleTests {
    struct Recorded: Decodable {
        struct Row: Decodable {
            let function: String
            let args: [FormatVectors.Value]
            let out: String

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                function = try items.decode(String.self)
                args = try items.decode([FormatVectors.Value].self)
                out = try items.decode(String.self)
            }
        }

        let timeZone: String
        let locales: [String: [Row]]
    }

    @Test func numbersMoneyAndClockFollowTheLocale() throws {
        let recorded = try JSONDecoder().decode(Recorded.self, from: try Fixture.data("models/formatting-locales.json"))
        let zone = try #require(TimeZone(identifier: recorded.timeZone))
        #expect(recorded.locales.keys.sorted() == ["de_DE", "en_GB", "es_ES", "fr_FR", "nl_NL", "pl_PL", "pt_BR", "sv_SE"])

        for (identifier, rows) in recorded.locales.sorted(by: { $0.key < $1.key }) {
            let locale = Locale(identifier: identifier)
            var failures: [String] = []
            for row in rows {
                let number = row.args.first?.double
                let currency = row.args.count > 1 ? row.args[1].text ?? "" : ""
                let actual: String
                switch row.function {
                case "clock": actual = Format.clock(number ?? .nan, locale: locale, timeZone: zone)
                case "money": actual = Format.money(number, currency, locale: locale)
                case "fmtKwhPrice": actual = Format.fmtKwhPrice(number, currency, locale: locale)
                case "fmtKwh": actual = Format.fmtKwh(number, locale: locale)
                case "toLocaleString": actual = JS.toLocaleString(number ?? .nan, locale: locale)
                default:
                    failures.append("No port for \(row.function)")
                    continue
                }
                if FormatVectors.foldSpaces(actual) != FormatVectors.foldSpaces(row.out) {
                    failures.append("\(row.function)(\(row.args.map(\.description).joined(separator: ", "))) gives \"\(actual)\", JavaScript gives \"\(row.out)\"")
                }
            }
            #expect(rows.count == 104)
            #expect(failures.isEmpty, "\(identifier): \(failures.count) of \(rows.count) rows differ:\n\(failures.prefix(12).joined(separator: "\n"))")
        }
    }

    @Test func aFewToRead() {
        let german = Locale(identifier: "de_DE"), british = Locale(identifier: "en_GB"), french = Locale(identifier: "fr_FR")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let fold = FormatVectors.foldSpaces
        #expect(fold(Format.money(1234.5, "EUR", locale: german)) == "1.235 \u{20AC}")
        #expect(fold(Format.money(12.345, "EUR", locale: german)) == "12,35 \u{20AC}")
        #expect(Format.money(12.345, "USD", locale: british) == "US$12.35")
        #expect(fold(Format.fmtKwhPrice(0.316, "EUR", locale: french)) == "0,316 \u{20AC}")
        #expect(Format.fmtKwh(1234.5, locale: german) == "1.235 kWh")
        #expect(Format.fmtKwh(99.95, locale: german) == "100.0 kWh")   // toFixed knows no locale: the dashboard prints a point here
        // 24-hour locales: no AM/PM, and a single-digit hour stays single.
        #expect(Format.clock(1_795_213_064_123, locale: german, timeZone: berlin) == "23:17")
        #expect(Format.clock(1_795_161_909_000, locale: german, timeZone: berlin) == "9:05")
        #expect(Format.clock(1_795_161_909_000, locale: british, timeZone: berlin) == "9:05")
        // Spanish groups thousands only from five digits on.
        #expect(JS.toLocaleString(9999, locale: Locale(identifier: "es_ES")) == "9999")
        #expect(JS.toLocaleString(-1_234_567.891, locale: german) == "-1.234.567,891")
    }
}

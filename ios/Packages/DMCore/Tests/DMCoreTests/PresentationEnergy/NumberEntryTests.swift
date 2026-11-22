import Foundation
import Testing
@testable import DMCore

@Suite struct NumberEntryTests {
    private let enUS = EnergyFixtures.enUS

    @Test func parseFloatMatchesJavaScript() throws {
        let rows = try EnergyFixtures.load(EnergyFixtures.Numbers.self, "numbers.json").parseFloat
        #expect(rows.count > 250)
        var failures: [String] = []
        for row in rows {
            let ours = NumberEntry.parseFloat(row[0])
            let same = row[1] == "NaN" ? ours.isNaN : ours.bitPattern == EnergyFixtures.double(bits: row[1]).bitPattern
            if !same { failures.append("parseFloat(\"\(row[0])\") gives \(JS.string(ours)), JavaScript \(row[1] == "NaN" ? "NaN" : JS.string(EnergyFixtures.double(bits: row[1])))") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(rows.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    @Test func parseIsParseFloatWithNilForNaN() {
        #expect(NumberEntry.parse("0.25", locale: enUS) == 0.25)
        #expect(NumberEntry.parse("  .5kWh", locale: enUS) == 0.5)
        #expect(NumberEntry.parse("", locale: enUS) == nil)
        #expect(NumberEntry.parse("abc", locale: enUS) == nil)
        #expect(NumberEntry.parse("-3", locale: enUS) == -3)
        #expect(NumberEntry.parse("Infinity", locale: enUS) == .infinity)
        // A comma ends the number for a browser in every locale; here only where it is not the decimal mark.
        #expect(NumberEntry.parse("0,25", locale: enUS) == 0)
    }

    @Test func decimalCommaIsReadAndWritten() {
        let german = Locale(identifier: "de_DE")
        #expect(NumberEntry.parse("0,25", locale: german) == 0.25)
        #expect(NumberEntry.parse("0.25", locale: german) == 0.25)
        #expect(NumberEntry.parse(",5", locale: german) == 0.5)
        #expect(NumberEntry.text(0.25, locale: german) == "0,25")
        #expect(NumberEntry.text(31, locale: german) == "31")
        #expect(NumberEntry.text(0.25, locale: enUS) == "0.25")
        #expect(NumberEntry.text(0.1235, locale: Locale(identifier: "fr_FR")) == "0,1235")
        // What is written reads back as the same number.
        for value in [0.0001, 0.165, 0.30000000000000004, 12.5, 999.9999, 1000] {
            for locale in [enUS, german, Locale(identifier: "sv_SE"), Locale(identifier: "ar_EG"), Locale(identifier: "hi_IN")] {
                #expect(NumberEntry.parse(NumberEntry.text(value, locale: locale), locale: locale) == value, "\(value) in \(locale.identifier)")
            }
        }
    }

    @Test func digitsOfOtherScriptsCount() {
        #expect(NumberEntry.parse("٠.٢٥", locale: enUS) == 0.25)
        #expect(NumberEntry.parse("٠٫٢٥", locale: Locale(identifier: "ar_EG")) == 0.25)
        #expect(NumberEntry.parse("१२.५", locale: enUS) == 12.5)
        #expect(NumberEntry.parse("１２", locale: enUS) == 12)
    }
}

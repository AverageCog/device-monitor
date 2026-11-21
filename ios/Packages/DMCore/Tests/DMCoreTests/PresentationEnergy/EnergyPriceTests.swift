import Foundation
import Testing
@testable import DMCore

/// priceSettings, fmtPrice, priceSource, the Settings hint and dayRate against price-texts.json,
/// and the hub's validEnergySettings against hub-stored.json.
@Suite struct EnergyPriceTests {
    private static let texts = Result { try EnergyFixtures.load(EnergyFixtures.PriceTexts.self, "price-texts.json") }
    private let enUS = EnergyFixtures.enUS
    private let fold = FormatVectors.foldSpaces

    @Test func savedAndGuessedPricesReadAsOnTheDashboard() throws {
        let rows = try Self.texts.get().rows
        #expect(rows.count > 180)
        var failures: [String] = []
        for row in rows {
            let guess = PriceRegions.guess(timeZoneIdentifier: row.tz, languageTag: row.language)
            let price = EnergyPrice(saved: row.saved, guessedRegion: guess)
            let label = "\(row.tz) \(row.language ?? "nil") \(row.saved.map { "\($0)" } ?? "nothing saved")"
            func check(_ what: String, _ ours: String, _ theirs: String) {
                if fold(ours) != fold(theirs) { failures.append("\(label): \(what) is \"\(ours)\", the dashboard says \"\(theirs)\"") }
            }
            check("region", price.region, row.region)
            check("currency", price.currency, row.currency)
            check("guessed", "\(price.guessed)", "\(row.guessed)")
            check("rate", String(price.rate.bitPattern, radix: 16), String(EnergyFixtures.double(bits: row.rateBits).bitPattern, radix: 16))
            check("fmtPrice", price.priceText(locale: enUS), row.fmtPrice)
            check("priceSource", price.source, row.source)
            check("hint", price.settingsHint, row.hint)
            check("regionName", price.regionName, row.regionName)
            check("dayRate", String(price.dayRate.bitPattern, radix: 16), String(EnergyFixtures.double(bits: row.dayRate).bitPattern, radix: 16))
            check("isTimeOfUse", "\(price.isTimeOfUse)", "\(row.isTou)")
            check("rate field", NumberEntry.text(price.rate, locale: enUS), row.rateValue)
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    @Test func textsOfPricesHandedOverDirectly() throws {
        let rows = try Self.texts.get().direct
        #expect(rows.count > 150)
        var failures: [String] = []
        for row in rows {
            let price = row.price.value
            if fold(price.priceText(locale: enUS)) != fold(row.fmtPrice) { failures.append("fmtPrice(\(price)) is \"\(price.priceText(locale: enUS))\", not \"\(row.fmtPrice)\"") }
            if price.source != row.source { failures.append("priceSource(\(price)) is \"\(price.source)\", not \"\(row.source)\"") }
            if price.dayRate.bitPattern != EnergyFixtures.double(bits: row.dayRate).bitPattern {
                failures.append("dayRate(\(price)) is \(JS.string(price.dayRate)), not \(JS.string(EnergyFixtures.double(bits: row.dayRate)))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    @Test func aGuessOutsideTheTableIsTheUSAverage() {
        let price = EnergyPrice(saved: nil, guessedRegion: "ZZ")
        #expect(price == EnergyPrice(region: "US", currency: "USD", rate: 0.165, guessed: true))
        #expect(price.settings == EnergySettings(region: "US", rate: 0.165, currency: "USD"))
    }

    @Test func priceForThisDeviceGuessesFromZoneAndLocale() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let guessed = EnergyPrice(saved: nil, timeZone: berlin, locale: Locale(identifier: "en_US"))
        #expect(guessed == EnergyPrice(region: "DE", currency: "EUR", rate: 0.39, guessed: true))
        let saved = EnergySettings(region: "custom", rate: 0.2, currency: "CHF", tou: [TouPeriod(from: 1, to: 2, rate: 0.1)])
        let price = EnergyPrice(saved: saved, timeZone: berlin, locale: Locale(identifier: "en_US"))
        #expect(!price.guessed)
        #expect(price.settings == saved)
    }

    @Test func priceTextFollowsTheLocale() {
        let price = EnergyPrice(region: "DE", currency: "EUR", rate: 0.39)
        #expect(fold(price.priceText(locale: Locale(identifier: "de_DE"))) == "0,390 €/kWh")
    }

    // MARK: validEnergySettings

    @Test func hubStoredMatchesTheHub() throws {
        let rows = try EnergyFixtures.load(EnergyFixtures.HubStored.self, "hub-stored.json").rows
        #expect(rows.count > 200)
        #expect(rows.contains { $0.stored == nil } && rows.contains { $0.stored != nil })
        var failures: [String] = []
        for row in rows {
            let ours = EnergyPricing.hubStored(row.body)
            if ours != row.stored { failures.append("\(row.body)\n   ours: \(ours.map { "\($0)" } ?? "refused")\n   hub:  \(row.stored.map { "\($0)" } ?? "refused")") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(rows.count) differ:\n\(failures.prefix(10).joined(separator: "\n"))")
    }

    @Test func storingIsIdempotent() throws {
        for row in try EnergyFixtures.load(EnergyFixtures.HubStored.self, "hub-stored.json").rows {
            guard let stored = row.stored else { continue }
            #expect(EnergyPricing.hubStored(stored) == stored)
        }
    }
}

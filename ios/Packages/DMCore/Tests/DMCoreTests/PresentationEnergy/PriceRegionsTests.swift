import Foundation
import Testing
@testable import DMCore

/// The price table, the pickers and the guess, against regions.json (PRICE_REGIONS, TZ_REGIONS,
/// renderPriceRow's markup and guessRegion, as the dashboard has them).
@Suite struct PriceRegionsTests {
    private static let loaded = Result { try EnergyFixtures.load(EnergyFixtures.Regions.self, "regions.json") }

    private var fixture: EnergyFixtures.Regions {
        get throws { try Self.loaded.get() }
    }

    @Test func tableMatchesTheDashboardEntryForEntry() throws {
        let expected = try fixture.regions
        #expect(expected.count == 94)
        #expect(PriceRegions.all.count == expected.count)
        for (ours, theirs) in zip(PriceRegions.all, expected) {
            #expect(ours.code == theirs.code)
            #expect(ours.name == theirs.name, "\(theirs.code)")
            #expect(ours.currency == theirs.currency, "\(theirs.code)")
            #expect(ours.rate == theirs.rate, "\(theirs.code)")
            // The JSON number and the JavaScript literal must be the same double as ours.
            let bits = try #require(try fixture.rateBits[theirs.code])
            #expect(ours.rate.bitPattern == EnergyFixtures.double(bits: bits).bitPattern, "\(theirs.code)")
            #expect(PriceRegions.region(theirs.code) == ours)
            #expect(ours.id == theirs.code)
        }
        #expect(Set(PriceRegions.all.map(\.code)).count == PriceRegions.all.count)
    }

    @Test func everyCodeAndCurrencyIsOneTheHubAccepts() {
        for region in PriceRegions.all {
            #expect(EnergyPricing.hubStored(EnergySettings(region: region.code, rate: region.rate, currency: region.currency)) != nil, "\(region.code)")
        }
        #expect(EnergyPricing.isRegionCode(PriceRegions.customCode))
    }

    @Test func timeZoneTableMatches() throws {
        let expected = try fixture.tzRegions
        #expect(expected.count == 51)
        #expect(PriceRegions.timeZoneRegions.count == expected.count)
        for pair in expected {
            #expect(PriceRegions.timeZoneRegions[pair[0]] == pair[1], "\(pair[0])")
            #expect(PriceRegions.region(pair[1]) != nil, "\(pair[1]) is not in the table")
        }
    }

    @Test func pickerGroupsAreTheDashboardsOptgroups() throws {
        let expected = try fixture.groups
        #expect(expected.map(\.label) == ["United States", "Canada", "Other countries"])
        #expect(PriceRegions.groups.map(\.title) == expected.map(\.label))
        for (ours, theirs) in zip(PriceRegions.groups, expected) {
            #expect(ours.regions.map(\.code) == theirs.options.map(\.value), "\(theirs.label)")
            #expect(ours.regions.map(\.name) == theirs.options.map(\.label), "\(theirs.label)")
        }
        // The whole picker: the groups in order, then the lone "Somewhere else".
        let all = try fixture.regionOptions
        let ours = PriceRegions.groups.flatMap(\.regions).map(\.code) + [PriceRegions.customCode]
        #expect(ours == all.map(\.value))
        #expect(all.last?.label == PriceRegions.customName)
        #expect(PriceRegions.groups.flatMap(\.regions).count == PriceRegions.all.count)
    }

    @Test func currencyListMatches() throws {
        #expect(PriceRegions.currencies == (try fixture.currencies))
        #expect(PriceRegions.currencies.count == 25)
    }

    @Test func regionNames() throws {
        let rows = try fixture.regionName
        #expect(rows.count > 95)
        for row in rows {
            #expect(PriceRegions.name(for: row[0]) == row[1], "regionName(\(row[0]))")
        }
    }

    @Test func guessMatchesEveryRecordedZoneAndLanguage() throws {
        let rows = try fixture.guess
        #expect(rows.count > 600)
        var failures: [String] = []
        for row in rows {
            let ours = PriceRegions.guess(timeZoneIdentifier: row.zone, languageTag: row.language)
            if ours != row.region { failures.append("guess(\(row.zone), \(row.language ?? "nil")) gives \(ours), the dashboard \(row.region)") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(rows.count) differ:\n\(failures.prefix(15).joined(separator: "\n"))")
        // Every outcome is a code the table has.
        #expect(Set(rows.map(\.region)).allSatisfy { PriceRegions.region($0) != nil })
    }

    @Test func guessFromALocaleUsesItsRegionEvenBehindAScript() throws {
        let kyiv = try #require(TimeZone(identifier: "Europe/Kyiv"))
        // A browser's "zh-Hant-TW" yields no country (the dashboard reads the second subtag)…
        #expect(PriceRegions.guess(timeZoneIdentifier: "Europe/Kyiv", languageTag: "zh-Hant-TW") == "US")
        // …a Locale knows its region.
        #expect(PriceRegions.guess(timeZone: kyiv, locale: Locale(identifier: "zh-Hant-TW")) == "TW")
        #expect(PriceRegions.guess(timeZone: kyiv, locale: Locale(identifier: "de_DE")) == "DE")
        #expect(PriceRegions.guess(timeZone: kyiv, locale: Locale(identifier: "en")) == "US")
        #expect(PriceRegions.guess(timeZone: kyiv, locale: Locale(identifier: "es_419")) == "US")
        // The zone wins over the locale.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(PriceRegions.guess(timeZone: berlin, locale: Locale(identifier: "en_US")) == "DE")
        let knox = try #require(TimeZone(identifier: "America/Indiana/Knox"))
        #expect(PriceRegions.guess(timeZone: knox, locale: Locale(identifier: "de_DE")) == "US-IN")
        #expect(PriceRegions.guess(timeZoneIdentifier: "Nowhere/Land", localeRegion: "gb") == "GB")
        #expect(PriceRegions.guess(timeZoneIdentifier: "Nowhere/Land", localeRegion: nil) == "US")
    }
}

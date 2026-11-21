import Foundation
import Testing
@testable import DMCore

/// presentation/dashboard/collation.json: names and how `localeCompare` orders them (Node, so V8
/// and ICU as in Chrome). Cards with the same place are sorted by name, so the app has to agree;
/// where it is known not to, the fixture says so and the tests hold it to exactly that.
@Suite struct NameCollationTests {
    /// `[a, b, sign of a.localeCompare(b)]`, in en-US.
    struct Pair: Decodable {
        let a: String
        let b: String
        let sign: Int

        init(from decoder: Decoder) throws {
            var items = try decoder.unkeyedContainer()
            a = try items.decode(String.self)
            b = try items.decode(String.self)
            sign = try items.decode(Int.self)
        }
    }

    /// How one locale orders `names`: a place per name, the same place for names it calls equal.
    struct Order: Decodable {
        let locale: String
        let places: [Int]
    }

    /// `[locale, a, b, sign of a.localeCompare(b, locale)]`: a pair the app orders differently.
    struct Limit: Decodable {
        let locale: String
        let a: String
        let b: String
        let sign: Int

        init(from decoder: Decoder) throws {
            var items = try decoder.unkeyedContainer()
            locale = try items.decode(String.self)
            a = try items.decode(String.self)
            b = try items.decode(String.self)
            sign = try items.decode(Int.self)
        }
    }

    struct Collation: Decodable {
        let host: [Pair]
        let punctuation: [Pair]
        let latin: [Pair]
        let world: [Pair]
        let forms: [Pair]
        let names: [String]
        let orders: [Order]
        let limits: [Limit]
    }

    let collation: Collation

    init() throws {
        collation = try DashFixture.decode(Collation.self, "dashboard/collation.json")
    }

    /// The fixture names locales as a browser does ("zh-Hans-CN"), Foundation as "zh_Hans_CN".
    private func locale(_ tag: String) -> Locale {
        Locale(identifier: tag.replacingOccurrences(of: "-", with: "_"))
    }

    private func show(_ name: String) -> String {
        "\"\(name)\" (\(name.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")))"
    }

    private func differences(_ pairs: [Pair]) -> [String] {
        pairs.compactMap { pair in
            let mine = DashboardOrder.compareNames(pair.a, pair.b, locale: DashFixture.enUS).rawValue
            return mine == pair.sign ? nil : "\(show(pair.a)) against \(show(pair.b)): \(mine), a browser says \(pair.sign)"
        }
    }

    @Test func namesOfTheKindComputersHave() {
        DashFixture.report(differences(collation.host), of: collation.host.count)
    }

    @Test func punctuation() {
        DashFixture.report(differences(collation.punctuation), of: collation.punctuation.count)
    }

    @Test func accentedLatin() {
        DashFixture.report(differences(collation.latin), of: collation.latin.count)
    }

    @Test func otherScripts() {
        DashFixture.report(differences(collation.world), of: collation.world.count)
    }

    /// Names apart only in width, kana type, kana size or a compatibility form, which Foundation's
    /// comparison calls equal unless told to order them, and two spellings of one text, which a
    /// browser calls equal.
    @Test func widthKanaAndCompatibilityForms() {
        DashFixture.report(differences(collation.forms), of: collation.forms.count)
        #expect(collation.forms.contains { $0.sign == 0 && $0.a.unicodeScalars.elementsEqual($0.b.unicodeScalars) == false }, "No pair of two spellings of one text")
    }

    /// Thai is compared only on names of letters and digits: a browser set to Thai ignores
    /// everything else in a name, Foundation does not.
    private func isCompared(_ name: String, in order: Order) -> Bool {
        !order.locale.hasPrefix("th") || name.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    /// The same list of names in every locale of the fixture. The app may differ from a browser
    /// only on the pairs the fixture lists as known for that locale, and has to give one answer
    /// whichever of two names it is asked about first: sorting relies on that.
    @Test func otherLanguages() throws {
        let names = collation.names
        #expect(names.count > 140 && collation.orders.count > 30)
        var failures = [String](), lopsided = [String](), compared = 0, known = 0
        for order in collation.orders {
            #expect(order.places.count == names.count, "\(order.locale)")
            let locale = locale(order.locale)
            let limits = collation.limits.filter { $0.locale == order.locale }
            for i in names.indices {
                for j in names.indices where j >= i {
                    let mine = DashboardOrder.compareNames(names[i], names[j], locale: locale).rawValue
                    let back = DashboardOrder.compareNames(names[j], names[i], locale: locale).rawValue
                    if mine != -back { lopsided.append("\(order.locale): \(show(names[i])) against \(show(names[j])) is \(mine), the other way round \(back)") }
                    guard isCompared(names[i], in: order), isCompared(names[j], in: order) else { continue }
                    let browser = (order.places[i] - order.places[j]).signum()
                    compared += 1
                    if mine == browser { continue }
                    if limits.contains(where: { ($0.a == names[i] && $0.b == names[j]) || ($0.a == names[j] && $0.b == names[i]) }) {
                        known += 1
                    } else {
                        failures.append("\(order.locale): \(show(names[i])) against \(show(names[j])): \(mine), a browser says \(browser)")
                    }
                }
            }
        }
        DashFixture.report(failures, of: compared)
        DashFixture.report(lopsided, of: compared)
        #expect(known > 0, "No known difference among the names: the fixture no longer covers them")

        // What the exception for Japanese is for: a browser set to Japanese calls these one name,
        // any other tells them apart.
        let japanese = try #require(collation.orders.first { $0.locale == "ja-JP" })
        let english = try #require(collation.orders.first { $0.locale == "en-US" })
        let kana = try [#require(names.firstIndex(of: "あ")), #require(names.firstIndex(of: "ア")), #require(names.firstIndex(of: "ｱ"))]
        #expect(Set(kana.map { japanese.places[$0] }).count == 1 && Set(kana.map { english.places[$0] }).count == 3)
    }

    /// The differences `DashboardOrder.compareNames` documents are still differences. When one of
    /// these starts to agree with a browser, its row in `limits` and the comment there go.
    @Test func documentedDifferencesAreStillThere() {
        var agreeing = [String]()
        for limit in collation.limits {
            let mine = DashboardOrder.compareNames(limit.a, limit.b, locale: locale(limit.locale)).rawValue
            if mine == limit.sign { agreeing.append("\(limit.locale): \(show(limit.a)) against \(show(limit.b)) is \(mine) here and in a browser") }
        }
        DashFixture.report(agreeing, of: collation.limits.count)
        for language in ["en", "da", "mt", "zh", "ja", "th", "fo", "ig", "tk", "sv", "fi"] {
            #expect(collation.limits.contains { $0.locale.hasPrefix(language + "-") }, "No known difference recorded for \(language)")
        }
    }
}

import Foundation
import Testing
@testable import DMCore

/// presentation/dashboard/collation.json: pairs of names and how `localeCompare` orders them in a
/// browser set to en-US. Cards with the same place are sorted by name, so the app has to agree.
@Suite struct NameCollationTests {
    /// `[a, b, sign of a.localeCompare(b)]`.
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

    struct Collation: Decodable {
        let host: [Pair]
        let punctuation: [Pair]
        let latin: [Pair]
        let world: [Pair]
    }

    let collation: Collation

    init() throws {
        collation = try DashFixture.decode(Collation.self, "dashboard/collation.json")
    }

    private func differences(_ pairs: [Pair]) -> [String] {
        pairs.compactMap { pair in
            let mine = DashboardOrder.compareNames(pair.a, pair.b, locale: DashFixture.enUS).rawValue
            return mine == pair.sign ? nil : "\"\(pair.a)\" against \"\(pair.b)\": \(mine), a browser says \(pair.sign)"
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
}

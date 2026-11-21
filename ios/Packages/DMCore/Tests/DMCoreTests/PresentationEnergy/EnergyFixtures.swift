import Foundation
@testable import DMCore

/// Fixtures/presentation/energy: what the dashboard's own electricity price code produced in Node
/// (see the README next to the files).
enum EnergyFixtures {
    static let enUS = Locale(identifier: "en_US")

    static func load<T: Decodable>(_ type: T.Type = T.self, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: try Fixture.data("presentation/energy/" + name))
    }

    static func double(bits hex: String) -> Double {
        Double(bitPattern: UInt64(hex, radix: 16) ?? 0)
    }

    // MARK: regions.json

    struct Regions: Decodable {
        struct Region: Decodable {
            let code, name, currency: String
            let rate: Double

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                code = try items.decode(String.self)
                name = try items.decode(String.self)
                currency = try items.decode(String.self)
                rate = try items.decode(Double.self)
            }
        }

        struct Option: Decodable {
            let value, label: String
        }

        struct Group: Decodable {
            let label: String
            let options: [Option]
        }

        /// `[zone, language or null, 1 when a language was given at all, expected region]`
        struct Guess: Decodable {
            let zone: String
            let language: String?
            let region: String

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                zone = try items.decode(String.self)
                language = try items.decodeIfPresent(String.self)
                _ = try items.decode(Int.self)
                region = try items.decode(String.self)
            }
        }

        let regions: [Region]
        let rateBits: [String: String]
        let tzRegions: [[String]]
        let groups: [Group]
        let regionOptions: [Option]
        let currencies: [String]
        let regionName: [[String]]
        let guess: [Guess]
    }

    // MARK: price-texts.json

    struct PriceTexts: Decodable {
        struct Row: Decodable {
            let tz: String
            let language: String?
            let saved: EnergySettings?
            let guessed: Bool
            let region, currency, rateBits: String
            let fmtPrice, source, hint, dayRate, regionName, rateValue: String
            let isTou: Bool
        }

        struct Direct: Decodable {
            struct Price: Decodable {
                let region, currency: String
                let rate: Double
                let guessed: Bool
                let tou: [TouPeriod]?

                var value: EnergyPrice {
                    EnergyPrice(region: region, currency: currency, rate: rate, tou: tou ?? [], guessed: guessed)
                }
            }

            let price: Price
            let fmtPrice, source, dayRate: String
        }

        let rows: [Row]
        let direct: [Direct]
    }

    // MARK: hours.json

    struct Hours: Decodable {
        struct Option: Decodable {
            let hour: Double
            let label: String

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                hour = try items.decode(Double.self)
                label = try items.decode(String.self)
            }
        }

        let from, to: [Option]
        let labels: [String: String]
    }

    // MARK: numbers.json and hub-stored.json

    struct Numbers: Decodable {
        /// `[text, bits of parseFloat(text) or "NaN"]`
        let parseFloat: [[String]]
    }

    struct HubStored: Decodable {
        struct Row: Decodable {
            let body: EnergySettings
            let stored: EnergySettings?
        }

        let rows: [Row]
    }

    // MARK: editor.json

    struct Editor: Decodable {
        struct Snapshot: Decodable {
            struct Row: Decodable, Equatable {
                let from, to: Double
                let rate: String
                let bad: Bool

                init(from decoder: Decoder) throws {
                    var items = try decoder.unkeyedContainer()
                    from = try items.decode(Double.self)
                    to = try items.decode(Double.self)
                    rate = try items.decode(String.self)
                    bad = try items.decode(Int.self) == 1
                }
            }

            struct Base: Decodable, Equatable {
                let value: String
                let bad: Bool

                init(from decoder: Decoder) throws {
                    var items = try decoder.unkeyedContainer()
                    value = try items.decode(String.self)
                    bad = try items.decode(Int.self) == 1
                }
            }

            let hint, region, currency, rate: String
            let isTou, guessed: Bool
            let rows: [Row]?
            let base: Base?
            let lastTou: [TouPeriod]?
        }

        struct Action: Decodable {
            let type: String
            let focus: String
            let code, text, mode: String?
            let index: Int?
            let hour: Double?
            let settings: EnergySettings?
        }

        /// What the hub stored: nothing (refused, or nothing was sent), the body as sent, or a
        /// rounded and sorted version of it.
        enum Answer: Decodable {
            case none, same
            case stored(EnergySettings)

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if single.decodeNil() {
                    self = .none
                } else if (try? single.decode(String.self)) == "same" {
                    self = .same
                } else {
                    self = .stored(try single.decode(EnergySettings.self))
                }
            }
        }

        struct Step: Decodable {
            let action: Action
            let put: EnergySettings?
            let answer: Answer
            let saved: EnergySettings?
            let after: Snapshot
        }

        struct Scenario: Decodable {
            let name, tz, guessedRegion: String
            let language: String?
            let saved: EnergySettings?
            let initial: Snapshot
            let steps: [Step]
        }

        let scenarios: [Scenario]
    }
}

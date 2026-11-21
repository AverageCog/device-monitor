import Foundation
@testable import DMCore

/// Fixtures/presentation/advanced/render.json: what renderAdv and drawAdvChart of the dashboard
/// wrote into a fake page in Node, for captured and generated hub data.
enum AdvancedFixtures {
    static let enUS = Locale(identifier: "en_US")
    private static let loaded = Result { try JSONDecoder().decode(Render.self, from: try Fixture.data("presentation/advanced/render.json")) }

    static func render() throws -> Render {
        try loaded.get()
    }

    static func page() throws -> Page {
        try loaded.get().page
    }

    /// A named entry of the file's shared sets, or the value itself.
    enum Ref<Value: Decodable & Sendable>: Decodable, Sendable {
        case named(String)
        case inline(Value)

        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self = .named(name)
            } else {
                self = .inline(try Value(from: decoder))
            }
        }
    }

    struct Page: Decodable {
        struct Layout: Decodable {
            let left, right, top, bottom: Double
        }

        let note, defaultRange, title, electricity, usage: String
        let rangeButtons, colors: [[String]]
        let reloadMs, liveMs, tipWidth, dimmedAlpha: Double
        let layout: Layout
    }

    struct Render: Decodable {
        let page: Page
        let deviceSets: [String: [Device]]
        let energySets: [String: EnergyResponse]
        let scenarios: [Scenario]
    }

    struct Scenario: Decodable {
        let name, tz, language, unit, range: String
        let now: Double
        let saved: EnergySettings?
        let devices: Ref<[Device]>
        let energy: Ref<EnergyResponse>?
        /// advBounds() at `now`, recorded when there is no data to take the bounds from.
        let bounds: [Double]?
        let out: Output

        func devices(in file: Render) throws -> [Device] {
            switch devices {
            case .inline(let list): return list
            case .named(let name):
                guard let list = file.deviceSets[name] else { throw MissingSet(name: name) }
                return list
            }
        }

        func energy(in file: Render) throws -> EnergyResponse? {
            switch energy {
            case nil: return nil
            case .inline(let value): return value
            case .named(let name):
                guard let value = file.energySets[name] else { throw MissingSet(name: name) }
                return value
            }
        }
    }

    struct MissingSet: Error {
        let name: String
    }

    struct Output: Decodable {
        struct Price: Decodable {
            let label, value, source, button, text: String
        }

        struct PowerRow: Decodable {
            let name, color, now, average, peak, energy, cost, share, source, sourceTitle: String
            let nowMuted: Bool
            let nowTitle: String?
            let shareWidth: Double
        }

        struct UsageRow: Decodable {
            let name, color, memory, downloaded, uploaded, diskRead, diskWritten: String
            /// `[main text, muted text]`
            let online, cpu, gpu, temps: [String]
        }

        struct Table<Row: Decodable & Sendable>: Decodable, Sendable {
            let head: [String]?
            let rows: [Row]?
            let foot: [String]?
            let empty: String?
        }

        struct Label: Decodable {
            let text: String
            let fraction: Double

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                text = try items.decode(String.self)
                fraction = try items.decode(Double.self)
            }
        }

        struct XLabel: Decodable {
            let index: Int
            let text: String

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                index = try items.decode(Int.self)
                text = try items.decode(String.self)
            }
        }

        /// `[resolved colour, height as a share of the plot]`
        struct Bar: Decodable {
            let fill: String
            let fraction: Double

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                fill = try items.decode(String.self)
                fraction = try items.decode(Double.self)
            }
        }

        struct Width: Decodable {
            let W, slot: Double
            let barWidth: Double?
            let yLabels: [Label]
            let xLabels: [XLabel]
            let bars: [[Bar]]?
        }

        struct Tip: Decodable {
            let title, short: String
            /// `[colour token, name, energy, cost]`, the last one being the total.
            let rows: [[String]]
            let left: Double
        }

        struct Hover: Decodable {
            struct Point: Decodable {
                let x: Double
                let index: Int?

                init(from decoder: Decoder) throws {
                    var items = try decoder.unkeyedContainer()
                    x = try items.decode(Double.self)
                    index = try items.decodeIfPresent(Int.self)
                }
            }

            let W: Double
            let points: [Point]
        }

        struct Chart: Decodable {
            let widths: [Width]
            let tips: [Tip]
            let hover: [Hover]
        }

        let rangeOn: [String]
        let tiles: [[String]]
        let price: Price
        let chartTitle: String
        let legend: [[String]]
        let power: Table<PowerRow>
        let usage: Table<UsageRow>
        let chart: Chart?
    }

    // MARK: Comparing text

    /// Node puts a plain space before AM/PM and after a currency code, Apple's ICU U+202F and
    /// U+00A0; both sides are compared with those folded to a space (as the formatter tests do).
    static func same(_ ours: String, _ theirs: String) -> Bool {
        FormatVectors.foldSpaces(ours) == FormatVectors.foldSpaces(theirs)
    }

    /// Text with a date in it. Apple's locale data joins a date and a time with " at " where
    /// Node's has a comma ("Nov 18 at 12:31 PM"), and with `reordered` the parts may come in
    /// another order ("Fri 20" for Node's "20 Fri"). The parts themselves must be equal.
    static func sameDate(_ ours: String, _ theirs: String, reordered: Bool = false) -> Bool {
        let a = FormatVectors.foldSpaces(ours).replacingOccurrences(of: " at ", with: ", "), b = FormatVectors.foldSpaces(theirs)
        if a == b { return true }
        guard reordered else { return false }
        let parts = { (text: String) in text.split(whereSeparator: { $0 == " " || $0 == "," }).sorted() }
        return parts(a) == parts(b)
    }
}

import Foundation
@testable import DMCore

/// Fixtures/presentation/alerts: what the hub's own alerts.js answered in Node (see the README
/// next to the files).
enum AlertFixtures {
    static let enUS = Locale(identifier: "en_US")

    /// The hub's answers are read the way the app reads them: half a surrogate pair, which the
    /// hub leaves where it cuts a text and JSON.stringify writes as an escape, arrives as U+FFFD.
    static func load<T: Decodable>(_ type: T.Type = T.self, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: HubClient.wellFormedJSON(try Fixture.data("presentation/alerts/" + name)))
    }

    // MARK: types.json

    struct Types: Decodable {
        struct RuleType: Decodable {
            /// A number, null (no entry: 5 % of the limit), or "none" for a type without the key.
            enum Hysteresis: Decodable, Equatable {
                case fixed(Double), unset, absent

                init(from decoder: Decoder) throws {
                    let single = try decoder.singleValueContainer()
                    if single.decodeNil() {
                        self = .unset
                    } else if let number = try? single.decode(Double.self) {
                        self = .fixed(number)
                    } else {
                        self = .absent
                    }
                }
            }

            let type, label: String
            let threshold: [Double]?
            let hyst: Hysteresis
        }

        struct DefaultRule: Decodable {
            let type, device: String
            let threshold: Double?
            let minutes: Int
            let enabled: Bool
        }

        let types: [RuleType]
        let defaultSettings: AlertSettings
        let defaultRules: [DefaultRule]
        let maxRules: Int
    }

    // MARK: urls.json

    struct URLs: Decodable {
        struct Row: Decodable {
            let input: String
            let normalized: String?

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                input = try items.decode(String.self)
                normalized = try items.decodeIfPresent(String.self)
            }
        }

        let rows: [Row]
        let emptyServerBecomes: String
    }

    // MARK: validation.json

    struct Validation: Decodable {
        struct Full: Decodable {
            let field: String?
            let prevWebhook: Bool
            let body: AlertSettings
            let answer: AlertSettings?
        }

        struct RuleRow: Decodable {
            let field: String?
            let rule: AlertRule
            let stored: AlertRule?
        }

        struct Stored: Decodable {
            let channels: AlertChannels
            let notifyResolved: Bool
            let tempUnit: TemperatureUnit
        }

        struct ChannelRow: Decodable {
            let field: String?
            let prevWebhook: Bool
            let channels: AlertChannels
            let notifyResolved: Bool
            let tempUnit: TemperatureUnit
            let stored: Stored?
        }

        let base, baseAnswer: AlertSettings
        let rows: [Full]
        let ruleRows: [RuleRow]
        let channelRows: [ChannelRow]
    }

    // MARK: values.json and texts.json

    struct Values: Decodable {
        /// `[unit, type or "temp()", value (null and "undefined" both mean none), currency or null, text]`
        struct Row: Decodable {
            let unit: TemperatureUnit
            let type: String
            let value: Double?
            let currency: String?
            let text: String

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                unit = try items.decode(TemperatureUnit.self)
                type = try items.decode(String.self)
                if try items.decodeNil() {
                    value = nil
                } else if let number = try? items.decode(Double.self) {
                    value = number
                } else {
                    _ = try items.decode(String.self)
                    value = nil
                }
                currency = try items.decodeIfPresent(String.self)
                text = try items.decode(String.self)
            }
        }

        let rows: [Row]
    }

    struct Texts: Decodable {
        struct NamedDevice: Decodable {
            let id, name: String
        }

        struct Detail: Decodable {
            let currency: String?
        }

        struct Row: Decodable {
            let unit: TemperatureUnit
            let rule: AlertRule
            let device, deviceName, state, title, message, limit: String
            let value: Double?
            let detail: Detail?
        }

        let tz, allDevices: String
        let devices: [NamedDevice]
        let rows: [Row]
    }

    // MARK: events.json

    struct Events: Decodable {
        struct Message: Decodable {
            let type: String
            let event: AlertEvent
            let notify: Bool
            let activeIds: [String]
        }

        struct Step: Decodable {
            let label: String
            let t: Double
            let messages: [Message]
            let active: [ActiveAlert]
            let logIds: [String]
        }

        struct Scenario: Decodable {
            let notifyResolved, desktop: Bool
            let settings: AlertSettings
            let initialLog: [AlertEvent]
            let steps: [Step]
            /// The log at the end, newest first.
            let log: [AlertEvent]
        }

        /// `[type, limit, reading, 1 when the alert cleared]`
        struct Clear: Decodable {
            let type: String
            let threshold, value: Double
            let cleared: Bool

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                type = try items.decode(String.self)
                threshold = try items.decode(Double.self)
                value = try items.decode(Double.self)
                cleared = try items.decode(Int.self) == 1
            }
        }

        let tz: String
        let scenarios: [Scenario]
        let clears: [Clear]
    }
}

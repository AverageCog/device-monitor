import Foundation
import Observation

/// What the user chose on this device: the dashboard's display preferences (`PREF_KEYS` in
/// public/index.html, same values, defaults and validation) plus two things only the app has.
/// Nothing here is a secret.
///
/// Every property can be bound to directly (`@Bindable var preferences`); a value that the
/// dashboard would not accept for a key is ignored rather than stored.
@MainActor
@Observable
public final class Preferences {
    /// Where each preference is kept in `UserDefaults`. The values are the strings the dashboard
    /// keeps in `localStorage`, under its key names with a "dm." prefix.
    public enum Key: String, CaseIterable, Sendable {
        /// "C" or "F".
        case unit = "dm.unit"
        /// "10m", "1h" or "6h": the range of a card nobody chose a range for.
        case range = "dm.range"
        /// A JSON object, device id to range.
        case cardRanges = "dm.cardRanges"
        /// "1h", "6h", "24h", "7d" or "30d".
        case hvRange = "dm.hvRange"
        /// "24h", "7d" or "30d".
        case advRange = "dm.advRange"
        /// "1" when the advanced settings are expanded.
        case setAdvOpen = "dm.setAdvOpen"
        /// A boolean. App only.
        case notifications = "dm.notifications"
        /// App only.
        case alertSeenID = "dm.alertSeenID"
        /// Milliseconds since 1970. App only.
        case alertSeenTime = "dm.alertSeenTime"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private var unit: TemperatureUnit
    private var cardDefault: HistoryRange
    private var cardChoices: [String: String]
    private var history: HistoryRange
    private var advanced: HistoryRange
    private var advancedOpen: Bool
    private var notifications: Bool
    private var seenID: String?
    private var seenTime: Double?

    /// Reads what `defaults` holds. Pass a suite of your own in tests and previews.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let text = { (key: Key) in defaults.string(forKey: key.rawValue) }
        // let unit = store.get('unit') || 'C'; everything compares it with 'F'.
        unit = text(.unit) == TemperatureUnit.fahrenheit.rawValue ? .fahrenheit : .celsius
        // RANGE_MS[store.get('range')] ? store.get('range') : '10m'
        cardDefault = Self.range(text(.range), among: HistoryRange.cardRanges) ?? .tenMinutes
        cardChoices = Self.decodeChoices(text(.cardRanges))
        // store.get('hvRange') || '6h', then: if (!HV_RANGES[hv.range]) hv.range = '6h'
        history = Self.range(text(.hvRange), among: HistoryRange.historyRanges) ?? .sixHours
        // if (!['24h', '7d', '30d'].includes(adv.range)) adv.range = '7d'
        advanced = Self.range(text(.advRange), among: HistoryRange.advancedRanges) ?? .week
        // $('#setAdv').open = store.get('setAdvOpen') === '1'
        advancedOpen = text(.setAdvOpen) == "1"
        notifications = defaults.bool(forKey: Key.notifications.rawValue)
        seenID = text(.alertSeenID)
        seenTime = defaults.object(forKey: Key.alertSeenTime.rawValue) == nil ? nil : defaults.double(forKey: Key.alertSeenTime.rawValue)
    }

    // MARK: Display

    /// Celsius unless the user chose Fahrenheit.
    public var temperatureUnit: TemperatureUnit {
        get { unit }
        set {
            unit = newValue
            defaults.set(newValue.rawValue, forKey: Key.unit.rawValue)
        }
    }

    /// The range of a card whose range was never chosen: ten minutes, unless an older dashboard
    /// left its dashboard-wide setting behind. Only `HistoryRange.cardRanges` are accepted.
    public var defaultCardRange: HistoryRange {
        get { cardDefault }
        set {
            guard HistoryRange.cardRanges.contains(newValue) else { return }
            cardDefault = newValue
            defaults.set(newValue.rawValue, forKey: Key.range.rawValue)
        }
    }

    /// `rangeOf(id)`: the card's own choice when it is a valid one, else the default.
    public func cardRange(for deviceID: String) -> HistoryRange {
        Self.range(cardChoices[deviceID], among: HistoryRange.cardRanges) ?? cardDefault
    }

    /// The first half of `setRange(id, r)`: remembers the choice. A range a card cannot show is
    /// ignored. `HubStore.setRange(_:for:)` does this and reloads the chart.
    public func setCardRange(_ range: HistoryRange, for deviceID: String) {
        guard HistoryRange.cardRanges.contains(range) else { return }
        cardChoices[deviceID] = range.rawValue
        defaults.set(Self.encodeChoices(cardChoices), forKey: Key.cardRanges.rawValue)
    }

    /// The history page's range, six hours by default. Only `HistoryRange.historyRanges` are accepted.
    public var historyRange: HistoryRange {
        get { history }
        set {
            guard HistoryRange.historyRanges.contains(newValue) else { return }
            history = newValue
            defaults.set(newValue.rawValue, forKey: Key.hvRange.rawValue)
        }
    }

    /// The advanced page's range, seven days by default. Only `HistoryRange.advancedRanges` are accepted.
    public var advancedRange: HistoryRange {
        get { advanced }
        set {
            guard HistoryRange.advancedRanges.contains(newValue) else { return }
            advanced = newValue
            defaults.set(newValue.rawValue, forKey: Key.advRange.rawValue)
        }
    }

    /// Whether the "Advanced settings" section of the settings screen is expanded.
    public var isAdvancedSettingsExpanded: Bool {
        get { advancedOpen }
        set {
            advancedOpen = newValue
            defaults.set(newValue ? "1" : "0", forKey: Key.setAdvOpen.rawValue)
        }
    }

    // MARK: App only

    /// Whether the user asked this device to show a notification for hub alerts. Off until they
    /// switch it on; the system's own permission is a separate matter.
    public var notificationsEnabled: Bool {
        get { notifications }
        set {
            notifications = newValue
            defaults.set(newValue, forKey: Key.notifications.rawValue)
        }
    }

    /// The newest alert log entry the user has looked at, and when it happened.
    public var lastSeenAlertID: String? { seenID }
    public var lastSeenAlertTime: Double? { seenTime }

    /// Remembers `event` as seen, unless something newer already is.
    public func markAlertSeen(_ event: AlertEvent) {
        markAlertSeen(id: event.id, time: event.t)
    }

    public func markAlertSeen(id: String, time: Double) {
        if let seenTime, time < seenTime { return }
        seenID = id
        seenTime = time
        defaults.set(id, forKey: Key.alertSeenID.rawValue)
        defaults.set(time, forKey: Key.alertSeenTime.rawValue)
    }

    /// Forgets which alerts were seen and each card's range: what belongs to one hub. Call it
    /// when the app is paired with a different hub. Display choices stay.
    public func forgetHub() {
        seenID = nil
        seenTime = nil
        cardChoices = [:]
        for key in [Key.alertSeenID, .alertSeenTime, .cardRanges] { defaults.removeObject(forKey: key.rawValue) }
    }

    // MARK: Stored forms

    private static func range(_ text: String?, among allowed: [HistoryRange]) -> HistoryRange? {
        guard let range = text.flatMap(HistoryRange.init(rawValue:)), allowed.contains(range) else { return nil }
        return range
    }

    /// `(() => { try { return JSON.parse(store.get('cardRanges')) || {}; } catch { return {}; } })()`.
    /// Entries that are not text are dropped; text that is not a range stays and is ignored when read.
    private static func decodeChoices(_ text: String?) -> [String: String] {
        guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    private static func encodeChoices(_ choices: [String: String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: choices, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

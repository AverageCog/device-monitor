import Foundation

/// What kind of number a rule's limit is.
public enum AlertThresholdUnit: Sendable, Hashable {
    /// The rule has no limit (offline).
    case none
    /// Degrees. The hub stores Celsius whatever unit is shown.
    case temperature
    case percent
    case watts
    /// Money in the currency of the saved electricity price.
    case currency
}

/// One kind of alert rule: what its limit may be and how the hub treats it (`TYPES` in alerts.js,
/// with the handling `validRule`, `evaluate` and `checkCost` give each type).
public struct AlertRuleSpec: Sendable, Hashable, Identifiable {
    /// When a firing alert of this kind is over.
    public enum Clearing: Sendable, Hashable {
        /// Offline: the device reports again.
        case onReport
        /// The value falls this far below the limit, in the limit's unit (the type's `hyst`).
        case below(Double)
        /// The value falls below the limit by this share of it (types without a `hyst`: 5 %).
        case belowFraction(Double)
        /// Daily cost: never during the day; the hub quietly starts over at its local midnight.
        case nextDay
    }

    public let kind: AlertRule.Kind
    /// "CPU temperature", as the hub writes it in alert titles.
    public let label: String
    /// The limits the hub accepts, in its own units (°C for temperatures); nil when there is none.
    public let thresholdRange: ClosedRange<Double>?
    public let unit: AlertThresholdUnit
    public let clearing: Clearing
    /// Whether "for N minutes" means anything: the hub stores minutes for a daily-cost rule but
    /// never looks at them.
    public let usesDuration: Bool
    /// The minutes the hub accepts; an offline rule needs at least one.
    public let minutesRange: ClosedRange<Int>
    /// What a new rule of this kind starts with. The hub's own default rules where it has one
    /// (offline, temperatures, disk); a sensible middle otherwise.
    public let defaultThreshold: Double?
    public let defaultMinutes: Int

    public var id: String { kind.rawValue }

    /// The reading at or below which a firing alert resolves (`value <= r.threshold - hyst` in
    /// evaluate), nil for kinds that clear some other way.
    public func clearsAt(threshold: Double) -> Double? {
        switch clearing {
        case .below(let margin): threshold - margin
        case .belowFraction(let share): threshold - threshold * share
        case .onReport, .nextDay: nil
        }
    }
}

/// The rule types the hub knows, its default rules, and the limits of a rule list.
public enum AlertRuleCatalog {
    /// In the hub's order.
    public static let specs: [AlertRuleSpec] = [
        spec(.offline, .none, .onReport, threshold: nil, minutes: 10),
        spec(.cpuTemp, .temperature, .below(3), threshold: 90, minutes: 2),
        spec(.gpuTemp, .temperature, .below(3), threshold: 85, minutes: 2),
        spec(.cpu, .percent, .below(5), threshold: 95, minutes: 10),
        spec(.gpu, .percent, .below(5), threshold: 95, minutes: 10),
        spec(.mem, .percent, .below(3), threshold: 90, minutes: 5),
        spec(.disk, .percent, .below(1), threshold: 90, minutes: 0),
        // const hyst = TYPES[r.type].hyst ?? r.threshold * 0.05;
        spec(.power, .watts, .belowFraction(0.05), threshold: 500, minutes: 5),
        // checkCost: `if (st?.firing && st.day !== today) this.state.delete(key);   // new day: quietly start over`
        spec(.dailyCost, .currency, .nextDay, threshold: 5, minutes: 0),
    ]

    /// nil for a kind this app does not know (a newer hub's).
    public static func spec(for kind: AlertRule.Kind) -> AlertRuleSpec? {
        specs.first { $0.kind == kind }
    }

    /// The hub keeps the first hundred rules of a list and drops the rest without a word.
    public static let maxRules = AlertSettings.maxRules

    /// The rules a fresh hub starts with (`DEFAULT_RULES`): offline for 10 minutes, CPU above
    /// 90 °C and GPU above 85 °C for 2 minutes, a disk more than 90 % full. All for every device.
    public static func defaultRules(newID: () -> String = AlertRule.newID) -> [AlertRule] {
        [AlertRule.Kind.offline, .cpuTemp, .gpuTemp, .disk].map { newRule($0, id: newID()) }
    }

    /// A rule to start editing from: the kind's default limit and duration, switched on.
    public static func newRule(_ kind: AlertRule.Kind, device: String = AlertRule.allDevices, id: String = AlertRule.newID()) -> AlertRule {
        let spec = spec(for: kind)
        return AlertRule(id: id, type: kind, device: device, threshold: spec?.defaultThreshold, minutes: spec?.defaultMinutes ?? 0, enabled: true)
    }

    private static func spec(
        _ kind: AlertRule.Kind, _ unit: AlertThresholdUnit, _ clearing: AlertRuleSpec.Clearing, threshold: Double?, minutes: Int
    ) -> AlertRuleSpec {
        AlertRuleSpec(
            kind: kind, label: kind.label, thresholdRange: kind.thresholdRange, unit: unit, clearing: clearing,
            usesDuration: kind != .dailyCost, minutesRange: kind.minutesRange, defaultThreshold: threshold, defaultMinutes: minutes
        )
    }
}

/// Showing and editing a rule's limit in the user's unit. The hub stores temperatures in Celsius
/// and writes them in whole degrees of `AlertSettings.tempUnit`; everything else is stored as shown.
public enum AlertThresholds {
    /// The number to show for a stored limit: whole degrees Fahrenheit for a temperature when the
    /// unit is Fahrenheit (as the hub rounds them in its own texts), the stored number otherwise.
    public static func displayValue(_ stored: Double, kind: AlertRule.Kind, unit: TemperatureUnit) -> Double {
        isFahrenheit(kind, unit) ? JS.round(stored * 9 / 5 + 32) : stored
    }

    /// The limit to store for a number the user entered.
    ///
    /// Fahrenheit is converted exactly, so the hub's alert texts show the number that was typed.
    /// Entering the number that is already on screen changes nothing: a limit someone saved as
    /// 90.3 °C shows as 195 °F and stays 90.3 °C when the form is saved untouched.
    public static func storedValue(fromDisplay entered: Double, kind: AlertRule.Kind, unit: TemperatureUnit, current: Double? = nil) -> Double {
        guard isFahrenheit(kind, unit) else { return entered }
        if let current, displayValue(current, kind: kind, unit: unit) == entered { return current }
        return (entered - 32) * 5 / 9
    }

    /// The limits the hub accepts, in the unit shown: 68…302 for a temperature in Fahrenheit.
    public static func displayRange(kind: AlertRule.Kind, unit: TemperatureUnit) -> ClosedRange<Double>? {
        guard let range = kind.thresholdRange else { return nil }
        guard isFahrenheit(kind, unit) else { return range }
        return (range.lowerBound * 9 / 5 + 32)...(range.upperBound * 9 / 5 + 32)
    }

    /// The text of the limit's field (`NumberEntry.text` of the display value), empty without a limit.
    public static func fieldText(_ stored: Double?, kind: AlertRule.Kind, unit: TemperatureUnit, locale: Locale = .current) -> String {
        stored.map { NumberEntry.text(displayValue($0, kind: kind, unit: unit), locale: locale) } ?? ""
    }

    /// What follows the field: "°C", "°F", "%", "W", or the currency code; empty for no limit.
    public static func unitLabel(kind: AlertRule.Kind, unit: TemperatureUnit, currency: String? = nil) -> String {
        switch AlertRuleCatalog.spec(for: kind)?.unit {
        case .temperature: unit.symbol
        case .percent: "%"
        case .watts: "W"
        case .currency: currency ?? ""
        case .some(.none), nil: ""
        }
    }

    private static func isFahrenheit(_ kind: AlertRule.Kind, _ unit: TemperatureUnit) -> Bool {
        unit == .fahrenheit && AlertRuleCatalog.spec(for: kind)?.unit == .temperature
    }
}

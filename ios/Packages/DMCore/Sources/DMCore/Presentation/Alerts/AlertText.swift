import Foundation

/// Alert wording. Readings and limits are written exactly as the hub writes them in its alert
/// titles and messages (`fmt`, `temp` and `nameOf` in alerts.js), so a rule in the app reads like
/// the alert it produces. The hub always writes in US English; so does this.
public enum AlertText {
    /// The hub's locale for numbers and money.
    static let hubLocale = Locale(identifier: "en_US")

    /// What the hub calls a rule for every device.
    public static let allDevices = "All devices"

    // temp(c) { return this.cfg.tempUnit === 'F' ? Math.round(c * 9 / 5 + 32) + '°F' : Math.round(c) + '°C'; }
    public static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        Format.fmtTemp(celsius, unit)
    }

    /// A reading or a limit of a rule kind: "90°C", "194°F", "1.26 kW", "95%", "$2.50". Empty for
    /// no value (function fmt).
    ///
    /// - Parameter currency: the saved electricity price's currency; US dollars are assumed
    ///   without one, as the hub does.
    public static func value(_ kind: AlertRule.Kind, _ value: Double?, unit: TemperatureUnit, currency: String? = nil) -> String {
        guard let value else { return "" }
        switch kind {
        case .cpuTemp, .gpuTemp:
            return temperature(value, unit: unit)
        case .power:
            return Format.fmtW(value)
        case .dailyCost:
            return money(value, currency: currency)
        default:
            return Format.fmtPct(value)
        }
    }

    // new Intl.NumberFormat('en-US', { style: 'currency', currency: detail?.currency || 'USD' }).format(v), or v.toFixed(2)
    private static func money(_ value: Double, currency: String?) -> String {
        let code = (currency ?? "").isEmpty ? "USD" : currency ?? "USD"
        // Intl takes any three letters and throws on everything else.
        let units = Array(code.utf8)
        guard units.count == 3, units.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return JS.toFixed(value, 2) }
        guard value.isFinite else { return JS.toFixed(value, 2) }
        return value.formatted(
            FloatingPointFormatStyle<Double>.Currency(code: code.uppercased(), locale: hubLocale).rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    /// The rule's limit: `value` of its threshold. Empty for an offline rule.
    public static func limit(of rule: AlertRule, unit: TemperatureUnit, currency: String? = nil) -> String {
        value(rule.type, rule.threshold, unit: unit, currency: currency)
    }

    // const dur = r.minutes ? ` for ${r.minutes} min` : '';
    /// " for 2 min", or nothing for an immediate rule.
    public static func duration(minutes: Int) -> String {
        minutes != 0 ? " for \(minutes) min" : ""
    }

    // nameOf(id) { return id === '*' ? 'All devices' : this.devices().find(d => d.id === id)?.name || id; }
    /// The name the hub puts in front of an alert: "All devices", the device's name, or its id
    /// when the device is gone.
    public static func deviceName(_ id: String, devices: [Device]) -> String {
        if id == AlertRule.allDevices { return allDevices }
        guard let name = devices.first(where: { $0.id == id })?.name, !name.isEmpty else { return id }
        return name
    }

    /// What a rule watches for, in the words of the alert it raises: "CPU temperature above 90°C
    /// for 2 min", "Offline for 10 min", "Electricity cost today above $5.00".
    public static func condition(of rule: AlertRule, unit: TemperatureUnit, currency: String? = nil) -> String {
        switch rule.type {
        case .offline:
            return rule.type.label + duration(minutes: rule.minutes)
        case .dailyCost:
            // The hub ignores a daily-cost rule's minutes, and leaves them out of its message too.
            return "\(rule.type.label) above \(limit(of: rule, unit: unit, currency: currency))"
        default:
            return "\(rule.type.label) above \(limit(of: rule, unit: unit, currency: currency))\(duration(minutes: rule.minutes))"
        }
    }

    /// One line for a rule in a list: "CPU temperature above 90°C for 2 min · All devices".
    public static func summary(of rule: AlertRule, devices: [Device], unit: TemperatureUnit, currency: String? = nil) -> String {
        "\(condition(of: rule, unit: unit, currency: currency)) \u{B7} \(deviceName(rule.device, devices: devices))"
    }

    /// When a firing alert of this rule is over: "Clears at 87°C or below.", "Clears when the
    /// device reports again.", "Starts over at midnight."
    public static func clearing(of rule: AlertRule, unit: TemperatureUnit, currency: String? = nil) -> String {
        guard let spec = AlertRuleCatalog.spec(for: rule.type) else { return "" }
        switch spec.clearing {
        case .onReport:
            return "Clears when the device reports again."
        case .nextDay:
            return "Starts over at midnight."
        case .below, .belowFraction:
            guard let threshold = rule.threshold, let level = spec.clearsAt(threshold: threshold) else { return "" }
            return "Clears at \(value(rule.type, level, unit: unit, currency: currency)) or below."
        }
    }

    /// Under a daily-cost rule while the hub has no electricity price: it can never fire.
    public static let needsPrice = "Needs an electricity price. Until one is saved in Settings, this rule never fires."
}

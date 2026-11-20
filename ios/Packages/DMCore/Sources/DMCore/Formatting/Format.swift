import Foundation

/// The dashboard's formatters (public/index.html), ported one for one: same thresholds, rounding
/// and wording, so a number reads the same in the app as in a browser.
///
/// Every function is pure. A JavaScript `null` or `undefined` argument is a Swift `nil`; times are
/// milliseconds since 1970. Locale, time zone and "now" default to the device's.
public enum Format {
    /// What the dashboard shows for a missing value (an en dash).
    public static let dash = "\u{2013}"

    // MARK: Numbers

    // const fmtPct = v => v == null ? '–' : Math.round(v) + '%';
    public static func fmtPct(_ v: Double?) -> String {
        guard let v else { return dash }
        return JS.string(JS.round(v)) + "%"
    }

    // function fmtBytes(b, d = 1): binary units; whole numbers below 1 MB.
    public static func fmtBytes(_ b: Double?, _ d: Int = 1) -> String {
        guard var b, !b.isNaN else { return dash }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        while b >= 1024 && i < units.count - 1 {
            b /= 1024
            i += 1
        }
        return JS.toFixed(b, i < 2 ? 0 : d) + " " + units[i]
    }

    // const fmtRate = b => b == null ? '–' : fmtBytes(b) + '/s';
    public static func fmtRate(_ b: Double?) -> String {
        guard let b else { return dash }
        return fmtBytes(b) + "/s"
    }

    /// "387 / 771 GB": the unit is written once when both sides share it (function memPair).
    public static func memPair(_ used: Double?, _ total: Double?) -> String {
        let t = fmtBytes(total, 0)
        // `used < 1024 ** 3 * 100` with null counting as 0.
        let u = fmtBytes(used, (used ?? 0) < 1024 * 1024 * 1024 * 100 ? 1 : 0)
        let usedParts = u.components(separatedBy: " "), totalParts = t.components(separatedBy: " ")
        let usedUnit = usedParts.count > 1 ? usedParts[1] : nil
        let totalUnit = totalParts.count > 1 ? totalParts[1] : nil
        return usedUnit == totalUnit ? "\(usedParts[0]) / \(t)" : "\(u) / \(t)"
    }

    // MARK: Temperature

    // function fmtTemp(c), with the dashboard's unit setting passed in.
    public static func fmtTemp(_ c: Double?, _ unit: TemperatureUnit) -> String {
        guard let c else { return dash }
        return unit == .fahrenheit
            ? JS.string(JS.round(c * 9 / 5 + 32)) + "\u{B0}F"
            : JS.string(JS.round(c)) + "\u{B0}C"
    }

    // const toF = c => unit === 'F' ? c * 9 / 5 + 32 : c;  (converts chart values; a no-op in Celsius)
    public static func toF(_ c: Double, _ unit: TemperatureUnit) -> Double {
        unit == .fahrenheit ? c * 9 / 5 + 32 : c
    }

    /// How warm a CPU or GPU is. The dashboard pairs these with its good, warning and critical
    /// colours and shows the word next to the reading unless it is "Normal".
    public enum TempStatus: String, Sendable, Hashable, CaseIterable {
        case normal = "Normal"
        case warm = "Warm"
        case hot = "Hot"

        public var label: String { rawValue }
    }

    // function tempStatus(c): below 70 °C normal, below 85 °C warm, otherwise hot.
    public static func tempStatus(_ c: Double?) -> TempStatus? {
        guard let c else { return nil }
        if c < 70 { return .normal }
        if c < 85 { return .warm }
        return .hot
    }

    // MARK: Durations

    // function fmtUptime(s): "3d 2h", "1h 5m", "12m"; empty for no uptime.
    public static func fmtUptime(_ s: Double?) -> String {
        guard let s, JS.isTruthy(s) else { return "" }
        let d = (s / 86400).rounded(.down)
        let h = (s.truncatingRemainder(dividingBy: 86400) / 3600).rounded(.down)
        let m = (s.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)
        if JS.isTruthy(d) { return "\(JS.string(d))d \(JS.string(h))h" }
        if JS.isTruthy(h) { return "\(JS.string(h))h \(JS.string(m))m" }
        return "\(JS.string(m))m"
    }

    // function ago(ms): "42s ago", "5m ago", "3h ago", "2d ago".
    public static func ago(_ ms: Double?, now: Double = Date().hubTime) -> String {
        let s = JS.round((now - (ms ?? 0)) / 1000)
        if s < 60 { return JS.string(s) + "s ago" }
        if s < 3600 { return JS.string(JS.round(s / 60)) + "m ago" }
        if s < 86400 { return JS.string(JS.round(s / 3600)) + "h ago" }
        return JS.string(JS.round(s / 86400)) + "d ago"
    }

    // const hours = m => … in renderAdv: minutes online as "7.5 h", or "12 h" from ten hours up.
    public static func hours(_ m: Double) -> String {
        m >= 600 ? JS.string(JS.round(m / 60)) + " h" : JS.toFixed(m / 60, 1) + " h"
    }

    // MARK: Hardware names

    // const shortCpu = n => (n || '').replace(/\(R\)|\(TM\)|CPU|Processor|@.*$/gi, '').replace(/\s+/g, ' ').trim() || '–';
    public static func shortCpu(_ n: String?) -> String {
        var name = n ?? ""
        name = cpuNoise.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: name.utf16.count), withTemplate: "")
        name = whiteSpaceRun.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: name.utf16.count), withTemplate: " ")
        name = JS.trim(name)
        return name.isEmpty ? dash : name
    }

    // const shortGpu = n => (n || '').replace(/^NVIDIA\s+/i, '').replace(/Workstation Edition/i, '').trim() || '–';
    public static func shortGpu(_ n: String?) -> String {
        var name = n ?? ""
        for pattern in [nvidiaPrefix, workstationEdition] {   // no `g` flag: the first match only
            let ns = name as NSString
            let match = pattern.rangeOfFirstMatch(in: name, range: NSRange(location: 0, length: ns.length))
            if match.location != NSNotFound { name = ns.replacingCharacters(in: match, with: "") }
        }
        name = JS.trim(name)
        return name.isEmpty ? dash : name
    }

    // The patterns spell out what the JavaScript ones mean. ICU's own case-insensitive matching and
    // `\s` are close but not equal: ICU folds the Kelvin sign onto "k" and leaves U+FEFF out of \s.
    private static let jsWhiteSpace = #"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]"#
    private static let cpuNoise = regex(#"\([Rr]\)|\([Tt][Mm]\)|[Cc][Pp][Uu]|[Pp][Rr][Oo][Cc][Ee][Ss][Ss][Oo][Rr]|@[^\n\r\x{2028}\x{2029}]*\z"#)
    private static let whiteSpaceRun = regex(jsWhiteSpace + "+")
    private static let nvidiaPrefix = regex(#"\A[Nn][Vv][Ii][Dd][Ii][Aa]"# + jsWhiteSpace + "+")
    private static let workstationEdition = regex("[Ww][Oo][Rr][Kk][Ss][Tt][Aa][Tt][Ii][Oo][Nn] [Ee][Dd][Ii][Tt][Ii][Oo][Nn]")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, so failing to compile one is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: Power, energy and money

    // const fmtW = w => w == null ? '–' : w >= 1000 ? (w / 1000).toFixed(2) + ' kW' : Math.round(w) + ' W';
    public static func fmtW(_ w: Double?) -> String {
        guard let w else { return dash }
        return w >= 1000 ? JS.toFixed(w / 1000, 2) + " kW" : JS.string(JS.round(w)) + " W"
    }

    // const fmtKwh = k => (k == null ? '–' : k < 10 ? k.toFixed(2) : k < 100 ? k.toFixed(1) : Math.round(k).toLocaleString()) + ' kWh';
    public static func fmtKwh(_ k: Double?, locale: Locale = .current) -> String {
        guard let k else { return dash + " kWh" }
        let number = k < 10 ? JS.toFixed(k, 2) : k < 100 ? JS.toFixed(k, 1) : JS.toLocaleString(JS.round(k), locale: locale)
        return number + " kWh"
    }

    /// An amount in `currency` (function money): two decimals, none from 100 up, unless `frac` says
    /// otherwise. Rounds as `Intl.NumberFormat` does, on the decimal digits, halves away from zero,
    /// so 1.005 is "$1.01" where `toFixed` would say "1.00".
    public static func money(_ v: Double?, _ currency: String, _ frac: Int? = nil, locale: Locale = .current) -> String {
        guard let v, v.isFinite else { return dash }
        let f = frac ?? (abs(v) >= 100 ? 0 : 2)
        // Intl throws on anything but three letters, and the dashboard then falls back to this.
        guard isWellFormedCurrencyCode(currency) else { return JS.toFixed(v, f) + " " + currency }
        return v.formatted(
            FloatingPointFormatStyle<Double>.Currency(code: currency.uppercased(), locale: locale)
                .precision(.fractionLength(f))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    // const fmtKwhPrice = (r, cur) => money(r, cur, r < 1 ? 3 : 2);  (null compares as 0)
    public static func fmtKwhPrice(_ r: Double?, _ currency: String, locale: Locale = .current) -> String {
        money(r, currency, (r ?? 0) < 1 ? 3 : 2, locale: locale)
    }

    private static func isWellFormedCurrencyCode(_ code: String) -> Bool {
        let units = Array(code.utf8)
        return units.count == 3 && units.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    /// An hour of the day for the time-of-use editor (const fmtHour): "noon", "midnight", "4 pm".
    ///
    /// Meant for whole hours, as the dashboard's editor only offers those. A fraction comes out the
    /// way the dashboard prints it, hour fraction and all ("6.5:30 am").
    public static func fmtHour(_ h: Double) -> String {
        if h == 24 { return "midnight" }
        if h == 12 { return "noon" }
        let hour12 = h.truncatingRemainder(dividingBy: 12)
        let part = h.truncatingRemainder(dividingBy: 1)
        let hour = JS.isTruthy(hour12) ? JS.string(hour12) : "12"
        let minutes = JS.isTruthy(part) ? ":" + JS.padStart(JS.string(part * 60), 2, "0") : ""
        return hour + minutes + " " + (h < 12 ? "am" : "pm")
    }

    // MARK: Charts

    // function niceMax(v): the next "nice" axis maximum at or above v (1, 2, 2.5, 5 or 10 × a power of ten).
    public static func niceMax(_ v: Double) -> Double {
        if !(v > 0) { return 1 }
        let p = pow(10, log10(v).rounded(.down)), m = v / p
        return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p
    }

    // const clock = t => new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    public static func clock(_ t: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date = date(t) else { return invalidDate }
        return date.formatted(style(locale, timeZone).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    /// A label on a history chart's time axis (function timeLabel): the time for spans up to 36 h,
    /// the day and time up to 8 days, the day alone beyond.
    public static func timeLabel(_ t: Double, _ span: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        if span <= 36 * 3600e3 { return clock(t, locale: locale, timeZone: timeZone) }
        let day = date(t)?.formatted(style(locale, timeZone).weekday(.abbreviated).month(.abbreviated).day(.defaultDigits)) ?? invalidDate
        return day + (span <= 8 * 86400e3 ? " " + clock(t, locale: locale, timeZone: timeZone) : "")
    }

    /// What follows the time in a history tooltip (drawHvChart): " · 5 min avg", " · 2 h avg", or
    /// nothing while the points are raw samples.
    public static func historyResolutionSuffix(_ resolution: Double) -> String {
        guard resolution > 2500 else { return "" }
        let width = resolution >= 3600e3
            ? JS.string(JS.round(resolution / 3600e3)) + " h"
            : JS.string(JS.round(resolution / 60e3)) + " min"
        return " \u{B7} " + width + " avg"
    }

    /// The time in a history tooltip (drawHvChart): weekday and time, with seconds only while the
    /// points are raw samples. `historyResolutionSuffix` goes right after it.
    public static func historyTooltipTime(_ t: Double, resolution: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date = date(t) else { return invalidDate }
        let base = style(locale, timeZone).weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return date.formatted(resolution <= 2500 ? base.second(.twoDigits) : base)
    }

    /// The time in a device card's chart tooltip (drawChart). On the live ten-minute range it is
    /// relative ("now", "42s ago", "3m 5s ago"); on the longer ranges it is the clock time.
    public static func cardTooltipTime(
        _ t: Double, live: Bool, now: Double = Date().hubTime, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        guard live else { return clock(t, locale: locale, timeZone: timeZone) }
        let secs = JS.round((now - t) / 1000)
        if secs < 5 { return "now" }
        if secs < 60 { return JS.string(secs) + "s ago" }
        return JS.string((secs / 60).rounded(.down)) + "m " + JS.string(secs.truncatingRemainder(dividingBy: 60)) + "s ago"
    }

    /// What JavaScript prints for a date it cannot represent.
    static let invalidDate = "Invalid Date"

    // new Date(t): fractions of a millisecond are dropped; NaN and anything beyond ±8.64e15 is invalid.
    private static func date(_ t: Double) -> Date? {
        guard t.isFinite, abs(t) <= 8.64e15 else { return nil }
        return Date(timeIntervalSince1970: t.rounded(.towardZero) / 1000)
    }

    private static func style(_ locale: Locale, _ timeZone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: locale.calendar, timeZone: timeZone)
    }
}

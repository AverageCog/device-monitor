import Foundation

/// The electricity price the screens work with (function priceSettings in public/index.html): the
/// one saved on the hub, or, until someone saves one, the typical rate of the guessed region.
public struct EnergyPrice: Sendable, Hashable {
    /// A `PriceRegion.code` or `PriceRegions.customCode`.
    public var region: String
    public var currency: String
    /// Price per kWh. With time-of-use periods, the price of every other hour.
    public var rate: Double
    /// Time-of-use periods in the hub's local time; empty for one rate.
    public var tou: [TouPeriod]
    /// True while nothing is saved on the hub and the price is only a guess.
    public var guessed: Bool

    public init(region: String, currency: String, rate: Double, tou: [TouPeriod] = [], guessed: Bool = false) {
        self.region = region
        self.currency = currency
        self.rate = rate
        self.tou = tou
        self.guessed = guessed
    }

    /// function priceSettings. `guessedRegion` comes from `PriceRegions.guess`; a code the table
    /// does not have counts as the US average.
    public init(saved: EnergySettings?, guessedRegion: String) {
        if let saved {
            self.init(region: saved.region, currency: saved.currency, rate: saved.rate, tou: saved.tou, guessed: false)
        } else {
            let region = PriceRegions.region(guessedRegion) ?? PriceRegions.all[0]
            self.init(region: region.code, currency: region.currency, rate: region.rate, guessed: true)
        }
    }

    /// The price for this device: the saved one, else the guess for its time zone and locale.
    public init(saved: EnergySettings?, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.init(saved: saved, guessedRegion: PriceRegions.guess(timeZone: timeZone, locale: locale))
    }

    public var isTimeOfUse: Bool { !tou.isEmpty }

    /// The price as a `PUT /api/energy/settings` body.
    public var settings: EnergySettings {
        EnergySettings(region: region, rate: rate, currency: currency, tou: tou)
    }

    /// The name of `region`, or "your area" for one the table does not list.
    public var regionName: String { PriceRegions.name(for: region) }

    // const dayRate = s => s.rate + (s.tou || []).reduce((a, p) => a + (p.to - p.from) * (p.rate - s.rate), 0) / 24;
    /// The average price over a day, each time-of-use period weighted by its hours.
    public var dayRate: Double {
        rate + tou.reduce(0) { $0 + ($1.to - $1.from) * ($1.rate - rate) } / 24
    }

    /// "$0.316/kWh", or "€0.124–€0.420/kWh by time of day" with time-of-use periods (function fmtPrice).
    public func priceText(locale: Locale = .current) -> String {
        guard isTimeOfUse else { return Format.fmtKwhPrice(rate, currency, locale: locale) + "/kWh" }
        let rates = [rate] + tou.map(\.rate)
        let low = Format.fmtKwhPrice(rates.min(), currency, locale: locale)
        let high = Format.fmtKwhPrice(rates.max(), currency, locale: locale)
        return "\(low)\u{2013}\(high)/kWh by time of day"
    }

    /// Where the price comes from, as a sentence (function priceSource).
    public var source: String {
        if isTimeOfUse { return "Your time-of-use rates." }
        if guessed { return "Typical home rate for \(regionName), guessed from this device's time zone." }
        if region != PriceRegions.customCode, PriceRegions.region(region)?.rate == rate { return "Typical home rate for \(regionName)." }
        return "The rate you entered."
    }

    /// The hint under "Electricity price" in Settings (renderPriceRow).
    public var settingsHint: String {
        if isTimeOfUse { return "Each hour is charged at the rate of its period." }
        return source + (guessed ? " Pick your area, or enter the rate from your bill." : " Enter the rate from your bill for a better estimate.")
    }
}

/// The hub's side of saving a price.
public enum EnergyPricing {
    /// The most time-of-use periods the hub keeps.
    public static let maxPeriods = 12
    /// A rate must be above zero and at most this.
    public static let maxRate = 1000.0

    /// What the hub stores for a `PUT /api/energy/settings` body, or nil when it answers 400
    /// (function validEnergySettings in server.js): rates rounded to four decimals, hours to
    /// quarters, periods sorted by their start.
    public static func hubStored(_ body: EnergySettings) -> EnergySettings? {
        guard isRegionCode(body.region), let rate = storedRate(body.rate), isCurrencyCode(body.currency) else { return nil }
        if body.tou.isEmpty { return EnergySettings(region: body.region, rate: rate, currency: body.currency) }
        guard body.tou.count <= maxPeriods else { return nil }
        var tou: [TouPeriod] = []
        for period in body.tou {
            guard let from = storedHour(period.from), let to = storedHour(period.to), from < to, let periodRate = storedRate(period.rate) else { return nil }
            tou.append(TouPeriod(from: from, to: to, rate: periodRate))
        }
        // Array.prototype.sort is stable; Swift's sort does not promise to be.
        let sorted = tou.enumerated().sorted { $0.element.from != $1.element.from ? $0.element.from < $1.element.from : $0.offset < $1.offset }
        return EnergySettings(region: body.region, rate: rate, currency: body.currency, tou: sorted.map(\.element))
    }

    /// A rate as the hub keeps it, or nil for one it refuses: `Math.round(rate * 1e4) / 1e4`, which
    /// must not come out as zero.
    public static func storedRate(_ rate: Double) -> Double? {
        guard rate > 0, rate <= maxRate else { return nil }
        let rounded = JS.round(rate * 1e4) / 1e4
        return rounded == 0 ? nil : rounded
    }

    /// An hour of the day as the hub keeps it (quarter hours), or nil outside 0...24.
    public static func storedHour(_ hour: Double) -> Double? {
        guard hour >= 0, hour <= 24 else { return nil }
        return JS.round(hour * 4) / 4
    }

    // /^([A-Z]{2}(-[A-Z]{2})?|custom)$/
    static func isRegionCode(_ code: String) -> Bool {
        if code == PriceRegions.customCode { return true }
        let units = Array(code.utf8)
        let capital = { (u: UInt8) in (65...90).contains(u) }
        switch units.count {
        case 2: return units.allSatisfy(capital)
        case 5: return capital(units[0]) && capital(units[1]) && units[2] == UInt8(ascii: "-") && capital(units[3]) && capital(units[4])
        default: return false
        }
    }

    // /^[A-Z]{3}$/
    static func isCurrencyCode(_ code: String) -> Bool {
        let units = Array(code.utf8)
        return units.count == 3 && units.allSatisfy { (65...90).contains($0) }
    }
}

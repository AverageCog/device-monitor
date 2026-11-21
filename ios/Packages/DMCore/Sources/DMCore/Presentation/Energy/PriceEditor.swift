import Foundation

/// The "Electricity price" editor of the dashboard's Settings, as a value: what the controls show
/// and what each action sends to the hub.
///
/// Every action returns the body to `PUT /api/energy/settings`, or nil when there is nothing to
/// send (an invalid entry, a no-op). Nothing changes on screen until the hub has answered, exactly
/// as on the dashboard:
///
///     if let body = editor.setRate(text) {
///         do { editor.hubSaved(try await api.saveEnergySettings(body)) } catch { editor.saveFailed() }
///     }
///
/// Call `hubSaved` as well when an `energySettings` event arrives from another screen.
public struct PriceEditor: Sendable, Equatable {
    /// "One rate" or "Time of use" (the #setPriceMode buttons).
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case flat, timeOfUse

        public var label: String {
            self == .flat ? "One rate" : "Time of use"
        }
    }

    /// Where the keyboard focus is while the hub's answer is applied. The dashboard leaves a field
    /// the user is still in alone, so a value being typed is not replaced under the cursor.
    public enum Focus: Sendable, Hashable {
        case none
        /// The flat rate field.
        case flatRate
        /// Any control of the time-of-use rows.
        case timeOfUse
    }

    /// One row of the time-of-use editor.
    public struct Period: Sendable, Equatable, Identifiable {
        /// Stable while the row is on screen; rows get new ids when they are rebuilt from the hub.
        public let id: Int
        /// Local hours, 0–24.
        public var from: Double
        public var to: Double
        /// The rate as typed.
        public var rateText: String
        /// Set by the last attempt to save: the row needs `from < to` and a rate above 0, at most 1000.
        public var isInvalid: Bool
    }

    /// A choice of an hour picker.
    public struct HourOption: Sendable, Hashable, Identifiable {
        public let hour: Double
        /// "12 am", "noon", "4 pm", "midnight" (`Format.fmtHour`).
        public let label: String

        public var id: Double { hour }
    }

    /// The editor's fixed wording.
    public enum Labels {
        public static let title = "Electricity price"
        public static let perKwh = "per kWh"
        public static let to = "to"
        public static let otherHours = "All other hours"
        public static let addPeriod = "+ Add time period"
        public static let removePeriod = "Remove"
        // Accessibility labels of the controls.
        public static let region = "Where you live"
        public static let currency = "Currency"
        public static let rate = "Price per kWh"
        public static let baseRate = "Price per kWh for all other hours"
        public static let from = "From"
        public static let until = "To"
    }

    /// The price saved on the hub; nil until someone saves one.
    public private(set) var saved: EnergySettings?
    /// The region assumed while nothing is saved (`PriceRegions.guess`).
    public let guessedRegion: String
    /// Decides the decimal separator of the rate fields.
    public let locale: Locale
    /// The periods in force before "One rate" was chosen, so "Time of use" brings them back for as
    /// long as this editor lives. `remember(_:)` carries them over to another editor.
    public private(set) var rememberedPeriods: [TouPeriod]?
    /// Text of the flat rate field.
    public private(set) var rateText: String
    /// The time-of-use rows; empty in flat mode.
    public private(set) var periods: [Period]
    /// Text of the "All other hours" field.
    public private(set) var baseRateText: String
    public private(set) var baseRateIsInvalid: Bool
    private var nextPeriodID = 0

    public init(saved: EnergySettings?, guessedRegion: String, locale: Locale = .current) {
        self.saved = saved
        self.guessedRegion = guessedRegion
        self.locale = locale
        rateText = ""
        periods = []
        baseRateText = ""
        baseRateIsInvalid = false
        render(focus: .none)
    }

    public init(saved: EnergySettings?, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.init(saved: saved, guessedRegion: PriceRegions.guess(timeZone: timeZone, locale: locale), locale: locale)
    }

    // MARK: What the controls show

    /// The price in force: the saved one, else the guess.
    public var price: EnergyPrice { EnergyPrice(saved: saved, guessedRegion: guessedRegion) }

    public var mode: Mode { price.isTimeOfUse ? .timeOfUse : .flat }

    /// The line under the title.
    public var hint: String { price.settingsHint }

    /// The region picker's selection: a `PriceRegion.code` or `PriceRegions.customCode`.
    public var regionCode: String { price.region }

    public var currency: String { price.currency }

    /// The currency picker's choices. The dashboard's list, plus the saved currency when another
    /// client stored one the list does not have (a browser would show a blank picker).
    public var currencyOptions: [String] {
        PriceRegions.currencies.contains(currency) ? PriceRegions.currencies : (PriceRegions.currencies + [currency]).sorted()
    }

    /// False once the hub's limit of twelve periods is reached.
    public var canAddPeriod: Bool { price.tou.count < EnergyPricing.maxPeriods }

    /// The hours a period can start at: 0–23 (renderTou).
    public static let startHours: [HourOption] = (0...23).map { HourOption(hour: Double($0), label: Format.fmtHour(Double($0))) }
    /// The hours a period can end at: 1–24.
    public static let endHours: [HourOption] = (1...24).map { HourOption(hour: Double($0), label: Format.fmtHour(Double($0))) }

    /// `startHours`, plus the row's own start when the hub holds one that is not a whole hour
    /// (another client can save quarter hours; a browser's picker would silently show "12 am").
    public func startHourOptions(for period: Period) -> [HourOption] {
        Self.options(Self.startHours, including: period.from)
    }

    public func endHourOptions(for period: Period) -> [HourOption] {
        Self.options(Self.endHours, including: period.to)
    }

    private static func options(_ list: [HourOption], including hour: Double) -> [HourOption] {
        guard !list.contains(where: { $0.hour == hour }) else { return list }
        return (list + [HourOption(hour: hour, label: hourLabel(hour))]).sorted { $0.hour < $1.hour }
    }

    /// "4 pm", "noon", "midnight" as the dashboard writes whole hours (`Format.fmtHour`), and
    /// "6:15 am" for the quarter hours it has no picker entry for.
    public static func hourLabel(_ hour: Double) -> String {
        let whole = hour.rounded(.down)
        guard hour != whole, hour.isFinite else { return Format.fmtHour(hour) }
        let hour12 = whole.truncatingRemainder(dividingBy: 12)
        let minutes = JS.string(JS.round((hour - whole) * 60))
        return "\(JS.string(hour12 == 0 ? 12 : hour12)):\(JS.padStart(minutes, 2, "0")) \(hour < 12 ? "am" : "pm")"
    }

    // MARK: Actions

    /// The region picker changed (#setRegion). A listed region brings its currency and typical
    /// rate; `PriceRegions.customCode` keeps both. Time-of-use periods stay.
    public mutating func chooseRegion(_ code: String) -> EnergySettings? {
        let s = price
        if code == PriceRegions.customCode {
            return sendable(EnergySettings(region: code, rate: s.rate, currency: s.currency, tou: s.tou))
        }
        guard let region = PriceRegions.region(code) else { return nil }
        return sendable(EnergySettings(region: code, rate: region.rate, currency: region.currency, tou: s.tou))
    }

    /// The flat rate field was committed (#setRate). Anything but a number above 0 and at most 1000
    /// is dropped and the field goes back to the saved rate, unless the user is still in it.
    public mutating func setRate(_ text: String, focus: Focus = .none) -> EnergySettings? {
        let s = price
        rateText = text
        if let value = NumberEntry.parse(text, locale: locale), value > 0, value <= EnergyPricing.maxRate,
           let body = sendable(EnergySettings(region: s.region, rate: value, currency: s.currency, tou: s.tou)) {
            return body
        }
        render(focus: focus)
        return nil
    }

    /// The currency picker changed (#setCurrency): the rate is the user's own from now on.
    public mutating func chooseCurrency(_ code: String) -> EnergySettings? {
        let s = price
        return sendable(EnergySettings(region: PriceRegions.customCode, rate: s.rate, currency: code, tou: s.tou))
    }

    /// One of the mode buttons was pressed (function setPriceMode).
    public mutating func setMode(_ mode: Mode) -> EnergySettings? {
        let s = price
        if (mode == .timeOfUse) == s.isTimeOfUse {
            render(focus: .none)
            return nil
        }
        if mode == .flat {
            rememberedPeriods = s.tou
            return sendable(EnergySettings(region: s.region, rate: s.rate, currency: s.currency))
        }
        let tou = rememberedPeriods.flatMap { $0.isEmpty ? nil : $0 } ?? [TouPeriod(from: 16, to: 21, rate: s.rate)]
        return sendable(EnergySettings(region: s.region, rate: s.rate, currency: s.currency, tou: tou))
    }

    /// Hands this editor the periods another one remembered. The dashboard has a single `lastTou`
    /// for as long as its page is open, however often the settings dialog is. An app that makes
    /// an editor for every screen showing the price keeps `rememberedPeriods` beside them: handed
    /// over before an action and read back after it, all its editors share one memory.
    public mutating func remember(_ periods: [TouPeriod]?) {
        rememberedPeriods = periods
    }

    public mutating func setPeriodStart(at index: Int, hour: Double) -> EnergySettings? {
        guard periods.indices.contains(index) else { return nil }
        periods[index].from = hour
        return saveTou()
    }

    public mutating func setPeriodEnd(at index: Int, hour: Double) -> EnergySettings? {
        guard periods.indices.contains(index) else { return nil }
        periods[index].to = hour
        return saveTou()
    }

    public mutating func setPeriodRate(at index: Int, text: String) -> EnergySettings? {
        guard periods.indices.contains(index) else { return nil }
        periods[index].rateText = text
        return saveTou()
    }

    /// The "All other hours" field was committed.
    public mutating func setBaseRate(_ text: String) -> EnergySettings? {
        baseRateText = text
        return saveTou()
    }

    /// A row's remove button. Removing the last one goes back to one rate.
    public mutating func removePeriod(at index: Int) -> EnergySettings? {
        guard periods.indices.contains(index) else { return nil }
        periods.remove(at: index)
        return saveTou()
    }

    /// "+ Add time period": an hour after the last saved period, or from midnight when that one
    /// runs to the end of the day. Rows that were waiting for a valid entry start over from what
    /// the hub has.
    public mutating func addPeriod() -> EnergySettings? {
        let s = price
        guard canAddPeriod else {
            // The dashboard asks anyway, is refused, and shows the saved rows again.
            renderTou(s.tou, base: s.rate)
            return nil
        }
        let from = s.tou.last.flatMap { $0.to < 24 ? $0.to : nil } ?? 0
        renderTou(s.tou + [TouPeriod(from: from, to: min(24, from + 1), rate: s.rate)], base: s.rate)
        return saveTou()
    }

    // MARK: The hub's answers

    /// The hub stored a price: its answer to a PUT, an `energySettings` event, or the first GET.
    public mutating func hubSaved(_ settings: EnergySettings?, focus: Focus = .none) {
        saved = settings
        render(focus: focus)
    }

    /// A PUT failed: show what the hub still has.
    public mutating func saveFailed(focus: Focus = .none) {
        render(focus: focus)
    }

    // MARK: -

    // function renderPriceRow, the parts that fill in the fields.
    private mutating func render(focus: Focus) {
        let s = price
        if focus != .flatRate { rateText = NumberEntry.text(s.rate, locale: locale) }
        if !s.isTimeOfUse {
            // The dashboard only hides the rows; nothing can reach them until they are rebuilt.
            renderTou([], base: s.rate)
        } else if focus != .timeOfUse || periods.isEmpty {
            // Rows are left alone under the cursor, but never left missing.
            renderTou(s.tou, base: s.rate)
        }
    }

    private mutating func renderTou(_ list: [TouPeriod], base: Double) {
        periods = list.map { period in
            nextPeriodID += 1
            return Period(id: nextPeriodID, from: period.from, to: period.to, rateText: NumberEntry.text(period.rate, locale: locale), isInvalid: false)
        }
        baseRateText = NumberEntry.text(base, locale: locale)
        baseRateIsInvalid = false
    }

    // function saveTou: nothing is saved until every row makes sense.
    private mutating func saveTou() -> EnergySettings? {
        let base = NumberEntry.parse(baseRateText, locale: locale).flatMap { EnergyPricing.storedRate($0) == nil ? nil : $0 }
        baseRateIsInvalid = base == nil
        var tou: [TouPeriod] = []
        for index in periods.indices {
            let row = periods[index]
            let rate = NumberEntry.parse(row.rateText, locale: locale)
            let period = rate.map { TouPeriod(from: row.from, to: row.to, rate: $0) }
            let ok = period.map(Self.hubAccepts) ?? false
            periods[index].isInvalid = !ok
            if ok, let period { tou.append(period) }
        }
        guard tou.count == periods.count, let base else { return nil }
        let s = price
        if tou.isEmpty { return setMode(.flat) }
        return sendable(EnergySettings(region: s.region, rate: base, currency: s.currency, tou: tou))
    }

    /// The dashboard's own check (`p.from < p.to && p.rate > 0 && p.rate <= 1000`), tightened to
    /// what the hub goes on to require after rounding, so a row it would refuse is marked instead
    /// of sent.
    private static func hubAccepts(_ period: TouPeriod) -> Bool {
        guard period.from < period.to, let from = EnergyPricing.storedHour(period.from), let to = EnergyPricing.storedHour(period.to) else { return false }
        return from < to && EnergyPricing.storedRate(period.rate) != nil
    }

    /// The body, unless the hub would answer 400 to it.
    private func sendable(_ body: EnergySettings) -> EnergySettings? {
        EnergyPricing.hubStored(body) == nil ? nil : body
    }
}

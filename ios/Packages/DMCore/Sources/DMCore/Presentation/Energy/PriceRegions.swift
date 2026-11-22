import Foundation

/// A place with a typical household electricity price (one entry of `PRICE_REGIONS` in
/// public/index.html).
public struct PriceRegion: Sendable, Hashable, Identifiable {
    /// "US", "US-CA", "DE": what the hub stores as `EnergySettings.region`.
    public let code: String
    public let name: String
    /// ISO 4217 code of the currency the rate is in.
    public let currency: String
    /// Price per kWh in `currency`.
    public let rate: Double

    public var id: String { code }

    public init(code: String, name: String, currency: String, rate: Double) {
        self.code = code
        self.name = name
        self.currency = currency
        self.rate = rate
    }
}

/// The dashboard's price table and the guess it makes before anyone has saved a price.
public enum PriceRegions {
    /// `EnergySettings.region` of a price that belongs to no listed place.
    public static let customCode = "custom"
    /// What the region picker calls `customCode`.
    public static let customName = "Somewhere else"
    /// Where the guess ends up when nothing better is known.
    public static let fallbackCode = "US"

    /// One `<optgroup>` of the dashboard's region picker.
    public struct Group: Sendable, Hashable, Identifiable {
        public let title: String
        public let regions: [PriceRegion]

        public var id: String { title }
    }

    // PRICE_REGIONS: typical household rates per kWh in local currency, in the dashboard's order.
    public static let all: [PriceRegion] = [
        r("US", "United States (average)", "USD", 0.165), r("US-AL", "Alabama", "USD", 0.152),
        r("US-AK", "Alaska", "USD", 0.249), r("US-AZ", "Arizona", "USD", 0.151), r("US-AR", "Arkansas", "USD", 0.126),
        r("US-CA", "California", "USD", 0.316), r("US-CO", "Colorado", "USD", 0.153), r("US-CT", "Connecticut", "USD", 0.29),
        r("US-DE", "Delaware", "USD", 0.166), r("US-DC", "District of Columbia", "USD", 0.183),
        r("US-FL", "Florida", "USD", 0.15), r("US-GA", "Georgia", "USD", 0.14), r("US-HI", "Hawaii", "USD", 0.415),
        r("US-ID", "Idaho", "USD", 0.114), r("US-IL", "Illinois", "USD", 0.165), r("US-IN", "Indiana", "USD", 0.156),
        r("US-IA", "Iowa", "USD", 0.139), r("US-KS", "Kansas", "USD", 0.142), r("US-KY", "Kentucky", "USD", 0.13),
        r("US-LA", "Louisiana", "USD", 0.122), r("US-ME", "Maine", "USD", 0.27), r("US-MD", "Maryland", "USD", 0.186),
        r("US-MA", "Massachusetts", "USD", 0.303), r("US-MI", "Michigan", "USD", 0.193),
        r("US-MN", "Minnesota", "USD", 0.153), r("US-MS", "Mississippi", "USD", 0.133), r("US-MO", "Missouri", "USD", 0.13),
        r("US-MT", "Montana", "USD", 0.134), r("US-NE", "Nebraska", "USD", 0.12), r("US-NV", "Nevada", "USD", 0.153),
        r("US-NH", "New Hampshire", "USD", 0.245), r("US-NJ", "New Jersey", "USD", 0.194),
        r("US-NM", "New Mexico", "USD", 0.15), r("US-NY", "New York", "USD", 0.25),
        r("US-NC", "North Carolina", "USD", 0.139), r("US-ND", "North Dakota", "USD", 0.119),
        r("US-OH", "Ohio", "USD", 0.161), r("US-OK", "Oklahoma", "USD", 0.13), r("US-OR", "Oregon", "USD", 0.146),
        r("US-PA", "Pennsylvania", "USD", 0.18), r("US-RI", "Rhode Island", "USD", 0.29),
        r("US-SC", "South Carolina", "USD", 0.144), r("US-SD", "South Dakota", "USD", 0.13),
        r("US-TN", "Tennessee", "USD", 0.129), r("US-TX", "Texas", "USD", 0.153), r("US-UT", "Utah", "USD", 0.122),
        r("US-VT", "Vermont", "USD", 0.226), r("US-VA", "Virginia", "USD", 0.149), r("US-WA", "Washington", "USD", 0.126),
        r("US-WV", "West Virginia", "USD", 0.151), r("US-WI", "Wisconsin", "USD", 0.179), r("US-WY", "Wyoming", "USD", 0.133),
        r("CA-AB", "Alberta", "CAD", 0.25), r("CA-BC", "British Columbia", "CAD", 0.12), r("CA-MB", "Manitoba", "CAD", 0.11),
        r("CA-NB", "New Brunswick", "CAD", 0.14), r("CA-NL", "Newfoundland and Labrador", "CAD", 0.15),
        r("CA-NS", "Nova Scotia", "CAD", 0.19), r("CA-ON", "Ontario", "CAD", 0.15),
        r("CA-PE", "Prince Edward Island", "CAD", 0.18), r("CA-QC", "Quebec", "CAD", 0.08),
        r("CA-SK", "Saskatchewan", "CAD", 0.2),
        r("AU", "Australia", "AUD", 0.33), r("AT", "Austria", "EUR", 0.3), r("BE", "Belgium", "EUR", 0.35),
        r("BR", "Brazil", "BRL", 0.85), r("CN", "China", "CNY", 0.55), r("CZ", "Czechia", "CZK", 6.5),
        r("DK", "Denmark", "DKK", 2.6), r("FI", "Finland", "EUR", 0.2), r("FR", "France", "EUR", 0.25),
        r("DE", "Germany", "EUR", 0.39), r("HK", "Hong Kong", "HKD", 1.5), r("IN", "India", "INR", 8),
        r("IE", "Ireland", "EUR", 0.37), r("IL", "Israel", "ILS", 0.65), r("IT", "Italy", "EUR", 0.3),
        r("JP", "Japan", "JPY", 31), r("MX", "Mexico", "MXN", 1.5), r("NL", "Netherlands", "EUR", 0.32),
        r("NZ", "New Zealand", "NZD", 0.35), r("NO", "Norway", "NOK", 1.4), r("PH", "Philippines", "PHP", 12),
        r("PL", "Poland", "PLN", 1), r("PT", "Portugal", "EUR", 0.22), r("SG", "Singapore", "SGD", 0.3),
        r("ZA", "South Africa", "ZAR", 3.5), r("KR", "South Korea", "KRW", 150), r("ES", "Spain", "EUR", 0.24),
        r("SE", "Sweden", "SEK", 2), r("CH", "Switzerland", "CHF", 0.32), r("TW", "Taiwan", "TWD", 3),
        r("AE", "United Arab Emirates", "AED", 0.3), r("GB", "United Kingdom", "GBP", 0.25),
    ]

    // TZ_REGIONS: time zone -> most likely region. Zones shared by many US states are left out, so
    // they fall back to the US average.
    public static let timeZoneRegions: [String: String] = [
        "America/Los_Angeles": "US-CA", "America/Denver": "US-CO", "America/Phoenix": "US-AZ", "America/Boise": "US-ID",
        "America/Detroit": "US-MI", "America/Anchorage": "US-AK", "America/Juneau": "US-AK", "America/Nome": "US-AK",
        "America/Sitka": "US-AK", "Pacific/Honolulu": "US-HI", "America/Toronto": "CA-ON", "America/Vancouver": "CA-BC",
        "America/Edmonton": "CA-AB", "America/Winnipeg": "CA-MB", "America/Regina": "CA-SK", "America/Halifax": "CA-NS",
        "America/Moncton": "CA-NB", "America/St_Johns": "CA-NL", "America/Montreal": "CA-QC", "Europe/London": "GB",
        "Europe/Dublin": "IE", "Europe/Berlin": "DE", "Europe/Paris": "FR", "Europe/Madrid": "ES", "Europe/Rome": "IT",
        "Europe/Amsterdam": "NL", "Europe/Brussels": "BE", "Europe/Vienna": "AT", "Europe/Zurich": "CH",
        "Europe/Lisbon": "PT", "Europe/Warsaw": "PL", "Europe/Prague": "CZ", "Europe/Stockholm": "SE", "Europe/Oslo": "NO",
        "Europe/Copenhagen": "DK", "Europe/Helsinki": "FI", "Pacific/Auckland": "NZ", "Asia/Tokyo": "JP", "Asia/Seoul": "KR",
        "Asia/Singapore": "SG", "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "HK",
        "Asia/Taipei": "TW", "America/Sao_Paulo": "BR", "America/Mexico_City": "MX", "Africa/Johannesburg": "ZA",
        "Asia/Dubai": "AE", "Asia/Jerusalem": "IL", "Asia/Manila": "PH",
    ]

    // guessRegion: zones that name a state or country in their first path components.
    private static let timeZonePrefixes: [(prefix: String, code: String)] = [
        ("America/Indiana/", "US-IN"), ("America/Kentucky/", "US-KY"), ("America/North_Dakota/", "US-ND"), ("Australia/", "AU"),
    ]

    private static let byCode: [String: PriceRegion] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    public static func region(_ code: String) -> PriceRegion? {
        byCode[code]
    }

    // const regionName = code => PRICE_REGIONS[code]?.[0] || 'your area';
    public static func name(for code: String) -> String {
        byCode[code]?.name ?? "your area"
    }

    /// The region picker's sections, in order (renderPriceRow). `customName` follows them as a
    /// lone last entry that selects `customCode`.
    public static let groups: [Group] = [
        Group(title: "United States", regions: all.filter { $0.code.hasPrefix("US") }),
        Group(title: "Canada", regions: all.filter { $0.code.hasPrefix("CA-") }),
        Group(title: "Other countries", regions: all.filter { !$0.code.hasPrefix("US") && !$0.code.hasPrefix("CA-") }),
    ]

    /// The currency picker: every currency of the table plus EUR and USD, sorted (renderPriceRow).
    public static let currencies: [String] = Set(all.map(\.currency) + ["EUR", "USD"]).sorted()

    /// The region whose typical rate is assumed until a price is saved (function guessRegion).
    ///
    /// - Parameters:
    ///   - timeZoneIdentifier: the device's zone, e.g. `TimeZone.current.identifier`.
    ///   - localeRegion: the country of the device's locale ("DE", "us"); only asked when the zone
    ///     says nothing.
    public static func guess(timeZoneIdentifier: String, localeRegion: String?) -> String {
        if let code = timeZoneRegions[timeZoneIdentifier] { return code }
        if let match = timeZonePrefixes.first(where: { timeZoneIdentifier.hasPrefix($0.prefix) }) { return match.code }
        guard let country = localeRegion?.uppercased(), byCode[country] != nil else { return fallbackCode }
        return country
    }

    /// The same guess from a browser-style language tag, read the way the dashboard reads
    /// `navigator.language`: the second dash-separated part is taken for the country, so
    /// "zh-Hant-TW" finds none.
    public static func guess(timeZoneIdentifier: String, languageTag: String?) -> String {
        let parts = (languageTag ?? "").split(separator: "-", omittingEmptySubsequences: false)
        return guess(timeZoneIdentifier: timeZoneIdentifier, localeRegion: parts.count > 1 ? String(parts[1]) : nil)
    }

    /// The guess for this device. Unlike a browser's language tag, a `Locale` knows its region even
    /// when the tag carries a script, so a zh-Hant-TW phone is taken to be in Taiwan.
    public static func guess(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guess(timeZoneIdentifier: timeZone.identifier, localeRegion: locale.region?.identifier)
    }

    private static func r(_ code: String, _ name: String, _ currency: String, _ rate: Double) -> PriceRegion {
        PriceRegion(code: code, name: name, currency: currency, rate: rate)
    }
}

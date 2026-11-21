import Foundation

/// What the Settings tab says about this device, the hub it is paired with and the app itself:
/// the rows of the dashboard's settings dialog that a paired desktop sees (#settingsDlg and
/// openSettings in public/index.html; `dm:settings` and `dm:change-setup` in main.js), worded
/// for a phone or a tablet. Firewall, start at sign-in, updates and quit have no place on iOS.
public struct SettingsOverview: Sendable, Equatable {
    /// The kind of device the app runs on. The wording names it.
    public enum Device: String, Sendable, Hashable, CaseIterable {
        case phone = "iPhone"
        case pad = "iPad"

        public var name: String { rawValue }
    }

    /// The fixed wording of the screen.
    public enum Labels {
        public static let title = "Settings"
        public static let temperatureUnit = "Temperature unit"
        public static let pairedAs = "Paired as"
        public static let exitDemo = "Exit demo"
        public static let disconnect = "Disconnect\u{2026}"
        /// The confirmation's own button.
        public static let confirmDisconnect = "Disconnect"
        public static let cancel = "Cancel"
        public static let disconnecting = "Disconnecting\u{2026}"
        public static let hub = "Hub"
        public static let hostName = "Host name"
        public static let address = "Address"
        public static let electricityPrice = PriceEditor.Labels.title
        public static let changePrice = "Change\u{2026}"
        public static let advanced = "Advanced settings"
        public static let about = "About"
        public static let appName = "Device Monitor"
        public static let license = "License"
        public static let licenseName = "MIT License"
        /// A value the hub has not told yet.
        public static let pending = "\u{2026}"
        public static let retry = "Try again"
    }

    public let device: Device
    /// True in demo mode: nothing is paired and nothing is stored.
    public let isDemo: Bool
    /// The origin the app is enrolled at, or the demo's.
    public let hubOrigin: String?
    /// The label the hub stored for this device at pairing.
    public let pairedName: String?
    /// `GET /api/info`, nil until the hub has answered.
    public let info: HubInfo?
    public let fingerprint: HubFingerprint?
    /// CFBundleShortVersionString and CFBundleVersion.
    public let appVersion: String?
    public let appBuild: String?

    /// - Parameters:
    ///   - hubOrigin: `SessionController.hubOriginText`.
    ///   - pairedName: `SessionController.hub?.name`.
    ///   - info: `HubStore.info`.
    ///   - pin: `SessionController.hubPin`.
    public init(
        device: Device, isDemo: Bool, hubOrigin: String?, pairedName: String? = nil, info: HubInfo? = nil, pin: String? = nil,
        appVersion: String? = nil, appBuild: String? = nil
    ) {
        self.device = device
        self.isDemo = isDemo
        self.hubOrigin = hubOrigin
        self.pairedName = pairedName.flatMap { $0.isEmpty ? nil : $0 }
        self.info = info
        fingerprint = HubFingerprint(pin: pin)
        self.appVersion = appVersion.flatMap { $0.isEmpty ? nil : $0 }
        self.appBuild = appBuild.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: This device

    /// "This iPhone": the dashboard's "This computer".
    public var deviceTitle: String { "This \(device.name)" }

    // $('#setRole').textContent = s.mode === 'host' ? 'Hosting the dashboard for your devices'
    //   : s.mode === 'client' ? `Connected to the hub at ${s.hubUrl}` : 'Not set up';
    /// What this device is to the hub, or what demo mode is.
    public var connection: String {
        if isDemo { return "Running the demo on a hub that exists only in memory. Nothing is stored." }
        guard let hubOrigin else { return "Not set up" }
        return "Connected to the hub at \(hubOrigin)"
    }

    /// "Paired as Jay's iPhone"; nil in demo mode and when the hub stored no label.
    public var pairedAs: String? {
        guard !isDemo, let pairedName else { return nil }
        return "\(Labels.pairedAs) \(pairedName)"
    }

    /// Everything under the row's title.
    public var deviceDetail: String {
        [connection, pairedAs].compactMap { $0 }.joined(separator: "\n")
    }

    /// The button that ends the pairing, or the demo.
    public var leaveLabel: String { isDemo ? Labels.exitDemo : Labels.disconnect }

    /// Leaving the demo loses nothing, so only a real pairing is asked about.
    public var confirmsLeaving: Bool { !isDemo }

    // confirmNative('Disconnect this computer and change setup?')
    public var disconnectQuestion: String { "Disconnect this \(device.name) and change setup?" }

    /// What "Disconnect" does, under the question.
    public var disconnectDetail: String {
        "The hub forgets this \(device.name). To connect again, pair it with a new invitation from the hub."
    }

    // MARK: The hub

    /// `os.hostname()` of the hub, once it has answered.
    public var hostName: String? { info?.hostname.flatMap { $0.isEmpty ? nil : $0 } }

    /// The hub's HTTPS origin as the hub itself states it; until it has answered, the origin the
    /// app is enrolled at.
    public var address: String? { info?.origin.flatMap { $0.isEmpty ? nil : $0 } ?? hubOrigin }

    // MARK: About

    // $('#setVersion').textContent = 'Version ' + s.version;
    /// "Version 1.0.0 (1)".
    public var version: String {
        guard let appVersion else { return "Version unknown" }
        return "Version \(appVersion)" + (appBuild.map { " (\($0))" } ?? "")
    }

    public var companion: String {
        "A companion to the Device Monitor hub. It shows and controls what the hub's dashboard does, and never reports this \(device.name)'s own stats."
    }

    /// The line under "License".
    public static let licenseSummary = "\(Labels.licenseName) \u{B7} \(licenseCopyright)"

    /// The copyright line of the repository's LICENSE.
    public static let licenseCopyright = "Copyright (c) 2026 Matt"

    /// The repository's LICENSE, paragraph by paragraph. The MIT License asks for the notice to go
    /// with every copy of the software, the app included.
    public static let licenseParagraphs: [String] = [
        "MIT License",
        licenseCopyright,
        "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:",
        "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.",
        "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.",
    ]
}

/// The hub's TLS identity as Settings shows it: the enrolled pin (`publicKeyPin` in transport.js,
/// base64 of SHA-256 over the certificate's public key), shortened for a glance and grouped for
/// comparing by eye. The hub's key is public, and so is this.
public struct HubFingerprint: Sendable, Hashable {
    public static let label = "TLS identity"
    public static let hint = "SHA-256 of the hub's public key, pinned when this device was paired."
    public static let show = "Show all"
    public static let hide = "Show less"

    /// The pin as the app keeps it: 44 characters of base64.
    public let pin: String

    /// Nil for anything but a well-formed pin.
    public init?(pin: String?) {
        guard let pin, SPKIPin.isValid(pin) else { return nil }
        self.pin = pin
    }

    /// The first and the last eight characters: "q83vEjRW…Kf0x9dE=".
    public var short: String { "\(pin.prefix(8))\u{2026}\(pin.suffix(8))" }

    /// The whole pin in groups of four characters.
    public var grouped: String {
        var groups: [Substring] = []
        var rest = pin[...]
        while !rest.isEmpty {
            groups.append(rest.prefix(4))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }
}

/// What the electricity price editor says around its controls, where the dashboard says nothing:
/// a browser shows the editor only once the page has loaded, and drops a failed save silently.
public enum PriceEditorNotes {
    public static let loading = "Asking the hub for the electricity price\u{2026}"
    /// Under the title, in place of the hint, until the hub has answered.
    public static let shared = "Saved on the hub and shared by every screen."
    public static let retry = "Try again"
    public static let done = "Done"
    public static let searchRegions = "Search"
    public static let noRegionFound = "No area with that name."
    /// Under rows the last attempt to save marked.
    public static let invalidPeriods = "Nothing is saved until every period ends after it starts and has a price above 0, at most 1000."
    /// Next to the add button once the hub's limit is reached.
    public static let periodLimit = "The hub keeps at most \(EnergyPricing.maxPeriods) time periods."

    public static func loadFailed(_ error: HubError) -> String {
        sentence("Could not load the electricity price.", error)
    }

    public static func saveFailed(_ error: HubError) -> String {
        sentence("Could not save the electricity price.", error)
    }

    /// What the region picker shows as its choice: the place's name, "Somewhere else" for a rate
    /// of the user's own, and the code itself for one another client saved that the table does
    /// not list (a browser's picker would be blank).
    public static func regionLabel(for code: String) -> String {
        code == PriceRegions.customCode ? PriceRegions.customName : PriceRegions.region(code)?.name ?? code
    }

    /// A place's typical rate, next to its name in the list: "$0.316/kWh".
    public static func typicalRate(of region: PriceRegion, locale: Locale = .current) -> String {
        EnergyPrice(region: region.code, currency: region.currency, rate: region.rate).priceText(locale: locale)
    }

    /// The region picker's sections narrowed to the places whose name contains `query`, ignoring
    /// case and accents; sections left without a place are dropped. An empty query keeps all.
    public static func regionGroups(matching query: String, locale: Locale = .current) -> [PriceRegions.Group] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return PriceRegions.groups }
        return PriceRegions.groups.compactMap { group in
            let regions = group.regions.filter {
                $0.name.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            }
            return regions.isEmpty ? nil : PriceRegions.Group(title: group.title, regions: regions)
        }
    }

    /// The price in one line, for a row that only reports it: "$0.316/kWh · Typical home rate
    /// for California." (the Advanced page's price line without its label).
    public static func summary(of price: EnergyPrice, locale: Locale = .current) -> String {
        "\(price.priceText(locale: locale)) \u{B7} \(price.source)"
    }

    /// "4 pm to 9 pm": a period, for the accessibility labels of its controls.
    public static func span(of period: PriceEditor.Period) -> String {
        "\(PriceEditor.hourLabel(period.from)) \(PriceEditor.Labels.to) \(PriceEditor.hourLabel(period.to))"
    }

    /// "Remove 4 pm to 9 pm".
    public static func removeLabel(for period: PriceEditor.Period) -> String {
        "\(PriceEditor.Labels.removePeriod) \(span(of: period))"
    }

    private static func sentence(_ what: String, _ error: HubError) -> String {
        guard let reason = error.errorDescription, !reason.isEmpty else { return what }
        return "\(what) \(reason)"
    }
}

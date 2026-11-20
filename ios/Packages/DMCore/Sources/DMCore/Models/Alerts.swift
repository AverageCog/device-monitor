import Foundation

/// Alert rules and where alerts are delivered (`validSettings` in alerts.js).
///
/// Also the body of `PUT /api/alerts`: what `GET` returned can be edited and sent straight back.
public struct AlertSettings: Codable, Sendable, Hashable {
    /// The hub keeps at most this many rules.
    public static let maxRules = 100

    public var rules: [AlertRule]
    public var channels: AlertChannels
    /// Also announce when an alert clears.
    public var notifyResolved: Bool
    /// The unit temperatures are written in inside alert titles and messages.
    public var tempUnit: TemperatureUnit

    public init(
        rules: [AlertRule] = [], channels: AlertChannels = AlertChannels(), notifyResolved: Bool = true,
        tempUnit: TemperatureUnit = .celsius
    ) {
        self.rules = rules
        self.channels = channels
        self.notifyResolved = notifyResolved
        self.tempUnit = tempUnit
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        rules = c.list(.rules)
        channels = c.optional(.channels) ?? AlertChannels()
        notifyResolved = c.flag(.notifyResolved) ?? true
        tempUnit = c.optional(.tempUnit) ?? .celsius
    }
}

/// One rule (`validRule` in alerts.js): alert when a metric of a device stays above a threshold.
public struct AlertRule: Codable, Sendable, Hashable, Identifiable {
    /// What a rule watches (`TYPES` in alerts.js). A kind this app does not know yet survives a
    /// round trip, so saving settings never deletes a newer hub's rules.
    public enum Kind: Sendable, Hashable, Codable, RawRepresentable, CaseIterable {
        case offline, cpuTemp, gpuTemp, cpu, gpu, mem, disk, power, dailyCost
        case other(String)

        public static let allCases: [Kind] = [.offline, .cpuTemp, .gpuTemp, .cpu, .gpu, .mem, .disk, .power, .dailyCost]

        public init(rawValue: String) {
            self = Kind.allCases.first { $0.rawValue == rawValue } ?? .other(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .offline: "offline"
            case .cpuTemp: "cpuTemp"
            case .gpuTemp: "gpuTemp"
            case .cpu: "cpu"
            case .gpu: "gpu"
            case .mem: "mem"
            case .disk: "disk"
            case .power: "power"
            case .dailyCost: "dailyCost"
            case .other(let raw): raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        /// The hub's name for the metric, as used in alert titles.
        public var label: String {
            switch self {
            case .offline: "Offline"
            case .cpuTemp: "CPU temperature"
            case .gpuTemp: "GPU temperature"
            case .cpu: "CPU load"
            case .gpu: "GPU load"
            case .mem: "Memory use"
            case .disk: "Disk space used"
            case .power: "Power draw"
            case .dailyCost: "Electricity cost today"
            case .other(let raw): raw
            }
        }

        /// The thresholds the hub accepts; nil for a kind that has none (offline) or is unknown.
        /// Temperatures are in degrees Celsius whatever `tempUnit` says.
        public var thresholdRange: ClosedRange<Double>? {
            switch self {
            case .offline, .other: nil
            case .cpuTemp, .gpuTemp: 20...150
            case .cpu, .gpu, .mem, .disk: 1...100
            case .power: 1...100_000
            case .dailyCost: 0.01...10_000_000
            }
        }

        /// How long the condition must hold before the alert fires. An offline rule needs at least
        /// a minute; for the daily cost the hub ignores it.
        public var minutesRange: ClosedRange<Int> {
            self == .offline ? 1...1440 : 0...1440
        }
    }

    /// `device` of a rule that covers every device.
    public static let allDevices = "*"

    /// Twelve lowercase hex digits. The hub keeps an id of that form and replaces any other.
    public var id: String
    public var type: Kind
    /// A device id, or `allDevices`.
    public var device: String
    public var threshold: Double?
    public var minutes: Int
    public var enabled: Bool

    public init(
        id: String = AlertRule.newID(), type: Kind, device: String = AlertRule.allDevices,
        threshold: Double? = nil, minutes: Int = 0, enabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.device = device
        self.threshold = threshold
        self.minutes = minutes
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = c.text(.id) ?? AlertRule.newID()
        type = try c.require(.type)
        device = c.text(.device) ?? AlertRule.allDevices
        threshold = c.number(.threshold)
        minutes = c.integer(.minutes) ?? 0
        enabled = c.flag(.enabled) ?? true
    }

    /// A fresh rule id in the form the hub keeps (`newId` in alerts.js).
    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return String((0..<12).map { _ in digits[Int.random(in: 0..<16, using: &generator)] })
    }

    public var appliesToAllDevices: Bool { device == AlertRule.allDevices }

    /// Whether the hub would accept the rule as it stands (the checks of `validRule`). A kind this
    /// app does not know is left for the hub to judge.
    public var isAcceptable: Bool {
        if case .other = type { return true }
        if let range = type.thresholdRange {
            guard let threshold, threshold.isFinite, range.contains(threshold) else { return false }
        }
        return type.minutesRange.contains(minutes) && (appliesToAllDevices || AlertRule.isDeviceID(device))
    }

    // ID_RE in alerts.js: /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/
    private static func isDeviceID(_ id: String) -> Bool {
        let units = Array(id.utf8)
        guard let first = units.first, units.count <= 64 else { return false }
        let alphanumeric = { (u: UInt8) in (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) }
        return alphanumeric(first) && units.allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 45 }
    }
}

/// Where alerts go besides the hub's event log.
public struct AlertChannels: Codable, Sendable, Hashable {
    /// Push through ntfy (https://ntfy.sh): the phone subscribes to `topic`.
    public struct Ntfy: Codable, Sendable, Hashable {
        public static let defaultServer = "https://ntfy.sh"

        public var enabled: Bool
        public var server: String
        /// 1–64 characters of `A-Z a-z 0-9 _ -`; the hub switches the channel off without one.
        public var topic: String
        /// Optional address ntfy forwards alerts to.
        public var email: String

        public init(enabled: Bool = false, server: String = Ntfy.defaultServer, topic: String = "", email: String = "") {
            self.enabled = enabled
            self.server = server
            self.topic = topic
            self.email = email
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            enabled = c.flag(.enabled) ?? false
            server = c.text(.server) ?? Ntfy.defaultServer
            topic = c.text(.topic) ?? ""
            email = c.text(.email) ?? ""
        }
    }

    /// A chat webhook (Discord, Slack or anything that takes JSON).
    ///
    /// The hub never gives the URL back: it answers `url: ""` with `keepUrl` telling whether one is
    /// stored. Sent back unchanged, the stored URL stays; a new `url` replaces it; an empty `url`
    /// with `keepUrl` off removes it.
    public struct Webhook: Codable, Sendable, Hashable {
        public var enabled: Bool
        public var url: String
        public var keepUrl: Bool

        public init(enabled: Bool = false, url: String = "", keepUrl: Bool = false) {
            self.enabled = enabled
            self.url = url
            self.keepUrl = keepUrl
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, url, keepUrl
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            enabled = c.flag(.enabled) ?? false
            url = c.text(.url) ?? ""
            keepUrl = c.flag(.keepUrl) ?? false
        }

        // validSettings: `hook.url ? httpUrl(hook.url) : hook.keepUrl && prev ? prev.channels.webhook.url : ''`
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            if url.isEmpty && keepUrl {
                try c.encode(true, forKey: .keepUrl)
            } else {
                try c.encode(url, forKey: .url)
            }
        }

        /// Whether the hub has a URL to post to, stored or about to be sent.
        public var hasUrl: Bool { keepUrl || !url.isEmpty }
    }

    /// Whether paired apps should show a notification. The hub puts this in `notify` of each
    /// `alert` event (the name dates from when only the desktop apps listened).
    public var desktop: Bool
    public var ntfy: Ntfy
    public var webhook: Webhook

    public init(desktop: Bool = true, ntfy: Ntfy = Ntfy(), webhook: Webhook = Webhook()) {
        self.desktop = desktop
        self.ntfy = ntfy
        self.webhook = webhook
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        desktop = c.flag(.desktop) ?? true
        ntfy = c.optional(.ntfy) ?? Ntfy()
        webhook = c.optional(.webhook) ?? Webhook()
    }
}

/// An entry of the hub's alert log, also pushed live in `alert` events. The hub writes `title` and
/// `message` itself, in its own language, units and time zone.
public struct AlertEvent: Codable, Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable, Codable, RawRepresentable {
        case firing, resolved
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "firing": self = .firing
            case "resolved": self = .resolved
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .firing: "firing"
            case .resolved: "resolved"
            case .other(let raw): raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    public var id: String
    public var t: Double
    /// A test alert has no rule, type or device.
    public var ruleId: String?
    public var type: AlertRule.Kind?
    /// A device id, or "*" for a rule that sums every device (daily cost).
    public var device: String?
    public var deviceName: String?
    public var state: State
    /// The reading that fired or cleared the alert; nil for offline alerts.
    public var value: Double?
    public var title: String
    public var message: String
    /// Sent by "Send a test alert"; never part of the log.
    public var test: Bool

    public init(
        id: String, t: Double, ruleId: String? = nil, type: AlertRule.Kind? = nil, device: String? = nil,
        deviceName: String? = nil, state: State = .firing, value: Double? = nil, title: String = "",
        message: String = "", test: Bool = false
    ) {
        self.id = id
        self.t = t
        self.ruleId = ruleId
        self.type = type
        self.device = device
        self.deviceName = deviceName
        self.state = state
        self.value = value
        self.title = title
        self.message = message
        self.test = test
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = try c.require(.id)
        t = try c.require(.t)
        ruleId = c.text(.ruleId)
        type = c.optional(.type)
        device = c.text(.device)
        deviceName = c.text(.deviceName)
        state = c.optional(.state) ?? .firing
        value = c.number(.value)
        title = c.text(.title) ?? ""
        message = c.text(.message) ?? ""
        test = c.flag(.test) ?? false
    }

    public var date: Date { Date(hubTime: t) }
    public var isFiring: Bool { state == .firing }
}

/// An alert that is firing right now (`active()` in alerts.js).
public struct ActiveAlert: Codable, Sendable, Hashable, Identifiable {
    public var ruleId: String
    public var type: AlertRule.Kind
    /// A device id, or "*".
    public var device: String
    public var deviceName: String?
    /// When it started firing.
    public var since: Double
    public var value: Double?
    public var threshold: Double?
    public var title: String
    public var message: String

    public init(
        ruleId: String, type: AlertRule.Kind, device: String, deviceName: String? = nil, since: Double,
        value: Double? = nil, threshold: Double? = nil, title: String = "", message: String = ""
    ) {
        self.ruleId = ruleId
        self.type = type
        self.device = device
        self.deviceName = deviceName
        self.since = since
        self.value = value
        self.threshold = threshold
        self.title = title
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        ruleId = try c.require(.ruleId)
        type = try c.require(.type)
        device = try c.require(.device)
        deviceName = c.text(.deviceName)
        since = c.number(.since) ?? 0
        value = c.number(.value)
        threshold = c.number(.threshold)
        title = c.text(.title) ?? ""
        message = c.text(.message) ?? ""
    }

    /// The hub's own key for a firing alert: one per rule and device.
    public var id: String { ruleId + "|" + device }
    public var sinceDate: Date { Date(hubTime: since) }
}

/// `GET /api/alerts`.
public struct AlertsResponse: Codable, Sendable, Equatable {
    public var settings: AlertSettings
    public var active: [ActiveAlert]
    /// The newest 150 log entries, newest first.
    public var events: [AlertEvent]
    /// Whether an electricity price is saved; without one a daily-cost rule can never fire.
    public var priceSet: Bool

    public init(settings: AlertSettings = AlertSettings(), active: [ActiveAlert] = [], events: [AlertEvent] = [], priceSet: Bool = false) {
        self.settings = settings
        self.active = active
        self.events = events
        self.priceSet = priceSet
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        settings = try c.require(.settings)
        active = c.list(.active)
        events = c.list(.events)
        priceSet = c.flag(.priceSet) ?? false
    }
}

/// The answer to `PUT /api/alerts`: the settings as the hub stored them and what is firing under
/// them. An `alerts` event carries the same two fields.
public struct AlertsUpdate: Codable, Sendable, Equatable {
    public var settings: AlertSettings
    public var active: [ActiveAlert]

    public init(settings: AlertSettings, active: [ActiveAlert] = []) {
        self.settings = settings
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        settings = try c.require(.settings)
        active = c.list(.active)
    }
}

/// The answer to `POST /api/alerts/test`: how delivery went on each channel that is switched on.
/// A channel that is off is absent.
public struct AlertTestResult: Codable, Sendable, Hashable {
    public struct Delivery: Codable, Sendable, Hashable {
        public var ok: Bool
        /// "HTTP 404", a network error code, or "Blocked alert destination".
        public var error: String?

        public init(ok: Bool, error: String? = nil) {
            self.ok = ok
            self.error = error
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            ok = c.flag(.ok) ?? false
            error = c.text(.error)
        }
    }

    public var ntfy: Delivery?
    public var webhook: Delivery?

    public init(ntfy: Delivery? = nil, webhook: Delivery? = nil) {
        self.ntfy = ntfy
        self.webhook = webhook
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        ntfy = c.optional(.ntfy)
        webhook = c.optional(.webhook)
    }
}

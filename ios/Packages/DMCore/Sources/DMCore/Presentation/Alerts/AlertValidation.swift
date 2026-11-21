import Foundation

/// Something about alert settings the user should know before they are sent.
public struct AlertIssue: Sendable, Hashable {
    public enum Field: Sendable, Hashable {
        /// The rule list as a whole.
        case rules
        case ruleDevice(ruleID: String)
        case ruleThreshold(ruleID: String)
        case ruleMinutes(ruleID: String)
        case ntfyTopic
        case ntfyEmail
        case ntfyServer
        case webhookURL
    }

    public enum Severity: Sendable, Hashable {
        /// The hub answers 400 and saves nothing.
        case error
        /// The hub saves, but not quite what was asked: a channel without an address stays off.
        case warning
    }

    public let field: Field
    public let severity: Severity
    /// A sentence to show next to the field.
    public let message: String

    public init(field: Field, severity: Severity, message: String) {
        self.field = field
        self.severity = severity
        self.message = message
    }

    /// The rule the issue is about, if it is about one.
    public var ruleID: String? {
        switch field {
        case .ruleDevice(let id), .ruleThreshold(let id), .ruleMinutes(let id): id
        default: nil
        }
    }
}

/// The hub's checks on `PUT /api/alerts` (`validRule` and `validSettings` in alerts.js), run on
/// the phone so a form can say what is wrong before anything is sent.
public enum AlertValidation {
    public static let maxTopicLength = 64
    public static let maxEmailLength = 120

    /// Everything to tell the user about `settings`. Without an `.error` among them the hub
    /// accepts the settings.
    ///
    /// One difference from the hub on purpose: a rule of a kind this app does not know is not
    /// reported. A newer hub may have sent it, and only that hub can judge it.
    ///
    /// - Parameters:
    ///   - unit: the unit limits are shown in, for the messages; the settings' own by default.
    ///   - currency: the saved electricity price's currency, for the messages.
    ///   - hasStoredWebhook: whether the hub holds a webhook URL (`keepUrl` of the settings it
    ///     last sent), which an empty URL field then keeps.
    public static func issues(
        in settings: AlertSettings, unit: TemperatureUnit? = nil, currency: String? = nil, hasStoredWebhook: Bool? = nil
    ) -> [AlertIssue] {
        let unit = unit ?? settings.tempUnit
        var out: [AlertIssue] = []
        if settings.rules.count > AlertRuleCatalog.maxRules {
            out.append(AlertIssue(field: .rules, severity: .warning, message: "The hub keeps the first \(AlertRuleCatalog.maxRules) rules and drops the rest."))
        }
        // b.rules.slice(0, 100).map(validRule): rules past the hundredth are never looked at.
        for rule in settings.rules.prefix(AlertRuleCatalog.maxRules) {
            out += issues(for: rule, unit: unit, currency: currency)
        }

        let ntfy = settings.channels.ntfy
        let topic = cleaned(ntfy.topic, max: maxTopicLength)
        if !topic.isEmpty && !isTopic(topic) {
            out.append(AlertIssue(field: .ntfyTopic, severity: .error, message: "A topic is letters, digits, hyphens and underscores only."))
        } else if topic.isEmpty && ntfy.enabled {
            out.append(AlertIssue(field: .ntfyTopic, severity: .warning, message: "Enter a topic, or ntfy stays off."))
        }
        let email = cleaned(ntfy.email, max: maxEmailLength)
        if !email.isEmpty && !isEmail(email) {
            out.append(AlertIssue(field: .ntfyEmail, severity: .error, message: "That does not look like an email address."))
        }
        if !ntfy.server.isEmpty, let problem = AlertDestination.problem(with: ntfy.server) {
            out.append(AlertIssue(field: .ntfyServer, severity: .error, message: problem.message))
        }

        let hook = settings.channels.webhook
        if !hook.url.isEmpty {
            if let problem = AlertDestination.problem(with: hook.url) {
                out.append(AlertIssue(field: .webhookURL, severity: .error, message: problem.message))
            }
        } else if hook.enabled && !(hook.keepUrl && (hasStoredWebhook ?? true)) {
            out.append(AlertIssue(field: .webhookURL, severity: .warning, message: "Enter a webhook URL, or the webhook stays off."))
        }
        return out
    }

    /// The problems of one rule (function validRule).
    public static func issues(for rule: AlertRule, unit: TemperatureUnit = .celsius, currency: String? = nil) -> [AlertIssue] {
        guard let spec = AlertRuleCatalog.spec(for: rule.type) else { return [] }
        var out: [AlertIssue] = []
        if !(rule.appliesToAllDevices || isDeviceID(rule.device)) {
            out.append(AlertIssue(field: .ruleDevice(ruleID: rule.id), severity: .error, message: "Choose a device, or all devices."))
        }
        if let range = spec.thresholdRange {
            if let threshold = rule.threshold, threshold.isFinite, range.contains(threshold) {
                // fine
            } else {
                let low = AlertText.value(rule.type, range.lowerBound, unit: unit, currency: currency)
                let high = AlertText.value(rule.type, range.upperBound, unit: unit, currency: currency)
                let message = rule.threshold == nil ? "Enter a limit between \(low) and \(high)." : "The limit must be between \(low) and \(high)."
                out.append(AlertIssue(field: .ruleThreshold(ruleID: rule.id), severity: .error, message: message))
            }
        }
        if !spec.minutesRange.contains(rule.minutes) {
            let message = rule.type == .offline && rule.minutes < 1
                ? "An offline alert needs at least 1 minute."
                : "Use \(spec.minutesRange.lowerBound) to \(spec.minutesRange.upperBound) minutes."
            out.append(AlertIssue(field: .ruleMinutes(ruleID: rule.id), severity: .error, message: message))
        }
        return out
    }

    /// Whether the hub would save these settings. A rule of an unknown kind is given the benefit
    /// of the doubt (see `issues(in:)`); today's hub refuses it.
    public static func isAcceptable(_ settings: AlertSettings) -> Bool {
        !issues(in: settings).contains { $0.severity == .error }
    }

    /// True when a rule is of a kind this app does not know.
    public static func hasUnknownKinds(_ settings: AlertSettings) -> Bool {
        settings.rules.prefix(AlertRuleCatalog.maxRules).contains { AlertRuleCatalog.spec(for: $0.type) == nil }
    }

    /// What the hub answers to `PUT /api/alerts` with these settings (function validSettings, then
    /// `settings()`), or nil when it refuses them.
    ///
    /// The answer never contains the webhook URL: `keepUrl` says whether the hub has one. A rule
    /// whose id is not twelve lowercase hex digits gets a new one from `newID`.
    ///
    /// - Parameter hasStoredWebhook: whether the hub already holds a webhook URL.
    public static func hubStored(_ settings: AlertSettings, hasStoredWebhook: Bool, newID: () -> String = AlertRule.newID) -> AlertSettings? {
        var rules: [AlertRule] = []
        for rule in settings.rules.prefix(AlertRuleCatalog.maxRules) {
            guard let spec = AlertRuleCatalog.spec(for: rule.type), issues(for: rule).isEmpty else { return nil }
            rules.append(AlertRule(
                id: isRuleID(rule.id) ? rule.id : newID(), type: rule.type, device: rule.device,
                threshold: spec.thresholdRange == nil ? nil : rule.threshold, minutes: rule.minutes, enabled: rule.enabled
            ))
        }
        let ntfy = settings.channels.ntfy, hook = settings.channels.webhook
        let topic = cleaned(ntfy.topic, max: maxTopicLength), email = cleaned(ntfy.email, max: maxEmailLength)
        guard topic.isEmpty || isTopic(topic), email.isEmpty || isEmail(email) else { return nil }
        // const server = ntfy.server ? httpUrl(ntfy.server) : 'https://ntfy.sh';
        guard let server = ntfy.server.isEmpty ? AlertChannels.Ntfy.defaultServer : AlertDestination.normalized(ntfy.server) else { return nil }
        // const hookUrl = hook.url ? httpUrl(hook.url) : hook.keepUrl && prev ? prev.channels.webhook.url : '';
        let hasHookURL: Bool
        if !hook.url.isEmpty {
            guard AlertDestination.normalized(hook.url) != nil else { return nil }
            hasHookURL = true
        } else {
            hasHookURL = hook.keepUrl && hasStoredWebhook
        }
        return AlertSettings(
            rules: rules,
            channels: AlertChannels(
                desktop: settings.channels.desktop,
                ntfy: AlertChannels.Ntfy(enabled: ntfy.enabled && !topic.isEmpty, server: server, topic: topic, email: email),
                webhook: AlertChannels.Webhook(enabled: hook.enabled && hasHookURL, url: "", keepUrl: hasHookURL)
            ),
            notifyResolved: settings.notifyResolved, tempUnit: settings.tempUnit
        )
    }

    // const clean = (s, max) => s.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, max)
    /// A text field as the hub reads it: control characters removed, trimmed, cut to `max`
    /// UTF-16 units.
    public static func cleaned(_ text: String, max: Int) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value > 0x1f && $0.value != 0x7f }))
        var units = Array(JS.trim(visible).utf16.prefix(max))
        // A cut through a surrogate pair would leave half a character behind.
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    // /^[A-Za-z0-9_-]{1,64}$/
    static func isTopic(_ topic: String) -> Bool {
        let units = Array(topic.utf8)
        return (1...maxTopicLength).contains(units.count) && units.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    // /^[^@\s]+@[^@\s]+\.[^@\s]+$/
    static func isEmail(_ email: String) -> Bool {
        let scalars = Array(email.unicodeScalars)
        guard !scalars.contains(where: JS.isWhiteSpace), scalars.filter({ $0 == "@" }).count == 1,
              let at = scalars.firstIndex(of: "@"), at > 0 else { return false }
        let domain = scalars[(at + 1)...]
        // A dot with something on both sides of it.
        return domain.indices.contains { domain[$0] == "." && $0 > domain.startIndex && $0 < domain.endIndex - 1 }
    }

    // ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/
    static func isDeviceID(_ id: String) -> Bool {
        let units = Array(id.utf8)
        guard let first = units.first, units.count <= 64, isAlphanumeric(first) else { return false }
        return units.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "-") }
    }

    // /^[a-f0-9]{12}$/
    static func isRuleID(_ id: String) -> Bool {
        let units = Array(id.utf8)
        return units.count == 12 && units.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isAlphanumeric(_ unit: UInt8) -> Bool {
        (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
    }
}

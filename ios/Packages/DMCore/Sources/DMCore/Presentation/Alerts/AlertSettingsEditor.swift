import Foundation

/// Alert settings being edited: the rules and channels the hub last sent, a working copy, and
/// the changes a settings screen can make to it. Nothing here talks to the hub.
///
///     var editor = AlertSettingsEditor(settings: response.settings)
///     editor.setThreshold(of: id, toDisplayed: 195, unit: .fahrenheit)
///     if let body = editor.body { editor.hubSaved(try await api.saveAlerts(body).settings) }
///
/// Limits are kept as the hub keeps them (temperatures in Celsius); `AlertThresholds` turns them
/// into what a field shows.
public struct AlertSettingsEditor: Sendable, Equatable {
    /// What the hub has, as it last told us.
    public private(set) var saved: AlertSettings
    /// The working copy.
    public private(set) var settings: AlertSettings

    public init(settings: AlertSettings) {
        saved = settings
        self.settings = settings
    }

    // MARK: State

    /// True when the working copy differs from what the hub has.
    public var isDirty: Bool { settings != saved }

    /// Whether the hub holds a webhook URL (it never sends the URL itself back).
    public var hasStoredWebhook: Bool { saved.channels.webhook.keepUrl }

    /// False once the hub's limit of a hundred rules is reached.
    public var canAddRule: Bool { settings.rules.count < AlertRuleCatalog.maxRules }

    /// What to tell the user about the working copy. See `AlertValidation.issues(in:)`.
    public func issues(unit: TemperatureUnit? = nil, currency: String? = nil) -> [AlertIssue] {
        AlertValidation.issues(in: settings, unit: unit, currency: currency, hasStoredWebhook: hasStoredWebhook)
    }

    /// The issues of one rule.
    public func issues(forRule id: String, unit: TemperatureUnit? = nil, currency: String? = nil) -> [AlertIssue] {
        issues(unit: unit, currency: currency).filter { $0.ruleID == id }
    }

    /// True when the hub would refuse the working copy.
    public var hasErrors: Bool { issues().contains { $0.severity == .error } }

    /// Whether there is something to save and nothing in its way.
    public var canSave: Bool { isDirty && !hasErrors }

    /// The body for `PUT /api/alerts`, or nil while the hub would refuse it.
    public var body: AlertSettings? { hasErrors ? nil : settings }

    public func rule(_ id: String) -> AlertRule? {
        settings.rules.first { $0.id == id }
    }

    // MARK: Rules

    /// Adds a rule of `kind` with that kind's default limit and duration, and returns it. Nil
    /// when the list is full.
    @discardableResult
    public mutating func addRule(_ kind: AlertRule.Kind, device: String = AlertRule.allDevices, id: String = AlertRule.newID()) -> AlertRule? {
        guard canAddRule else { return nil }
        // The hub does not mind two rules sharing an id, but a list on screen does.
        var id = id
        while settings.rules.contains(where: { $0.id == id }) { id = AlertRule.newID() }
        let rule = AlertRuleCatalog.newRule(kind, device: device, id: id)
        settings.rules.append(rule)
        return rule
    }

    /// Changes a rule in place. The id stays.
    public mutating func updateRule(_ id: String, _ change: (inout AlertRule) -> Void) {
        guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = settings.rules[index]
        change(&rule)
        rule.id = id
        settings.rules[index] = rule
    }

    /// Changes what a rule watches. The limit and duration start over at the new kind's defaults,
    /// since a limit of 90 means something else for every kind.
    public mutating func setKind(of id: String, to kind: AlertRule.Kind) {
        updateRule(id) { rule in
            guard rule.type != kind else { return }
            let fresh = AlertRuleCatalog.newRule(kind, device: rule.device, id: rule.id)
            rule.type = kind
            rule.threshold = fresh.threshold
            rule.minutes = fresh.minutes
        }
    }

    /// `AlertRule.allDevices` or a device id.
    public mutating func setDevice(of id: String, to device: String) {
        updateRule(id) { $0.device = device }
    }

    /// Sets the limit from the number in the field, given in the unit the field shows. Nil (an
    /// empty or unreadable field) leaves the rule without a limit, which `issues` reports.
    public mutating func setThreshold(of id: String, toDisplayed entered: Double?, unit: TemperatureUnit) {
        updateRule(id) { rule in
            rule.threshold = entered.map { AlertThresholds.storedValue(fromDisplay: $0, kind: rule.type, unit: unit, current: rule.threshold) }
        }
    }

    /// Sets the limit from the field's text (`NumberEntry.parse`).
    public mutating func setThreshold(of id: String, toText text: String, unit: TemperatureUnit, locale: Locale = .current) {
        setThreshold(of: id, toDisplayed: NumberEntry.parse(text, locale: locale), unit: unit)
    }

    public mutating func setMinutes(of id: String, to minutes: Int) {
        updateRule(id) { $0.minutes = minutes }
    }

    public mutating func setEnabled(_ enabled: Bool, for id: String) {
        updateRule(id) { $0.enabled = enabled }
    }

    public mutating func toggleRule(_ id: String) {
        updateRule(id) { $0.enabled.toggle() }
    }

    public mutating func deleteRule(_ id: String) {
        settings.rules.removeAll { $0.id == id }
    }

    /// Replaces every rule with the hub's defaults.
    public mutating func restoreDefaultRules() {
        settings.rules = AlertRuleCatalog.defaultRules()
    }

    // MARK: Channels

    /// Whether paired apps (this one included) show a notification.
    public mutating func setAppNotifications(_ enabled: Bool) {
        settings.channels.desktop = enabled
    }

    /// Whether an alert that clears is announced too.
    public mutating func setNotifyResolved(_ enabled: Bool) {
        settings.notifyResolved = enabled
    }

    /// The unit the hub writes temperatures in inside alert titles and messages.
    public mutating func setTemperatureUnit(_ unit: TemperatureUnit) {
        settings.tempUnit = unit
    }

    public mutating func setNtfyEnabled(_ enabled: Bool) {
        settings.channels.ntfy.enabled = enabled
    }

    public mutating func setNtfyTopic(_ topic: String) {
        settings.channels.ntfy.topic = topic
    }

    /// Empty means the public server, https://ntfy.sh.
    public mutating func setNtfyServer(_ server: String) {
        settings.channels.ntfy.server = server
    }

    public mutating func setNtfyEmail(_ email: String) {
        settings.channels.ntfy.email = email
    }

    public mutating func setWebhookEnabled(_ enabled: Bool) {
        settings.channels.webhook.enabled = enabled
    }

    /// The webhook URL field. A new URL replaces the stored one; an empty field keeps it (the
    /// hub never shows a stored URL, so the field starts out empty).
    public mutating func setWebhookURL(_ url: String) {
        settings.channels.webhook.url = url
        if url.isEmpty { settings.channels.webhook.keepUrl = hasStoredWebhook }
    }

    /// Forgets the stored webhook URL, which also switches the webhook off.
    public mutating func removeWebhookURL() {
        settings.channels.webhook.url = ""
        settings.channels.webhook.keepUrl = false
    }

    /// What the URL field shows while empty.
    public var webhookPlaceholder: String {
        settings.channels.webhook.keepUrl && hasStoredWebhook ? "Saved. Enter a new URL to replace it." : "https://\u{2026}"
    }

    // MARK: The hub

    /// The hub stored settings: its answer to the PUT. The working copy starts over from them.
    public mutating func hubSaved(_ stored: AlertSettings) {
        saved = stored
        settings = stored
    }

    /// Settings arrived from elsewhere (an `alerts` event, a refresh). Unsaved edits are kept;
    /// an untouched form follows the hub.
    public mutating func hubChanged(_ current: AlertSettings) {
        let untouched = !isDirty
        saved = current
        if untouched { settings = current }
    }

    /// Throws the edits away.
    public mutating func revert() {
        settings = saved
    }
}

import Foundation

/// The demo hub's alerts: a port of the `Alerts` class in alerts.js, minus delivery to ntfy and
/// webhooks and minus the daily-cost rule, which the demo never evaluates.
struct DemoAlerts: Sendable {
    /// What the hub knows about a device when it writes about it.
    struct Subject: Sendable {
        var id: String
        var name: String
        var online: Bool
        var lastSeen: Double?
    }

    /// Details that go into an alert's wording.
    struct Detail: Sendable, Equatable {
        var since: Double?
        var disk: String?
        var free: Double?
    }

    private struct Key: Hashable, Sendable {
        var rule: String
        var device: String
    }

    /// `{ since, firing, firedAt, value, detail }`
    private struct Tracking: Sendable {
        var since: Double?
        var firing = false
        var firedAt: Double = 0
        var value: Double?
        var detail = Detail()
    }

    /// What `broadcast({ type: 'alert', … })` sends.
    struct Emission: Sendable {
        var event: AlertEvent
        var notify: Bool
    }

    static let maxLog = 300
    private static let english = Locale(identifier: "en_US")

    /// The settings as stored, webhook address included.
    private(set) var stored: AlertSettings
    private var tracking: [Key: Tracking] = [:]
    /// Oldest first, as the hub keeps them.
    private(set) var log: [AlertEvent] = []
    private var issued: UInt64 = 0
    private let seed: UInt64
    private let timeZone: TimeZone

    init(seed: UInt64, timeZone: TimeZone) {
        self.seed = seed
        self.timeZone = timeZone
        stored = AlertSettings()
        // DEFAULT_RULES in alerts.js.
        stored.rules = [
            AlertRule(id: newID(), type: .offline, device: AlertRule.allDevices, threshold: nil, minutes: 10),
            AlertRule(id: newID(), type: .cpuTemp, device: AlertRule.allDevices, threshold: 90, minutes: 2),
            AlertRule(id: newID(), type: .gpuTemp, device: AlertRule.allDevices, threshold: 85, minutes: 2),
            AlertRule(id: newID(), type: .disk, device: AlertRule.allDevices, threshold: 90, minutes: 0),
        ]
    }

    /// Twelve hex digits like `newId()`, but the same ones on every run with the same seed.
    private mutating func newID() -> String {
        issued += 1
        var x = (seed ^ 0xA1E2_75C3_D4B5_F607) &+ issued &* 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        let text = String((x ^ (x >> 31)) & 0xFFFF_FFFF_FFFF, radix: 16)
        return String(repeating: "0", count: 12 - text.count) + text
    }

    // MARK: What the API answers

    /// `settings()`: the hub never gives the webhook address back.
    var settings: AlertSettings {
        var shown = stored
        shown.channels.webhook = AlertChannels.Webhook(enabled: stored.channels.webhook.enabled, url: "", keepUrl: !stored.channels.webhook.url.isEmpty)
        return shown
    }

    /// `active()`: everything firing, most recent first.
    func active(_ subjects: [Subject]) -> [ActiveAlert] {
        tracking.compactMap { key, state -> ActiveAlert? in
            guard state.firing, let rule = stored.rules.first(where: { $0.id == key.rule }) else { return nil }
            let name = Self.name(of: key.device, subjects)
            let words = text(rule, name: name, firing: true, value: state.value, detail: state.detail, now: state.firedAt)
            return ActiveAlert(
                ruleId: key.rule, type: rule.type, device: key.device, deviceName: name, since: state.firedAt, value: state.value,
                threshold: rule.threshold, title: words.title, message: words.message)
        }
        .sorted { ($1.since, $0.id) < ($0.since, $1.id) }
    }

    /// The log as `GET /api/alerts` answers it: `alerts.events.slice(-150).reverse()`.
    var recentEvents: [AlertEvent] { Array(log.suffix(AlertsState.maxEvents).reversed()) }

    // MARK: Past and staged

    /// Puts an alert into the firing state as if it had fired at `firedAt`, and logs it.
    mutating func seedFiring(rule type: AlertRule.Kind, device: Subject, firedAt: Double, value: Double?, detail: Detail) {
        guard let rule = stored.rules.first(where: { $0.type == type }) else { return }
        tracking[Key(rule: rule.id, device: device.id)] = Tracking(since: detail.since ?? firedAt, firing: true, firedAt: firedAt, value: value, detail: detail)
        record(rule, device: device, firing: true, value: value, detail: detail, at: firedAt)
    }

    /// Logs something that fired or cleared in the past without leaving it firing.
    mutating func seedPast(rule type: AlertRule.Kind, device: Subject, firing: Bool, at t: Double, value: Double?, detail: Detail = Detail()) {
        guard let rule = stored.rules.first(where: { $0.type == type }) else { return }
        record(rule, device: device, firing: firing, value: value, detail: detail, at: t)
    }

    @discardableResult
    private mutating func record(_ rule: AlertRule, device: Subject, firing: Bool, value: Double?, detail: Detail, at t: Double) -> AlertEvent {
        let words = text(rule, name: device.name, firing: firing, value: value, detail: detail, now: t)
        let event = AlertEvent(
            id: newID(), t: t, ruleId: rule.id, type: rule.type, device: device.id, deviceName: device.name,
            state: firing ? .firing : .resolved, value: value, title: words.title, message: words.message)
        log.append(event)
        log.sort { $0.t < $1.t }
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
        return event
    }

    // MARK: Evaluation

    /// `emit`: logs the event and says whether apps should announce it.
    private mutating func emit(_ rule: AlertRule, device: Subject, firing: Bool, value: Double?, detail: Detail, now: Double) -> Emission {
        let event = record(rule, device: device, firing: firing, value: value, detail: detail, at: now)
        return Emission(event: event, notify: (firing || stored.notifyResolved) && stored.channels.desktop)
    }

    /// `onReport(id, body)`.
    mutating func onReport(_ report: Report, from device: Subject, now: Double) -> [Emission] {
        var out: [Emission] = []
        for rule in stored.rules where rule.enabled && (rule.appliesToAllDevices || rule.device == device.id) {
            let key = Key(rule: rule.id, device: device.id)
            if rule.type == .offline {
                // resolveOffline
                if let state = tracking[key], state.firing {
                    tracking[key] = nil
                    out.append(emit(rule, device: device, firing: false, value: nil, detail: Detail(since: state.since), now: now))
                }
                continue
            }
            guard let threshold = rule.threshold, let (value, detail) = Self.metric(rule.type, report) else { continue }
            // evaluate
            var state = tracking[key] ?? Tracking()
            let hysteresis = Self.hysteresis(rule.type) ?? threshold * 0.05
            if value > threshold {
                state.since = state.since ?? now
                if !state.firing, now - (state.since ?? now) >= Double(rule.minutes) * 60e3 {
                    state.firing = true
                    state.firedAt = now
                    state.value = value
                    state.detail = detail
                    tracking[key] = state
                    out.append(emit(rule, device: device, firing: true, value: value, detail: detail, now: now))
                    continue
                }
                if state.firing {
                    state.value = value
                    state.detail = detail
                }
            } else if state.firing, value <= threshold - hysteresis {
                tracking[key] = nil
                out.append(emit(rule, device: device, firing: false, value: value, detail: detail, now: now))
                continue
            } else if !state.firing {
                state.since = nil
            }
            tracking[key] = state
        }
        return out
    }

    /// `tick()`: devices that have been silent for as long as an offline rule allows.
    mutating func tick(_ subjects: [Subject], now: Double) -> [Emission] {
        var out: [Emission] = []
        for rule in stored.rules where rule.enabled && rule.type == .offline {
            for device in subjects where rule.appliesToAllDevices || rule.device == device.id {
                let key = Key(rule: rule.id, device: device.id)
                guard !device.online, let lastSeen = device.lastSeen, tracking[key]?.firing != true else { continue }
                if now - lastSeen >= Double(rule.minutes) * 60e3 {
                    tracking[key] = Tracking(since: lastSeen, firing: true, firedAt: now)
                    out.append(emit(rule, device: device, firing: true, value: nil, detail: Detail(since: lastSeen), now: now))
                }
            }
        }
        return out
    }

    /// `removeDevice(id)`.
    mutating func removeDevice(_ id: String) {
        tracking = tracking.filter { $0.key.device != id }
    }

    mutating func clearLog() {
        log = []
    }

    /// `test()`: an event that is announced but not logged.
    mutating func test(now: Double) -> Emission {
        let event = AlertEvent(
            id: newID(), t: now, state: .firing, title: "Device Monitor test alert", message: "Alerts from your hub will arrive like this.",
            test: true)
        return Emission(event: event, notify: stored.channels.desktop)
    }

    // MARK: Saving

    /// `update(input)`: nil when the hub would answer "invalid alert settings".
    mutating func update(_ input: AlertSettings) -> AlertSettings? {
        guard let accepted = validated(input) else { return nil }
        let comparable = { (rule: AlertRule) -> AlertRule in
            var rule = rule
            rule.enabled = true
            return rule
        }
        let before = Dictionary(stored.rules.map { ($0.id, comparable($0)) }, uniquingKeysWith: { first, _ in first })
        stored = accepted
        // Forget state for rules that were removed, changed or switched off.
        tracking = tracking.filter { key, _ in
            guard let rule = accepted.rules.first(where: { $0.id == key.rule }), rule.enabled else { return false }
            return before[key.rule] == comparable(rule)
        }
        return settings
    }

    /// `validSettings(b, prev)`.
    private mutating func validated(_ input: AlertSettings) -> AlertSettings? {
        var rules: [AlertRule] = []
        for rule in input.rules.prefix(AlertSettings.maxRules) {
            // validRule: a known type, an acceptable device, threshold and duration.
            if case .other = rule.type { return nil }
            guard rule.isAcceptable else { return nil }
            var kept = rule
            if rule.type.thresholdRange == nil { kept.threshold = nil }
            if !Self.isRuleID(rule.id) { kept.id = newID() }
            rules.append(kept)
        }
        let topic = Self.clean(input.channels.ntfy.topic, 64)
        guard topic.isEmpty || topic.utf8.allSatisfy(Self.isTopicCharacter) else { return nil }
        let email = Self.clean(input.channels.ntfy.email, 120)
        guard email.isEmpty || Self.isEmail(email) else { return nil }
        let server = input.channels.ntfy.server.isEmpty ? AlertChannels.Ntfy.defaultServer : Self.httpURL(input.channels.ntfy.server)
        let hook = input.channels.webhook
        let hookURL = !hook.url.isEmpty ? Self.httpURL(hook.url) : hook.keepUrl ? stored.channels.webhook.url : ""
        guard let server, let hookURL else { return nil }
        return AlertSettings(
            rules: rules,
            channels: AlertChannels(
                desktop: input.channels.desktop,
                ntfy: AlertChannels.Ntfy(enabled: input.channels.ntfy.enabled && !topic.isEmpty, server: server, topic: topic, email: email),
                webhook: AlertChannels.Webhook(enabled: hook.enabled && !hookURL.isEmpty, url: hookURL)),
            notifyResolved: input.notifyResolved, tempUnit: input.tempUnit)
    }

    private static func isRuleID(_ id: String) -> Bool {
        id.utf8.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isTopicCharacter(_ unit: UInt8) -> Bool {
        (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 45
    }

    /// `/^[^@\s]+@[^@\s]+\.[^@\s]+$/`
    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        // A dot somewhere inside the domain, with something on both sides.
        let domain = Array(parts[1])
        return domain.indices.contains { $0 > 0 && $0 < domain.count - 1 && domain[$0] == "." }
    }

    /// `clean(s, max)`
    private static func clean(_ text: String, _ limit: Int) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
        var out = JS.trim(String(kept))
        while out.utf16.count > limit { out.unicodeScalars.removeLast() }
        return out
    }

    /// `httpUrl(s)`: an http(s) address without credentials that is not this machine. The real hub
    /// also refuses loopback and link-local addresses however they are written.
    private static func httpURL(_ text: String) -> String? {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || host.hasPrefix("127.") || host.hasPrefix("169.254.") || host.hasPrefix("0.") {
            return nil
        }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    // MARK: Wording

    private static func name(of id: String, _ subjects: [Subject]) -> String {
        id == AlertRule.allDevices ? "All devices" : subjects.first { $0.id == id }?.name ?? id
    }

    /// `hyst` in TYPES; nil means five percent of the threshold.
    private static func hysteresis(_ type: AlertRule.Kind) -> Double? {
        switch type {
        case .cpuTemp, .gpuTemp, .mem: 3
        case .cpu, .gpu: 5
        case .disk: 1
        default: nil
        }
    }

    /// `metric(type, b)`: the current value in a report, plus details for the message.
    private static func metric(_ type: AlertRule.Kind, _ report: Report) -> (Double, Detail)? {
        let plain = { (value: Double?) in value.map { ($0, Detail()) } }
        switch type {
        case .cpuTemp: return plain(report.cpu.temp)
        case .gpuTemp: return plain(report.gpus.compactMap(\.temp).max())
        case .cpu: return plain(report.cpu.usage)
        case .gpu: return plain(report.gpus.compactMap(\.usage).max())
        case .mem:
            guard let total = report.memory.total, total > 0, let used = report.memory.used else { return nil }
            return (used / total * 100, Detail())
        case .power: return plain(report.powerEst?.watts)
        case .disk:
            var worst: (percent: Double, disk: Report.Disk)?
            for disk in report.disks {
                guard let total = disk.total, total > 1e9, let used = disk.used else { continue }
                let percent = used / total * 100
                if worst == nil || percent > worst!.percent { worst = (percent, disk) }
            }
            return worst.map { ($0.percent, Detail(disk: $0.disk.name, free: ($0.disk.total ?? 0) - ($0.disk.used ?? 0))) }
        default: return nil
        }
    }

    /// `fmt(type, v, detail)`
    private func format(_ type: AlertRule.Kind, _ value: Double?) -> String {
        guard let value else { return "" }
        switch type {
        case .cpuTemp, .gpuTemp: return Format.fmtTemp(value, stored.tempUnit)
        case .power: return Format.fmtW(value)
        default: return JS.string(JS.round(value)) + "%"
        }
    }

    /// `text(r, id, state, value, detail)`
    private func text(_ rule: AlertRule, name: String, firing: Bool, value: Double?, detail: Detail, now: Double) -> (title: String, message: String) {
        let limit = format(rule.type, rule.threshold)
        let clock = { (t: Double) in Format.clock(t, locale: Self.english, timeZone: timeZone) }
        switch rule.type {
        case .offline:
            if firing { return ("\(name) is offline", "No reports since \(clock(detail.since ?? now)).") }
            return ("\(name) is back online", detail.since.map { "It was offline since \(clock($0))." } ?? "Reporting again.")
        case .disk:
            if firing {
                let free = detail.free.map { " \u{B7} \(JS.toFixed($0 / 1e9, 1)) GB free" } ?? ""
                var title = "\(name): disk \(detail.disk ?? "") is \(format(.disk, value)) full"
                // `.replace('  ', ' ')`: the gap a missing disk name leaves, once.
                if let gap = title.range(of: "  ") { title.replaceSubrange(gap, with: " ") }
                return (title, "Over your \(limit) limit\(free).")
            }
            return ("\(name): disk space back under \(limit)", "Now \(format(.disk, value)) used.")
        default:
            let duration = rule.minutes > 0 ? " for \(rule.minutes) min" : ""
            if firing { return ("\(name): \(rule.type.label) \(format(rule.type, value))", "Above \(limit)\(duration).") }
            return ("\(name): \(rule.type.label) back to normal", "Now \(format(rule.type, value)) (limit \(limit)).")
        }
    }
}

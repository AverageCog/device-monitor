import Foundation
import Testing
@testable import DMCore

/// Client-side validation against the hub's own: urls.json (httpUrl) and validation.json
/// (validRule and validSettings, each row answered by a real Alerts instance).
@Suite struct AlertValidationTests {
    private typealias F = AlertFixtures
    private static let loaded = Result { try F.load(F.Validation.self, "validation.json") }

    // MARK: httpUrl

    @Test func destinationsAreAcceptedAndStoredAsTheHubDoes() throws {
        let fixture = try F.load(F.URLs.self, "urls.json")
        #expect(fixture.rows.count > 300)
        var failures: [String] = []
        for row in fixture.rows where !row.input.isEmpty {
            let ours = AlertDestination.normalized(row.input)
            if ours != row.normalized { failures.append("\"\(row.input)\": ours \(ours ?? "refused"), hub \(row.normalized ?? "refused")") }
            if (AlertDestination.problem(with: row.input) == nil) != (row.normalized != nil) { failures.append("\"\(row.input)\": problem and normalized disagree") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(fixture.rows.count) differ:\n\(failures.prefix(40).joined(separator: "\n"))")
        #expect(fixture.emptyServerBecomes == AlertChannels.Ntfy.defaultServer)
        #expect(fixture.rows.filter { $0.normalized != nil }.count > 150)
        // Addresses the hub writes with a leading "::ffff:" are among them, on both sides.
        let afterPrefix = fixture.rows.filter { $0.input.lowercased().hasPrefix("http://[::ffff:") }
        #expect(afterPrefix.filter { $0.normalized == nil && $0.input.lowercased().hasPrefix("http://[::ffff:fe") }.count >= 10)
        #expect(afterPrefix.filter { $0.normalized != nil }.count >= 20)
    }

    @Test func whatFollowsTheMappedPrefixDecides() throws {
        // The hub takes "::ffff:" off the address as it writes it. Two groups after it are an
        // IPv4 address; anything else is tested for a link-local start as it then stands.
        let fixture = try F.load(F.URLs.self, "urls.json")
        let hub = Dictionary(fixture.rows.map { ($0.input, $0.normalized) }, uniquingKeysWith: { first, _ in first })
        let refused = ["http://[::ffff:fe80:1:2]", "http://[::ffff:fe80:1:2]/hook", "http://[::ffff:fe80]", "http://[::ffff:fe8]", "http://[0:0:0:ffff:fe80::]", "http://[::ffff:7f00:1]", "http://[::ffff:0:0]"]
        for address in refused {
            #expect(hub[address] == .some(nil), "\(address) is not a refused row of urls.json")
            #expect(AlertDestination.problem(with: address) == .blockedHost, "\(address)")
            #expect(AlertDestination.normalized(address) == nil, "\(address)")
        }
        let accepted = ["http://[::ffff:1:2:3]", "http://[::ffff:fe80:1]", "http://[::ffff:fe7f:1:2]", "http://[::ffff:fec0:1:2]", "http://[::ffff:7f00:0:1]", "http://[::ffff:fe]", "http://[1::ffff:fe80:1:2]", "http://[0:0:ffff:fe80::]"]
        for address in accepted {
            #expect(hub[address] == .some(address), "\(address) is not an accepted row of urls.json")
            #expect(AlertDestination.problem(with: address) == nil, "\(address)")
            #expect(AlertDestination.normalized(address) == address, "\(address)")
        }
        // The same check stands behind both address fields of the form.
        var settings = AlertSettings()
        settings.channels.webhook = AlertChannels.Webhook(enabled: true, url: "http://[::ffff:fe80:1:2]/hook", keepUrl: false)
        #expect(AlertValidation.issues(in: settings).map(\.field) == [.webhookURL])
        #expect(AlertValidation.hubStored(settings, hasStoredWebhook: false) == nil)
        var editor = AlertSettingsEditor(settings: AlertSettings())
        editor.setWebhookEnabled(true)
        editor.setWebhookURL("http://[::ffff:fe80:1:2]/hook")
        #expect(editor.body == nil && !editor.canSave)
        editor.setWebhookURL("http://[::ffff:1:2:3]/hook")
        #expect(editor.body != nil && editor.issues().isEmpty)
        editor.setNtfyServer("http://[::ffff:fe80]")
        #expect(editor.issues().map(\.field) == [.ntfyServer] && editor.body == nil)
    }

    @Test func refusalsNameTheReason() {
        #expect(AlertDestination.problem(with: "ntfy.sh") == .notAnAddress)
        #expect(AlertDestination.problem(with: "") == .notAnAddress)
        #expect(AlertDestination.problem(with: "https://") == .notAnAddress)
        #expect(AlertDestination.problem(with: "https://example.com:99999") == .notAnAddress)
        #expect(AlertDestination.problem(with: "ftp://example.com") == .notHTTP)
        #expect(AlertDestination.problem(with: "localhost:8080") == .notHTTP)
        #expect(AlertDestination.problem(with: "mailto:me@example.com") == .notHTTP)
        #expect(AlertDestination.problem(with: "https://user:secret@example.com/hook") == .hasCredentials)
        #expect(AlertDestination.problem(with: "http://localhost:8080") == .blockedHost)
        #expect(AlertDestination.problem(with: "http://127.0.0.1") == .blockedHost)
        #expect(AlertDestination.problem(with: "http://[::1]/") == .blockedHost)
        #expect(AlertDestination.problem(with: "http://169.254.169.254/latest") == .blockedHost)
        #expect(AlertDestination.problem(with: "http://192.168.1.20:8080/hook") == nil)
        #expect(AlertDestination.problem(with: "https://discord.com/api/webhooks/1/x") == nil)
        for problem in AlertDestination.Problem.allCases { #expect(!problem.message.isEmpty) }
        // A password never ends up in a message.
        #expect(AlertDestination.Problem.allCases.allSatisfy { !$0.message.contains("secret") })
    }

    // MARK: validRule

    private func ruleField(_ issue: AlertIssue) -> String? {
        switch issue.field {
        case .ruleThreshold: "threshold"
        case .ruleMinutes: "minutes"
        case .ruleDevice: "device"
        default: nil
        }
    }

    @Test func oneRuleAtATime() throws {
        let fixture = try Self.loaded.get()
        #expect(fixture.ruleRows.count > 400)
        var failures: [String] = [], refused = 0, unknown = 0
        for row in fixture.ruleRows {
            var settings = fixture.base
            settings.rules = [row.rule]
            let issues = AlertValidation.issues(in: settings)
            let stored = AlertValidation.hubStored(settings, hasStoredWebhook: false)
            let at = "\(row.rule)"
            if row.field == "type" {
                // The hub refuses a type it does not know; the app leaves that to the hub.
                unknown += 1
                if row.stored != nil || stored != nil || !issues.isEmpty || !AlertValidation.hasUnknownKinds(settings) { failures.append("\(at): unknown kind handled differently") }
                continue
            }
            let errors = issues.filter { $0.severity == .error }
            if errors.isEmpty != (row.stored != nil) { failures.append("\(at): ours \(errors.isEmpty ? "accepts" : "refuses"), hub \(row.stored != nil ? "accepts" : "refuses")") }
            if AlertValidation.isAcceptable(settings) != (row.stored != nil) { failures.append("\(at): isAcceptable") }
            if row.rule.isAcceptable != (row.stored != nil) { failures.append("\(at): AlertRule.isAcceptable disagrees") }
            if (stored == nil) != (row.stored == nil) { failures.append("\(at): hubStored \(stored == nil ? "refuses" : "accepts")") }
            if let theirs = row.stored, let ours = stored?.rules.first {
                var expected = theirs
                // An id the hub does not keep is replaced by a random one, here as there.
                if !AlertValidation.isRuleID(row.rule.id) {
                    if ours.id == row.rule.id || !AlertValidation.isRuleID(ours.id) { failures.append("\(at): id kept") }
                    expected.id = ours.id
                }
                if ours != expected { failures.append("\(at): stored as \(ours), hub stores \(theirs)") }
            } else {
                refused += 1
                // Exactly the field that was put wrong is reported, for exactly this rule.
                if errors.map(ruleField) != [row.field] || errors.first?.ruleID != row.rule.id { failures.append("\(at): reported \(errors.map(\.field)), wrong is \(row.field ?? "nothing")") }
                if errors.contains(where: { $0.message.isEmpty }) { failures.append("\(at): empty message") }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(25).joined(separator: "\n"))")
        #expect(refused > 150 && unknown == 7)
    }

    // MARK: validSettings

    @Test func channels() throws {
        let fixture = try Self.loaded.get()
        #expect(fixture.channelRows.count > 130)
        var failures: [String] = [], refused = 0, switchedOff = 0
        for row in fixture.channelRows {
            let settings = AlertSettings(rules: fixture.base.rules, channels: row.channels, notifyResolved: row.notifyResolved, tempUnit: row.tempUnit)
            let issues = AlertValidation.issues(in: settings, hasStoredWebhook: row.prevWebhook)
            let errors = issues.filter { $0.severity == .error }, warnings = issues.filter { $0.severity == .warning }
            let stored = AlertValidation.hubStored(settings, hasStoredWebhook: row.prevWebhook)
            let at = "\(row.channels) (webhook stored: \(row.prevWebhook))"
            guard let theirs = row.stored else {
                refused += 1
                if stored != nil { failures.append("\(at): hubStored accepts, the hub refuses") }
                let expected: AlertIssue.Field? = switch row.field {
                case "topic": .ntfyTopic
                case "email": .ntfyEmail
                case "server": .ntfyServer
                case "webhook": .webhookURL
                default: nil
                }
                if errors.map(\.field) != [expected].compactMap({ $0 }) { failures.append("\(at): errors on \(errors.map(\.field)), wrong is \(row.field ?? "nothing")") }
                continue
            }
            if !errors.isEmpty { failures.append("\(at): errors \(errors.map(\.message)), the hub accepts") }
            let expected = AlertSettings(rules: fixture.baseAnswer.rules, channels: theirs.channels, notifyResolved: theirs.notifyResolved, tempUnit: theirs.tempUnit)
            if stored != expected { failures.append("\(at): stored as \(stored.map { "\($0.channels)" } ?? "nil"), hub stores \(theirs.channels)") }
            // A warning exactly when the hub switches off a channel the user switched on.
            let ntfyOff = row.channels.ntfy.enabled && !theirs.channels.ntfy.enabled
            let hookOff = row.channels.webhook.enabled && !theirs.channels.webhook.enabled
            if ntfyOff || hookOff { switchedOff += 1 }
            if warnings.contains(where: { $0.field == .ntfyTopic }) != ntfyOff { failures.append("\(at): ntfy warning \(!ntfyOff), hub switches it off: \(ntfyOff)") }
            if warnings.contains(where: { $0.field == .webhookURL }) != hookOff { failures.append("\(at): webhook warning \(!hookOff), hub switches it off: \(hookOff)") }
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(25).joined(separator: "\n"))")
        #expect(refused > 40 && switchedOff > 8, "\(refused) refused, \(switchedOff) switched off")
    }

    @Test func wholeRuleLists() throws {
        let fixture = try Self.loaded.get()
        #expect(fixture.rows.count >= 6)
        for row in fixture.rows {
            let stored = AlertValidation.hubStored(row.body, hasStoredWebhook: row.prevWebhook)
            #expect(stored == row.answer, "\(row.body.rules.count) rules")
            #expect(AlertValidation.isAcceptable(row.body) == (row.answer != nil), "\(row.body.rules.count) rules")
        }
        // More than a hundred rules: saved, cut, and said so.
        let long = try #require(fixture.rows.first { $0.body.rules.count > 100 && $0.answer != nil })
        #expect(long.answer?.rules.count == 100)
        let issues = AlertValidation.issues(in: long.body)
        #expect(issues.map(\.field) == [.rules] && issues.first?.severity == .warning)
        // A bad rule past the cut is never looked at.
        let pastTheCut = try #require(fixture.rows.first { $0.body.rules.count == 101 })
        #expect(pastTheCut.answer != nil)
        #expect(AlertValidation.issues(in: pastTheCut.body).allSatisfy { $0.severity == .warning })
        #expect(AlertValidation.hubStored(fixture.base, hasStoredWebhook: false) == fixture.baseAnswer)
    }

    @Test func whatTheHubSendsCanGoStraightBack() throws {
        // The captured GET /api/alerts payloads of a real hub, sent back unchanged.
        for file in ["alerts.json", "alerts-default.json", "alerts-after-clear.json"] {
            let response = try HubJSON.decode(AlertsResponse.self, from: try Fixture.data("models/" + file))
            #expect(AlertValidation.isAcceptable(response.settings), "\(file)")
            let stored = AlertValidation.hubStored(response.settings, hasStoredWebhook: response.settings.channels.webhook.keepUrl)
            #expect(stored == response.settings, "\(file)")
        }
    }

    @Test func textFieldsAreReadAsTheHubReadsThem() {
        #expect(AlertValidation.cleaned("  my-topic \n", max: 64) == "my-topic")
        #expect(AlertValidation.cleaned("a\u{0}b\u{7F}c\td", max: 64) == "abcd")
        #expect(AlertValidation.cleaned(String(repeating: "x", count: 70), max: 64).count == 64)
        #expect(AlertValidation.cleaned("\u{FEFF} x \u{A0}", max: 64) == "x")
        // A cut never leaves half a character.
        #expect(AlertValidation.cleaned("ab😀", max: 3) == "ab")
        #expect(AlertValidation.cleaned("ab😀", max: 4) == "ab😀")
        #expect(AlertValidation.isTopic("A_b-9") && !AlertValidation.isTopic("") && !AlertValidation.isTopic("a b"))
        #expect(AlertValidation.isEmail("me@example.com") && !AlertValidation.isEmail("me@example") && !AlertValidation.isEmail("me@@example.com"))
        #expect(AlertValidation.isDeviceID("a3f1c9d2-7b64-4e0a-9c1d-2f5e8b7a6c40") && !AlertValidation.isDeviceID("*") && !AlertValidation.isDeviceID(""))
    }

    @Test func messagesSpeakTheUsersUnit() {
        let rule = AlertRule(id: "0123456789ab", type: .cpuTemp, threshold: 10)
        #expect(AlertValidation.issues(for: rule, unit: .celsius).map(\.message) == ["The limit must be between 20°C and 150°C."])
        #expect(AlertValidation.issues(for: rule, unit: .fahrenheit).map(\.message) == ["The limit must be between 68°F and 302°F."])
        var missing = rule
        missing.threshold = nil
        #expect(AlertValidation.issues(for: missing, unit: .celsius).map(\.message) == ["Enter a limit between 20°C and 150°C."])
        let cost = AlertRule(id: "0123456789ab", type: .dailyCost, threshold: 0)
        #expect(AlertValidation.issues(for: cost, currency: "EUR").map(\.message) == ["The limit must be between €0.01 and €10,000,000.00."])
        let offline = AlertRule(id: "0123456789ab", type: .offline, minutes: 0)
        #expect(AlertValidation.issues(for: offline).map(\.message) == ["An offline alert needs at least 1 minute."])
        let slow = AlertRule(id: "0123456789ab", type: .cpu, threshold: 90, minutes: 2000)
        #expect(AlertValidation.issues(for: slow).map(\.message) == ["Use 0 to 1440 minutes."])
        let nowhere = AlertRule(id: "0123456789ab", type: .cpu, device: "", threshold: 90)
        #expect(AlertValidation.issues(for: nowhere).map(\.field) == [.ruleDevice(ruleID: "0123456789ab")])
        // Several things wrong with one rule are all reported.
        let hopeless = AlertRule(id: "0123456789ab", type: .offline, device: "?", minutes: 5000)
        #expect(AlertValidation.issues(for: hopeless).count == 2)
    }
}

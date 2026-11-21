import Foundation
import Testing
@testable import DMCore

/// The alert settings editor. Whatever it offers as a PUT body is put to the hub's own check
/// (`AlertValidation.hubStored`, itself held to alerts.js by AlertValidationTests).
@Suite struct AlertSettingsEditorTests {
    private typealias F = AlertFixtures

    private func captured(_ file: String = "alerts.json") throws -> AlertSettings {
        try HubJSON.decode(AlertsResponse.self, from: try Fixture.data("models/" + file)).settings
    }

    @Test func untouchedSettingsAreCleanAndSendable() throws {
        for file in ["alerts.json", "alerts-default.json"] {
            let settings = try captured(file)
            let editor = AlertSettingsEditor(settings: settings)
            #expect(!editor.isDirty && !editor.hasErrors && !editor.canSave)
            #expect(editor.body == settings)
            #expect(editor.settings == settings && editor.saved == settings)
            #expect(editor.issues().isEmpty, "\(file)")
        }
    }

    @Test func addingRulesUsesEachKindsDefaults() throws {
        var editor = AlertSettingsEditor(settings: AlertSettings())
        for kind in AlertRule.Kind.allCases {
            let added = editor.addRule(kind, device: "nas-01")
            let rule = try #require(added)
            #expect(rule == AlertRuleCatalog.newRule(kind, device: "nas-01", id: rule.id))
            #expect(editor.rule(rule.id) == rule)
            #expect(AlertValidation.isRuleID(rule.id))
        }
        #expect(editor.settings.rules.map(\.type) == AlertRule.Kind.allCases)
        #expect(Set(editor.settings.rules.map(\.id)).count == 9)
        #expect(editor.isDirty && !editor.hasErrors && editor.canSave)
        let body = try #require(editor.body)
        #expect(AlertValidation.hubStored(body, hasStoredWebhook: false)?.rules == body.rules)
        // An id that is taken is not used twice.
        let taken = editor.settings.rules[0].id
        let again = editor.addRule(.cpu, id: taken)
        let extra = try #require(again)
        #expect(extra.id != taken && editor.rule(extra.id)?.type == .cpu)
    }

    @Test func theListStopsAtAHundred() {
        var editor = AlertSettingsEditor(settings: AlertSettings())
        for _ in 0..<100 { editor.addRule(.offline) }
        #expect(editor.settings.rules.count == 100 && !editor.canAddRule)
        let refused = editor.addRule(.cpu)
        #expect(refused == nil && editor.settings.rules.count == 100)
        editor.deleteRule(editor.settings.rules[0].id)
        #expect(editor.canAddRule && editor.settings.rules.count == 99)
    }

    @Test func editingARule() throws {
        var editor = AlertSettingsEditor(settings: try captured())
        let id = "5021aa0cccc6"   // CPU temperature above 90 °C for 2 minutes, all devices
        #expect(editor.rule(id)?.threshold == 90)

        editor.setThreshold(of: id, toDisplayed: 95, unit: .celsius)
        editor.setMinutes(of: id, to: 5)
        editor.setDevice(of: id, to: "nas-01")
        #expect(editor.rule(id) == AlertRule(id: id, type: .cpuTemp, device: "nas-01", threshold: 95, minutes: 5, enabled: true))
        #expect(editor.isDirty && editor.canSave)

        editor.toggleRule(id)
        #expect(editor.rule(id)?.enabled == false)
        editor.setEnabled(true, for: id)
        #expect(editor.rule(id)?.enabled == true)

        // The order of the list and the other rules are untouched.
        let before = try captured()
        #expect(editor.settings.rules.map(\.id) == before.rules.map(\.id))
        #expect(editor.settings.rules.filter { $0.id != id } == before.rules.filter { $0.id != id })

        // A closure cannot change the id; an unknown id changes nothing.
        editor.updateRule(id) { $0.id = "other" }
        #expect(editor.rule(id) != nil && editor.rule("other") == nil)
        let snapshot = editor
        editor.setMinutes(of: "nope", to: 3)
        editor.toggleRule("nope")
        editor.deleteRule("nope")
        #expect(editor == snapshot)

        editor.deleteRule(id)
        #expect(editor.rule(id) == nil && editor.settings.rules.count == before.rules.count - 1)
        editor.revert()
        #expect(editor.settings == before && !editor.isDirty)
    }

    @Test func limitsAreEditedInTheUsersUnitAndStoredInCelsius() throws {
        var editor = AlertSettingsEditor(settings: try captured())
        let id = "5021aa0cccc6"
        // Shown in Fahrenheit, saved untouched: nothing changes.
        let shown = AlertThresholds.displayValue(90, kind: .cpuTemp, unit: .fahrenheit)
        #expect(shown == 194)
        editor.setThreshold(of: id, toDisplayed: shown, unit: .fahrenheit)
        #expect(!editor.isDirty)
        // Changed: converted exactly, and the hub will write the number that was typed.
        editor.setThreshold(of: id, toDisplayed: 200, unit: .fahrenheit)
        let stored = try #require(editor.rule(id)?.threshold)
        #expect(stored == (200.0 - 32) * 5 / 9)
        let edited = try #require(editor.rule(id))
        #expect(AlertText.limit(of: edited, unit: .fahrenheit) == "200°F")
        #expect(AlertThresholds.fieldText(stored, kind: .cpuTemp, unit: .fahrenheit, locale: F.enUS) == "200")
        // Opening and saving the form again, any number of times, leaves it where it is.
        for _ in 0..<5 {
            let field = AlertThresholds.fieldText(editor.rule(id)?.threshold, kind: .cpuTemp, unit: .fahrenheit, locale: F.enUS)
            editor.setThreshold(of: id, toText: field, unit: .fahrenheit, locale: F.enUS)
        }
        #expect(editor.rule(id)?.threshold == stored)
        // So does opening it where Celsius is shown: the field says 93.33, and the limit stays.
        let celsiusField = AlertThresholds.fieldText(stored, kind: .cpuTemp, unit: .celsius, locale: F.enUS)
        #expect(celsiusField == "93.33")
        editor.setThreshold(of: id, toText: celsiusField, unit: .celsius, locale: F.enUS)
        #expect(editor.rule(id)?.threshold == stored)
        // Text in the user's locale.
        editor.setThreshold(of: "abcdef012345", toText: "97,25", unit: .fahrenheit, locale: Locale(identifier: "de_DE"))
        #expect(editor.rule("abcdef012345")?.threshold == 97.25)   // memory, a percentage: no conversion
        // An empty field is a missing limit, and is reported in the unit shown.
        editor.setThreshold(of: id, toText: "", unit: .fahrenheit, locale: F.enUS)
        #expect(editor.rule(id)?.threshold == nil)
        #expect(editor.issues(forRule: id, unit: .fahrenheit).map(\.message) == ["Enter a limit between 68°F and 302°F."])
        #expect(editor.hasErrors && editor.body == nil && !editor.canSave)
        // Out of range, in either unit.
        editor.setThreshold(of: id, toDisplayed: 400, unit: .fahrenheit)
        #expect(editor.issues(forRule: id, unit: .fahrenheit).map(\.message) == ["The limit must be between 68°F and 302°F."])
        editor.setThreshold(of: id, toDisplayed: 302, unit: .fahrenheit)
        #expect(editor.issues(forRule: id).isEmpty && editor.rule(id)?.threshold == 150)
    }

    @Test func changingTheKindStartsOverWithThatKindsDefaults() throws {
        var editor = AlertSettingsEditor(settings: try captured())
        let id = "5021aa0cccc6"
        editor.setDevice(of: id, to: "nas-01")
        editor.setEnabled(false, for: id)
        editor.setKind(of: id, to: .offline)
        #expect(editor.rule(id) == AlertRule(id: id, type: .offline, device: "nas-01", threshold: nil, minutes: 10, enabled: false))
        editor.setKind(of: id, to: .power)
        #expect(editor.rule(id)?.threshold == 500 && editor.rule(id)?.minutes == 5)
        // Choosing the kind it already has keeps what was entered.
        editor.setThreshold(of: id, toDisplayed: 750, unit: .celsius)
        editor.setKind(of: id, to: .power)
        #expect(editor.rule(id)?.threshold == 750)
        #expect(!editor.hasErrors)
    }

    @Test func restoringTheDefaultRules() throws {
        var editor = AlertSettingsEditor(settings: try captured())
        editor.restoreDefaultRules()
        #expect(editor.settings.rules.map(\.type) == [.offline, .cpuTemp, .gpuTemp, .disk])
        #expect(editor.settings.channels == (try captured()).channels)
        #expect(editor.canSave)
    }

    @Test func channelEdits() throws {
        var editor = AlertSettingsEditor(settings: AlertSettings())
        editor.setAppNotifications(false)
        editor.setNotifyResolved(false)
        editor.setTemperatureUnit(.fahrenheit)
        #expect(!editor.settings.channels.desktop && !editor.settings.notifyResolved && editor.settings.tempUnit == .fahrenheit)

        // ntfy without a topic: the hub would save it switched off, so say so.
        editor.setNtfyEnabled(true)
        #expect(editor.issues().map(\.field) == [.ntfyTopic] && editor.issues()[0].severity == .warning && editor.canSave)
        editor.setNtfyTopic("my topic")
        #expect(editor.issues().map(\.severity) == [.error] && editor.body == nil)
        editor.setNtfyTopic("my-topic")
        editor.setNtfyEmail("me@example")
        #expect(editor.issues().map(\.field) == [.ntfyEmail])
        editor.setNtfyEmail("me@example.com")
        editor.setNtfyServer("ntfy.example.com")
        #expect(editor.issues().map(\.field) == [.ntfyServer])
        #expect(editor.issues()[0].message == AlertDestination.Problem.notAnAddress.message)
        editor.setNtfyServer("https://ntfy.example.com/")
        #expect(editor.issues().isEmpty)
        let body = try #require(editor.body)
        let stored = try #require(AlertValidation.hubStored(body, hasStoredWebhook: false))
        #expect(stored.channels.ntfy == AlertChannels.Ntfy(enabled: true, server: "https://ntfy.example.com", topic: "my-topic", email: "me@example.com"))
        // An empty server field means the public one.
        editor.setNtfyServer("")
        #expect(editor.issues().isEmpty)
        let publicServer = try #require(editor.body)
        #expect(AlertValidation.hubStored(publicServer, hasStoredWebhook: false)?.channels.ntfy.server == "https://ntfy.sh")
    }

    @Test func webhookURLIsKeptReplacedOrRemoved() throws {
        // The hub holds a URL it never shows: enabled, url "", keepUrl true.
        let saved = try captured()
        #expect(saved.channels.webhook == AlertChannels.Webhook(enabled: true, url: "", keepUrl: true))
        var editor = AlertSettingsEditor(settings: saved)
        #expect(editor.hasStoredWebhook)
        #expect(editor.webhookPlaceholder.hasPrefix("Saved"))
        func json(_ editor: AlertSettingsEditor) throws -> String {
            String(decoding: try HubJSON.encode(try #require(editor.body).channels.webhook), as: UTF8.self)
        }

        // Left alone: the stored URL stays.
        #expect(try json(editor) == #"{"enabled":true,"keepUrl":true}"#)
        let untouched = try #require(editor.body)
        #expect(AlertValidation.hubStored(untouched, hasStoredWebhook: true)?.channels.webhook == saved.channels.webhook)

        // A new URL replaces it.
        editor.setWebhookURL("https://discord.com/api/webhooks/1/x")
        #expect(try json(editor) == #"{"enabled":true,"url":"https://discord.com/api/webhooks/1/x"}"#)
        #expect(editor.isDirty && editor.issues().isEmpty)

        // Clearing the field again goes back to keeping the stored one.
        editor.setWebhookURL("")
        #expect(!editor.isDirty)
        #expect(try json(editor) == #"{"enabled":true,"keepUrl":true}"#)

        // A URL the hub would refuse blocks saving.
        editor.setWebhookURL("http://localhost:3000/hook")
        #expect(editor.issues().map(\.field) == [.webhookURL] && editor.body == nil)
        #expect(editor.issues()[0].message == AlertDestination.Problem.blockedHost.message)
        editor.setWebhookURL("")

        // Removing it: nothing to keep, and a webhook that is still switched on gets a warning.
        #expect(!editor.removesStoredWebhook)
        editor.removeWebhookURL()
        #expect(editor.removesStoredWebhook)
        #expect(try json(editor) == #"{"enabled":true,"url":""}"#)
        // Typing something and clearing it again does not bring the removed URL back…
        editor.setWebhookURL("https://exam")
        #expect(!editor.removesStoredWebhook)
        editor.setWebhookURL("")
        #expect(editor.removesStoredWebhook)
        #expect(try json(editor) == #"{"enabled":true,"url":""}"#)
        // …only saying so does.
        editor.keepStoredWebhookURL()
        #expect(!editor.removesStoredWebhook && !editor.isDirty)
        #expect(try json(editor) == #"{"enabled":true,"keepUrl":true}"#)
        editor.removeWebhookURL()
        #expect(editor.issues().map(\.field) == [.webhookURL] && editor.issues()[0].severity == .warning)
        #expect(editor.webhookPlaceholder == "https://…")
        let removed = try #require(editor.body)
        let stored = try #require(AlertValidation.hubStored(removed, hasStoredWebhook: true))
        #expect(stored.channels.webhook == AlertChannels.Webhook(enabled: false, url: "", keepUrl: false))
        editor.hubSaved(stored)
        #expect(!editor.hasStoredWebhook && !editor.isDirty && editor.issues().isEmpty && !editor.removesStoredWebhook)
        // With nothing stored there is nothing to keep.
        editor.keepStoredWebhookURL()
        #expect(!editor.isDirty && editor.settings.channels.webhook.keepUrl == false)

        // Nothing stored: switching it on without a URL warns; with one it is fine.
        editor.setWebhookEnabled(true)
        #expect(editor.issues().map(\.field) == [.webhookURL])
        editor.setWebhookURL("https://hooks.slack.com/services/T/B/X")
        #expect(editor.issues().isEmpty)
        let replaced = try #require(editor.body)
        let again = try #require(AlertValidation.hubStored(replaced, hasStoredWebhook: false))
        #expect(again.channels.webhook == AlertChannels.Webhook(enabled: true, url: "", keepUrl: true))
    }

    @Test func settingsFromTheHubWhileEditing() throws {
        let saved = try captured()
        var other = saved
        other.notifyResolved.toggle()
        // An untouched form follows the hub.
        var idle = AlertSettingsEditor(settings: saved)
        idle.hubChanged(other)
        #expect(idle.settings == other && !idle.isDirty)
        // Unsaved edits are kept, and stay "dirty" against the new state.
        var busy = AlertSettingsEditor(settings: saved)
        busy.setNtfyTopic("new-topic")
        busy.hubChanged(other)
        #expect(busy.settings.channels.ntfy.topic == "new-topic" && busy.settings.notifyResolved == saved.notifyResolved)
        #expect(busy.saved == other && busy.isDirty)
        // The answer to a PUT replaces everything.
        busy.hubSaved(other)
        #expect(busy.settings == other && !busy.isDirty)
    }

    @Test func whateverTheEditorOffersTheHubAccepts() throws {
        var generator = PresentationTestRandom(seed: 0xA1E27)
        func pick<T>(_ items: [T]) -> T {
            items[Int(generator.next() % UInt64(items.count))]
        }
        // Mostly sensible entries with the odd bad one, as a person would make them.
        let devices = ["*", "*", "nas-01", "a3f1c9d2-7b64-4e0a-9c1d-2f5e8b7a6c40", "lab", "", "bad id"]
        let numbers: [Double?] = [25, 60, 68, 80, 85, 90.5, 95, 100, 150, 250, 500, nil, 0, 19.9, 151, 100_001, 1e8, -5, .nan, .infinity]
        let topics = ["", "my-topic", "alerts_1", "bad topic"], emails = ["", "me@example.com", "nope"]
        let servers = ["", "https://ntfy.sh", "http://192.168.1.5:8080", "http://localhost"]
        let hooks = ["", "https://discord.com/api/webhooks/1/x", "https://hooks.slack.com/services/T/B/X", "https://u:p@x.example", " "]
        var offered = 0, withheld = 0
        for round in 0..<40 {
            var editor = AlertSettingsEditor(settings: round % 2 == 0 ? AlertSettings() : try captured())
            for _ in 0..<60 {
                let id = editor.settings.rules.isEmpty ? "none" : pick(editor.settings.rules.map(\.id))
                let unit: TemperatureUnit = pick([.celsius, .fahrenheit])
                switch generator.next() % 18 {
                case 0: editor.addRule(pick(AlertRule.Kind.allCases), device: pick(devices))
                case 1: editor.setKind(of: id, to: pick(AlertRule.Kind.allCases))
                case 2: editor.setDevice(of: id, to: pick(devices))
                case 3, 4: editor.setThreshold(of: id, toDisplayed: pick(numbers), unit: unit)
                case 5: editor.setMinutes(of: id, to: pick([0, 1, 2, 5, 30, 1440, 1441, -1]))
                case 6: editor.toggleRule(id)
                case 7: editor.deleteRule(id)
                case 8: editor.setNtfyEnabled(pick([true, false]))
                case 9: editor.setNtfyTopic(pick(topics))
                case 10: editor.setNtfyEmail(pick(emails))
                case 11: editor.setNtfyServer(pick(servers))
                case 12: editor.setWebhookEnabled(pick([true, false]))
                case 13: editor.setWebhookURL(pick(hooks))
                case 14: if generator.next() % 2 == 0 { editor.removeWebhookURL() } else { editor.keepStoredWebhookURL() }
                case 15: editor.setTemperatureUnit(unit)
                case 16: editor.revert()
                default:
                    // Saving, when there is nothing in the way.
                    if let body = editor.body, let stored = AlertValidation.hubStored(body, hasStoredWebhook: editor.hasStoredWebhook) { editor.hubSaved(stored) }
                }
                // The editor and the hub's check agree on every state it can reach.
                let stored = AlertValidation.hubStored(editor.settings, hasStoredWebhook: editor.hasStoredWebhook)
                #expect(editor.hasErrors == (stored == nil), "\(editor.settings)")
                if let body = editor.body {
                    offered += 1
                    #expect(stored != nil)
                    #expect(body == editor.settings)
                    // Saving and saving again changes nothing more.
                    if let stored { #expect(AlertValidation.hubStored(stored, hasStoredWebhook: stored.channels.webhook.keepUrl) == stored) }
                } else {
                    withheld += 1
                    #expect(editor.issues().contains { $0.severity == .error && !$0.message.isEmpty })
                }
            }
        }
        #expect(offered > 200 && withheld > 200, "\(offered) offered, \(withheld) withheld")
    }
}

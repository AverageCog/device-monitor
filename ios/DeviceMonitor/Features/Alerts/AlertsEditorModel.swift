import Accessibility
import DMCore
import Observation
import SwiftUI

/// How a test alert went on each of the hub's channels.
nonisolated struct AlertsTestReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The channel is switched off.
        case off
        /// Put on the live connection; the hub hears nothing back from the apps.
        case sent
        case delivered
        /// With the hub's reason: "HTTP 404", a network error code, "Blocked alert destination".
        case failed(String)
    }

    struct Line: Equatable, Sendable, Identifiable {
        let id: String
        let channel: String
        let outcome: Outcome

        var text: String {
            switch outcome {
            case .off: "Off"
            case .sent: "Sent"
            case .delivered: "Delivered"
            case .failed(let reason): reason.isEmpty ? "Failed" : "Failed: \(reason)"
            }
        }
    }

    let lines: [Line]

    /// - Parameters:
    ///   - result: the hub's answer; a channel that is off is absent from it.
    ///   - sendsToApps: the hub's saved "Device Monitor apps" channel.
    init(result: AlertTestResult, sendsToApps: Bool) {
        let delivery = { (delivery: AlertTestResult.Delivery?) -> Outcome in
            guard let delivery else { return .off }
            return delivery.ok ? .delivered : .failed(delivery.error ?? "")
        }
        lines = [
            Line(id: "apps", channel: AlertsChannel.apps, outcome: sendsToApps ? .sent : .off),
            Line(id: "ntfy", channel: AlertsChannel.ntfy, outcome: delivery(result.ntfy)),
            Line(id: "webhook", channel: AlertsChannel.webhook, outcome: delivery(result.webhook)),
        ]
    }
}

nonisolated enum AlertsTestState: Equatable, Sendable {
    case idle
    case sending
    case sent(AlertsTestReport)
    /// The hub could not be asked at all.
    case failed(String)
}

/// The draft of the alert settings for the hub the app is on. Kept here and not in the Alerts
/// tab's own state: the shell takes the tabs away while the hub cannot be reached, and what was
/// being edited (a webhook address, typed on a phone) has to be there when they come back.
/// Another hub starts with a fresh draft.
final class AlertsDrafts {
    static let shared = AlertsDrafts()

    private weak var store: HubStore?
    private var model: AlertsEditorModel?

    private init() {}

    func model(for store: HubStore) -> AlertsEditorModel {
        if let model, self.store === store { return model }
        let fresh = AlertsEditorModel()
        self.store = store
        model = fresh
        return fresh
    }
}

/// The alert settings while they are being edited: the presentation layer's editor, plus what
/// only a screen has (a save in flight, its error, the rule that is open). One per hub
/// (`AlertsDrafts`), so a draft survives leaving the editor, and the tabs going away for a while.
@Observable
final class AlertsEditorModel {
    /// Nil until the hub's settings are known.
    private(set) var editor: AlertSettingsEditor?
    private(set) var isSaving = false
    /// Why the last save failed, in the hub's or the transport's words.
    private(set) var saveFailure: String?
    /// The hub's settings changed (another app, the dashboard) while this draft had edits.
    private(set) var changedElsewhere = false
    /// True for a moment after a save went through.
    private(set) var wasJustSaved = false
    /// Counted for the haptics: saves and tests that went through, and requests that did not.
    private(set) var saves = 0
    private(set) var tests = 0
    private(set) var failures = 0
    private(set) var test = AlertsTestState.idle

    /// The editor is pushed over the Alerts tab.
    var isOpen = AlertsLaunch.opensSettings
    /// The rule whose screen is pushed over the editor, once the editor has arrived
    /// (`AlertsSettingsScreen` sees to the order).
    var editedRuleID: String?
    /// The webhook URL field is shown although the hub holds a URL: "Replace" was chosen. Until
    /// the draft is saved or reverted, or the saved URL is kept after all.
    var isReplacingWebhook = false

    var isDirty: Bool { editor?.isDirty ?? false }
    var canSave: Bool { (editor?.canSave ?? false) && !isSaving }

    /// "Edit rule" on an alert: the editor, opened at the rule that raised it.
    func open(rule id: String) {
        editedRuleID = id
        isOpen = true
    }

    // MARK: The hub

    /// The store's settings changed, or are known for the first time. A draft without edits
    /// follows them; one with edits keeps them.
    func follow(_ settings: AlertSettings?) {
        guard let settings else { return }
        guard var current = editor else {
            editor = AlertSettingsEditor(settings: settings)
            return
        }
        guard current.saved != settings else { return }
        if current.isDirty, !isSaving { changedElsewhere = true }
        current.hubChanged(settings)
        editor = current
        // A test result is about the settings the hub had then.
        if test != .sending { test = .idle }
        if !current.isDirty { changedElsewhere = false }
    }

    /// Sends the draft to the hub. Nothing is sent while the hub would refuse it.
    func save(to store: HubStore) async {
        guard !isSaving, let current = editor, current.isDirty, let body = current.body else { return }
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }
        do {
            #if DEBUG
            if let failure = AlertsLaunch.saveFailure { throw failure }
            #endif
            try await store.saveAlerts(body)
        } catch {
            let reason = HubError(error).errorDescription ?? "The hub did not save the alert settings."
            saveFailure = reason
            failures += 1
            // The banner appears at the top of the form, which VoiceOver may be far from.
            AccessibilityNotification.Announcement("Not saved. \(reason)").post()
            return
        }
        // What the hub stored: topics trimmed, channels without an address switched off again.
        editor?.hubSaved(store.alerts.settings ?? body)
        settled()
        if test != .sending { test = .idle }
        saves += 1
        AccessibilityNotification.Announcement("Alert settings saved").post()
        confirmSave()
    }

    /// "Saved" takes the Save button's place for a moment.
    private func confirmSave() {
        let save = saves
        wasJustSaved = true
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if saves == save { wasJustSaved = false }
        }
    }

    /// Throws the edits away.
    func revert() {
        editor?.revert()
        saveFailure = nil
        settled()
    }

    /// The draft is the hub's again, by a save or by giving the edits up. Not by an edit that
    /// happens to end where it began: emptying the field "Replace" brought up, to start over,
    /// must not take the field away.
    private func settled() {
        changedElsewhere = false
        isReplacingWebhook = false
    }

    // MARK: Editing

    /// One change to the draft, as a tap or a keystroke makes it.
    func edit(_ change: (inout AlertSettingsEditor) -> Void) {
        guard var current = editor else { return }
        change(&current)
        Self.takeBackWhatIsHidden(in: &current)
        guard current != editor else { return }
        editor = current
        saveFailure = nil
        if !current.isDirty { changedElsewhere = false }
    }

    /// A channel that is off shows none of its fields, and the hub checks them all the same. What
    /// it would refuse in them could neither be seen nor put right, and would keep Save from
    /// working: switching a channel off takes such a field back to what the hub has.
    private static func takeBackWhatIsHidden(in editor: inout AlertSettingsEditor) {
        let channels = editor.settings.channels, saved = editor.saved.channels
        let ntfy = !channels.ntfy.enabled
            && (channels.ntfy.topic != saved.ntfy.topic || channels.ntfy.server != saved.ntfy.server || channels.ntfy.email != saved.ntfy.email)
        let webhook = !channels.webhook.enabled && channels.webhook.url != saved.webhook.url
        guard ntfy || webhook else { return }
        for issue in editor.issues() where issue.severity == .error {
            switch issue.field {
            case .ntfyTopic where ntfy: editor.setNtfyTopic(saved.ntfy.topic)
            case .ntfyServer where ntfy: editor.setNtfyServer(saved.ntfy.server)
            case .ntfyEmail where ntfy: editor.setNtfyEmail(saved.ntfy.email)
            case .webhookURL where webhook: editor.setWebhookURL(saved.webhook.url)
            default: break
            }
        }
    }

    /// Adds a rule of `kind` with its defaults and opens it.
    func addRule(_ kind: AlertRule.Kind) {
        var added: AlertRule?
        edit { added = $0.addRule(kind) }
        if let added { editedRuleID = added.id }
    }

    func deleteRule(_ id: String) {
        if editedRuleID == id { editedRuleID = nil }
        edit { $0.deleteRule(id) }
    }

    // MARK: Test

    /// Has the hub send a test alert with the settings it has saved.
    func sendTest(through store: HubStore) async {
        guard test != .sending else { return }
        test = .sending
        do {
            #if DEBUG
            if let failure = AlertsLaunch.testFailure { throw failure }
            #endif
            let result = try await store.sendTestAlert()
            test = .sent(AlertsTestReport(result: result, sendsToApps: store.alerts.settings?.channels.desktop ?? true))
            tests += 1
        } catch {
            test = .failed(HubError(error).errorDescription ?? "The hub could not be asked.")
            failures += 1
        }
    }

    #if DEBUG
    /// A launch argument shows a result the demo hub never gives (a delivery that failed).
    func debugShow(_ report: AlertsTestReport) {
        test = .sent(report)
    }
    #endif
}

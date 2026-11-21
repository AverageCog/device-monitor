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

/// The alert settings while they are being edited: the presentation layer's editor, plus what
/// only a screen has (a save in flight, its error, the rule that is open). One per Alerts tab,
/// so a draft survives leaving the editor and coming back.
@Observable
final class AlertsEditorModel {
    /// Nil until the hub's settings are known.
    private(set) var editor: AlertSettingsEditor?
    private(set) var isSaving = false
    /// Why the last save failed, in the hub's or the transport's words.
    private(set) var saveFailure: String?
    /// The hub's settings changed (another app, the dashboard) while this draft had edits.
    private(set) var changedElsewhere = false
    /// Counted for the haptics and the "Saved" note: saves and tests that went through, and
    /// requests that did not.
    private(set) var saves = 0
    private(set) var tests = 0
    private(set) var failures = 0
    private(set) var test = AlertsTestState.idle

    /// The editor is pushed over the Alerts tab.
    var isOpen = AlertsLaunch.opensSettings
    /// The rule whose screen is pushed over the editor.
    var editedRuleID: String?
    @ObservationIgnored private var ruleToOpen: String?
    /// The webhook URL field is shown although the hub holds a URL.
    var isReplacingWebhook = false

    var isDirty: Bool { editor?.isDirty ?? false }
    var canSave: Bool { (editor?.canSave ?? false) && !isSaving }

    /// "Edit rule" on an alert: the editor, opened at the rule that raised it. The rule's screen
    /// follows once the editor is on screen (`takeRuleToOpen()`): pushed in the same breath, the
    /// second screen can come up without its title.
    func open(rule id: String) {
        if isOpen {
            editedRuleID = id
        } else {
            ruleToOpen = id
            isOpen = true
        }
    }

    /// The rule the editor was opened for, once.
    func takeRuleToOpen() -> String? {
        defer { ruleToOpen = nil }
        return ruleToOpen
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
        if !current.isDirty { settled() }
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
            saveFailure = HubError(error).errorDescription ?? "The hub did not save the alert settings."
            failures += 1
            return
        }
        // What the hub stored: topics trimmed, channels without an address switched off again.
        editor?.hubSaved(store.alerts.settings ?? body)
        settled()
        saves += 1
    }

    /// Throws the edits away.
    func revert() {
        editor?.revert()
        saveFailure = nil
        settled()
    }

    private func settled() {
        changedElsewhere = false
        isReplacingWebhook = false
    }

    // MARK: Editing

    /// One change to the draft, as a tap or a keystroke makes it.
    func edit(_ change: (inout AlertSettingsEditor) -> Void) {
        guard var current = editor else { return }
        change(&current)
        guard current != editor else { return }
        editor = current
        saveFailure = nil
        if !current.isDirty { settled() }
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

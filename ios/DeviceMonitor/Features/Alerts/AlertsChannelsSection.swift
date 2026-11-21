import DMCore
import SwiftUI
import UIKit

/// Where the hub sends alerts: to the apps over its live connection, to phones through ntfy, to
/// a chat webhook. Each is a switch; ntfy and the webhook show their fields while they are on.
struct AlertsChannelsSection: View {
    let model: AlertsEditorModel
    let editor: AlertSettingsEditor
    let issues: [AlertIssue]
    var focus: FocusState<AlertsField?>.Binding

    var body: some View {
        let channels = editor.settings.channels
        SettingsSection("Send alerts to") {
            SettingsToggleRow(
                AlertsChannel.apps, description: "This app and the desktop apps, over the hub's live connection.",
                isOn: Binding(get: { channels.desktop }, set: { on in model.edit { $0.setAppNotifications(on) } })
            )
            .accessibilityIdentifier("alerts-channel-apps-toggle")

            SettingsToggleRow(
                AlertsChannel.ntfy,
                description: "Instant push to a phone, also while this app is not running. Install the free ntfy app and subscribe to your topic.",
                isOn: Binding(get: { channels.ntfy.enabled }, set: { on in model.edit { $0.setNtfyEnabled(on) } })
            )
            .accessibilityIdentifier("alerts-ntfy-toggle")
            if channels.ntfy.enabled {
                ntfyFields(channels.ntfy)
            }

            SettingsToggleRow(
                AlertsChannel.webhook, description: "Posts each alert to a chat webhook: Discord, Slack, or anything that takes JSON.",
                isOn: Binding(get: { channels.webhook.enabled }, set: { on in model.edit { $0.setWebhookEnabled(on) } })
            )
            .accessibilityIdentifier("alerts-webhook-toggle")
            if channels.webhook.enabled {
                AlertsWebhookRows(model: model, editor: editor, issue: issue(.webhookURL), focus: focus)
            }
        }
    }

    @ViewBuilder
    private func ntfyFields(_ ntfy: AlertChannels.Ntfy) -> some View {
        AlertsFieldRow(
            title: "Topic", hint: "Choose a name that is hard to guess: whoever knows it can read your alerts.",
            placeholder: "my-devices-7f3k", text: Binding(get: { ntfy.topic }, set: { text in model.edit { $0.setNtfyTopic(text) } }),
            issue: issue(.ntfyTopic), field: .topic, focus: focus, identifier: "alerts-ntfy-topic-field", keyboard: .asciiCapable
        ) {
            if ntfy.topic.isEmpty {
                Button("Suggest a topic") { model.edit { $0.setNtfyTopic(AlertsTopic.suggestion()) } }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("alerts-ntfy-suggest-button")
            }
        }
        AlertsFieldRow(
            title: "Server", hint: "Only different when you run an ntfy server of your own.",
            placeholder: AlertChannels.Ntfy.defaultServer, text: Binding(get: { ntfy.server }, set: { text in model.edit { $0.setNtfyServer(text) } }),
            issue: issue(.ntfyServer), field: .server, focus: focus, identifier: "alerts-ntfy-server-field", keyboard: .URL, contentType: .URL
        )
        AlertsFieldRow(
            title: "Email", hint: "Optional. ntfy also sends each alert to this address.",
            placeholder: "name@example.com", text: Binding(get: { ntfy.email }, set: { text in model.edit { $0.setNtfyEmail(text) } }),
            issue: issue(.ntfyEmail), field: .email, focus: focus, identifier: "alerts-ntfy-email-field", keyboard: .emailAddress,
            contentType: .emailAddress
        )
    }

    private func issue(_ field: AlertIssue.Field) -> AlertIssue? {
        issues.first { $0.field == field }
    }
}

nonisolated enum AlertsTopic {
    /// A topic nobody will guess. On the public ntfy server a topic is all that keeps alerts private.
    static func suggestion() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return "device-monitor-" + String((0..<12).map { _ in letters[Int.random(in: 0..<letters.count, using: &generator)] })
    }
}

/// The webhook's address. The hub never gives a stored address back, so there are four cases:
/// nothing stored (a field), one stored and kept ("A webhook URL is saved", Replace, Remove),
/// one being replaced (a field, and a way back), one being removed (a way back, and a field).
private struct AlertsWebhookRows: View {
    let model: AlertsEditorModel
    let editor: AlertSettingsEditor
    let issue: AlertIssue?
    var focus: FocusState<AlertsField?>.Binding

    var body: some View {
        let url = editor.settings.channels.webhook.url
        if editor.removesStoredWebhook {
            AlertsRow {
                AlertsRowText(title: "The saved URL will be removed", description: "Saving makes the hub forget it. Enter another below, or keep it.")
                Button("Keep the saved URL") { keep() }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("alerts-webhook-keep-button")
            }
            .accessibilityIdentifier("alerts-webhook-removing")
            field
        } else if editor.hasStoredWebhook, url.isEmpty, !model.isReplacingWebhook {
            AlertsRow {
                AlertsRowText(title: "A webhook URL is saved", description: "The hub keeps it to itself: it is never shown again.")
                    .accessibilityIdentifier("alerts-webhook-saved")
                HStack(spacing: Theme.Spacing.s) {
                    Button("Replace") {
                        model.isReplacingWebhook = true
                        focus.wrappedValue = .webhook
                    }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("alerts-webhook-replace-button")
                    Button("Remove") { model.edit { $0.removeWebhookURL() } }
                        .buttonStyle(.dm(.destructive, size: .small))
                        .accessibilityIdentifier("alerts-webhook-remove-button")
                }
            }
        } else {
            field
        }
    }

    private var field: some View {
        AlertsFieldRow(
            title: "Webhook URL", hint: nil, placeholder: editor.webhookPlaceholder,
            text: Binding(get: { editor.settings.channels.webhook.url }, set: { text in model.edit { $0.setWebhookURL(text) } }),
            issue: issue, field: .webhook, focus: focus, identifier: "alerts-webhook-url-field", keyboard: .URL, contentType: .URL
        ) {
            if editor.hasStoredWebhook, !editor.removesStoredWebhook {
                Button("Keep the saved URL") { keep() }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("alerts-webhook-keep-button")
            }
        }
    }

    private func keep() {
        model.edit { $0.keepStoredWebhookURL() }
        model.isReplacingWebhook = false
        focus.wrappedValue = nil
    }
}

/// A titled text field of the editor with what the presentation layer says about its content
/// underneath, and room for a button of its own.
struct AlertsFieldRow<Accessory: View>: View {
    private let title: String
    private let hint: String?
    private let placeholder: String
    @Binding private var text: String
    private let issue: AlertIssue?
    private let field: AlertsField
    private let focus: FocusState<AlertsField?>.Binding
    private let identifier: String
    private let keyboard: UIKeyboardType
    private let contentType: UITextContentType?
    private let accessory: Accessory

    init(
        title: String, hint: String?, placeholder: String, text: Binding<String>, issue: AlertIssue?, field: AlertsField,
        focus: FocusState<AlertsField?>.Binding, identifier: String, keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil, @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.hint = hint
        self.placeholder = placeholder
        _text = text
        self.issue = issue
        self.field = field
        self.focus = focus
        self.identifier = identifier
        self.keyboard = keyboard
        self.contentType = contentType
        self.accessory = accessory()
    }

    var body: some View {
        AlertsRow {
            AlertsRowText(title: title, description: hint)
            TextField(title, text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { focus.wrappedValue = nil }
                .focused(focus, equals: field)
                // The field look asks for 40 points; a touch target wants 44.
                .frame(minHeight: 44)
                .dmField(isInvalid: issue?.severity == .error)
                .accessibilityIdentifier(identifier)
            if let issue {
                AlertsIssueLabel(issue)
                    .accessibilityIdentifier(identifier + "-issue")
            }
            accessory
        }
    }
}

extension AlertsFieldRow where Accessory == EmptyView {
    init(
        title: String, hint: String?, placeholder: String, text: Binding<String>, issue: AlertIssue?, field: AlertsField,
        focus: FocusState<AlertsField?>.Binding, identifier: String, keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil
    ) {
        self.init(
            title: title, hint: hint, placeholder: placeholder, text: text, issue: issue, field: field, focus: focus,
            identifier: identifier, keyboard: keyboard, contentType: contentType
        ) { EmptyView() }
    }
}

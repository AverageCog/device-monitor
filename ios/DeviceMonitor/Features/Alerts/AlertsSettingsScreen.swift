import DMCore
import SwiftUI

/// The rules and channels editor: what the hub watches for and where it sends alerts, edited as
/// a draft and sent with Save (`PUT /api/alerts`). While the draft has no edits it follows
/// changes made elsewhere; with edits it keeps them and says that the hub has moved on.
/// "This iPhone" at the top is the exception: it is this device's own and applies at once.
struct AlertsSettingsScreen: View {
    @Bindable var model: AlertsEditorModel
    let directory: AlertsDirectory

    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var focus: AlertsField?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    if let editor = model.editor {
                        let unit = AlertsLaunch.unit(preferences.temperatureUnit)
                        let currency = store.energySettings?.currency
                        let issues = editor.issues(unit: unit, currency: currency)
                        AlertsEditorStatus(model: model, editor: editor)
                        AlertsDeviceSection(hubSendsToApps: editor.saved.channels.desktop)
                            .id(AlertsAnchor.iphone)
                        AlertsRulesSection(model: model, editor: editor, issues: issues, directory: directory, unit: unit, currency: currency)
                            .id(AlertsAnchor.rules)
                        AlertsChannelsSection(model: model, editor: editor, issues: issues, focus: $focus)
                            .id(AlertsAnchor.channels)
                        AlertsMessagesSection(model: model, editor: editor)
                            .id(AlertsAnchor.messages)
                        AlertsTestSection(model: model)
                            .id(AlertsAnchor.test)
                    } else {
                        AlertsLoadingView("Loading alert settings\u{2026}")
                            .accessibilityIdentifier("alerts-settings-loading")
                    }
                }
                .frame(maxWidth: AlertsLayout.formWidth)
                .padding(Theme.Layout.screenPadding(for: sizeClass))
                .alertsDebugWidth()
                .frame(maxWidth: .infinity)
                // A second tap on a save in flight, or typing into what is being sent, would be lost.
                .disabled(model.isSaving)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("screen-alert-settings")
            .task {
                // DEBUG launch argument only: open further down.
                guard let anchor = AlertsLaunch.settingsAnchor else { return }
                try? await Task.sleep(for: .milliseconds(700))
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        // A pushed screen draws its own page background; the tab shell only dresses the first one.
        .dmScreen()
        .navigationTitle("Alert settings")
        .navigationBarTitleDisplayMode(.inline)
        // With edits, the way out is Save or Cancel: a swipe back must not lose them silently.
        .navigationBarBackButtonHidden(model.isDirty)
        .toolbar {
            if model.isDirty {
                ToolbarItem(placement: .cancellationAction) { AlertsCancelButton(model: model) }
            }
            AlertsSaveItem(model: model, store: store)
        }
        .navigationDestination(item: $model.editedRuleID) { id in
            AlertsRuleScreen(model: model, ruleID: id, directory: directory)
        }
        .task {
            // Opened from "Edit rule" on an alert: on to the rule, once this screen has arrived.
            guard let rule = model.takeRuleToOpen() else { return }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled, model.isOpen, model.editor?.rule(rule) != nil { model.editedRuleID = rule }
        }
        .modifier(AlertsPermissionRefresh())
        .modifier(AlertsFollowHub(model: model))
        .sensoryFeedback(.success, trigger: model.saves + model.tests)
        .sensoryFeedback(.error, trigger: model.failures)
    }
}

/// The text fields of the editor, for moving the keyboard's focus.
nonisolated enum AlertsField: Hashable, Sendable {
    case topic, server, email, webhook
}

/// Save, in the editor and on a rule's screen alike: it always sends the whole draft.
struct AlertsSaveItem: ToolbarContent {
    let model: AlertsEditorModel
    let store: HubStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
                    .accessibilityLabel("Saving")
            } else if model.wasJustSaved, !model.isDirty {
                // In the button's place, where the eye already is, and without moving the form.
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .accessibilityHidden(true)
                    Text("Saved")
                        .dmFont(.bodyStrong)
                }
                .foregroundStyle(Theme.good)
                .padding(.horizontal, Theme.Spacing.s)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alerts-saved")
            } else {
                Button("Save") {
                    Task { await model.save(to: store) }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("alerts-save-button")
            }
        }
    }
}

/// Cancel takes the edits back, after asking: they may be a webhook address typed on a phone.
private struct AlertsCancelButton: View {
    let model: AlertsEditorModel
    @State private var isConfirming = AlertsLaunch.confirms(.discard)

    var body: some View {
        Button("Cancel") { isConfirming = true }
            .accessibilityIdentifier("alerts-cancel-button")
            .confirmationDialog("Discard your changes?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { model.revert() }
                    .accessibilityIdentifier("alerts-discard-confirm")
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("The alert settings go back to what the hub has.")
            }
    }
}

/// What the draft has to say for itself, above the form: a save that failed, a hub that has
/// moved on, fields that keep Save from working.
private struct AlertsEditorStatus: View {
    let model: AlertsEditorModel
    let editor: AlertSettingsEditor

    var body: some View {
        let hasErrors = editor.isDirty && editor.hasErrors
        if model.saveFailure != nil || model.changedElsewhere || hasErrors {
            VStack(spacing: Theme.Spacing.s) {
                if let failure = model.saveFailure {
                    BannerView("Not saved. \(failure)", kind: .critical)
                        .accessibilityIdentifier("alerts-save-error")
                }
                if model.changedElsewhere {
                    BannerView("These settings were changed on the hub while you were editing. Saving replaces them with yours.", kind: .warning)
                        .accessibilityIdentifier("alerts-changed-elsewhere")
                }
                if hasErrors {
                    BannerView("Some fields need to be put right before this can be saved.", kind: .warning)
                        .accessibilityIdentifier("alerts-has-errors")
                }
            }
        }
    }
}

// MARK: - Rules

/// The rules: a one-line summary and a switch each, and a way to add one.
private struct AlertsRulesSection: View {
    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router
    let model: AlertsEditorModel
    let editor: AlertSettingsEditor
    let issues: [AlertIssue]
    let directory: AlertsDirectory
    let unit: TemperatureUnit
    let currency: String?

    var body: some View {
        let rules = editor.settings.rules
        let hasPrice = AlertsLaunch.priceSet(store.alerts.priceSet)
        SettingsSection("Rules", footer: "The hub checks its rules as devices report, whether or not this app is open.") {
            if rules.isEmpty {
                AlertsRow {
                    AlertsRowText(title: "No rules", description: "Nothing is being watched. Add a rule, or bring back the four a hub starts with.")
                }
                .accessibilityIdentifier("alerts-rules-empty")
            }
            ForEach(rules) { rule in
                AlertsRuleRow(
                    rule: rule,
                    issues: issues.filter { $0.ruleID == rule.id },
                    deviceName: directory.name(of: rule.device),
                    unit: unit, currency: currency,
                    needsPrice: rule.type == .dailyCost && !hasPrice,
                    isOn: Binding(get: { rule.enabled }, set: { enabled in model.edit { $0.setEnabled(enabled, for: rule.id) } }),
                    open: { model.editedRuleID = rule.id },
                    delete: { model.deleteRule(rule.id) },
                    setPrice: { router.showElectricityPrice() }
                )
            }
            AlertsRow {
                // Side by side while they fit; one under the other at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) { addButtons(rules) }
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) { addButtons(rules) }
                }
                if !editor.canAddRule {
                    Text("The hub keeps \(AlertRuleCatalog.maxRules) rules at most.")
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                if let issue = issues.first(where: { $0.field == .rules }) {
                    AlertsIssueLabel(issue)
                }
            }
        }
    }

    @ViewBuilder
    private func addButtons(_ rules: [AlertRule]) -> some View {
        Menu {
            ForEach(AlertRuleCatalog.specs) { spec in
                Button {
                    model.addRule(spec.kind)
                } label: {
                    Label(spec.label, systemImage: AlertsGlyph.symbol(for: spec.kind))
                }
            }
        } label: {
            Label("Add rule", systemImage: "plus")
        }
        .buttonStyle(.dm(size: .small))
        .disabled(!editor.canAddRule)
        .accessibilityIdentifier("alerts-add-rule-button")
        if rules.isEmpty {
            Button("Restore defaults") { model.edit { $0.restoreDefaultRules() } }
                .buttonStyle(.dm(size: .small))
                .accessibilityIdentifier("alerts-restore-rules-button")
        }
    }
}

/// One rule in the list: what it watches for in the words of the alert it raises, the device,
/// and its switch. The text opens the rule; the switch only switches.
private struct AlertsRuleRow: View {
    let rule: AlertRule
    let issues: [AlertIssue]
    let deviceName: String
    let unit: TemperatureUnit
    let currency: String?
    let needsPrice: Bool
    let isOn: Binding<Bool>
    let open: () -> Void
    let delete: () -> Void
    let setPrice: () -> Void

    var body: some View {
        let title = AlertsRuleWording.title(of: rule, issues: issues, unit: unit, currency: currency)
        AlertsRow {
            HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                Button(action: open) {
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .dmFont(.rowTitle)
                                .foregroundStyle(rule.enabled ? Theme.textPrimary : Theme.textMuted)
                            Text(deviceName)
                                .dmFont(.callout)
                                .foregroundStyle(rule.enabled ? Theme.textSecondary : Theme.textMuted)
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(deviceName)")
                .accessibilityHint("Edits this rule")
                .accessibilityIdentifier("alert-rule-\(rule.id)")

                // The design system's switch, without a label of its own: 44 points high to touch.
                Toggle(isOn: isOn) {
                    Color.clear.frame(width: 0, height: 44)
                }
                .toggleStyle(.dm)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityIdentifier("alert-rule-toggle-\(rule.id)")
            }
            ForEach(issues, id: \.self) { issue in
                AlertsIssueLabel(issue)
            }
            if needsPrice {
                AlertsPriceNotice(setPrice: setPrice)
            }
        }
        .contextMenu {
            Button(action: open) { Label("Edit rule", systemImage: "slider.horizontal.3") }
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Label(rule.enabled ? "Turn off" : "Turn on", systemImage: rule.enabled ? "bell.slash" : "bell")
            }
            Button(role: .destructive, action: delete) { Label("Delete rule", systemImage: "trash") }
        }
    }
}

/// How a rule is named where there is one line for it.
nonisolated enum AlertsRuleWording {
    /// The condition in the hub's words ("CPU temperature above 90°C for 2 min"). A rule whose
    /// limit is missing or out of range has no such sentence yet, and goes by what it watches.
    static func title(of rule: AlertRule, issues: [AlertIssue], unit: TemperatureUnit, currency: String?) -> String {
        guard AlertRuleCatalog.spec(for: rule.type) != nil, !issues.contains(where: { $0.severity == .error }) else { return rule.type.label }
        return AlertText.condition(of: rule, unit: unit, currency: currency)
    }
}

/// Under a daily-cost rule while the hub has no electricity price: says so, and leads to the
/// price sheet.
struct AlertsPriceNotice: View {
    let setPrice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            AlertsIssueLabel(AlertText.needsPrice, isError: false)
            Button("Set electricity price", action: setPrice)
                .buttonStyle(.dm(size: .small))
                .accessibilityIdentifier("alerts-set-price-button")
        }
    }
}

// MARK: - Messages

/// What the hub writes and when: resolved alerts, and the unit of temperatures in its texts.
private struct AlertsMessagesSection: View {
    let model: AlertsEditorModel
    let editor: AlertSettingsEditor

    var body: some View {
        SettingsSection("Messages") {
            SettingsToggleRow(
                "Also notify when an alert resolves", description: "A second message when things are back to normal.",
                isOn: Binding(get: { editor.settings.notifyResolved }, set: { on in model.edit { $0.setNotifyResolved(on) } })
            )
            .accessibilityIdentifier("alerts-notify-resolved-toggle")
            AlertsRow {
                AlertsSplitRow("Temperature unit", description: "How alert titles and messages write temperatures.") {
                    DMSegmentedControl(
                        "Temperature unit in alert messages",
                        selection: Binding(get: { editor.settings.tempUnit }, set: { unit in model.edit { $0.setTemperatureUnit(unit) } }),
                        segments: [
                            DMSegment(TemperatureUnit.celsius, TemperatureUnit.celsius.symbol, identifier: "C"),
                            DMSegment(TemperatureUnit.fahrenheit, TemperatureUnit.fahrenheit.symbol, identifier: "F"),
                        ],
                        identifier: "alerts-message-unit"
                    )
                }
            }
        }
    }
}

// MARK: - Test

/// "Send test alert", and how it went on each channel.
private struct AlertsTestSection: View {
    @Environment(HubStore.self) private var store
    let model: AlertsEditorModel

    var body: some View {
        let isSending = model.test == .sending
        SettingsSection("Test", footer: footer) {
            AlertsRow {
                AlertsSplitRow("Send test alert", description: "Goes to every channel that is on.") {
                    Button(isSending ? "Sending\u{2026}" : "Send") {
                        Task { await model.sendTest(through: store) }
                    }
                    .buttonStyle(.dm(size: .small))
                    .disabled(isSending || model.isDirty)
                    .accessibilityIdentifier("alerts-test-button")
                }
            }
            switch model.test {
            case .sent(let report):
                ForEach(report.lines) { line in
                    AlertsTestLine(line: line)
                }
            case .failed(let reason):
                AlertsRow {
                    AlertsIssueLabel("The test was not sent. \(reason)", isError: true)
                        .accessibilityIdentifier("alerts-test-error")
                }
            case .idle, .sending:
                EmptyView()
            }
        }
    }

    private var footer: String {
        model.isDirty
            ? "Save your changes first: a test uses the settings the hub has."
            : "A test also shows on this \(AlertsLayout.deviceName) when \u{201C}\(AlertsDeviceNotifications.title)\u{201D} is on."
    }
}

private struct AlertsTestLine: View {
    let line: AlertsTestReport.Line

    var body: some View {
        AlertsRow {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(line.channel)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.s)
                Text(line.text)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
            }
            .dmFont(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.channel)
        .accessibilityValue(line.text)
        .accessibilityIdentifier("alerts-test-result-\(line.id)")
    }

    private var symbol: String {
        switch line.outcome {
        case .off: "minus.circle"
        case .sent, .delivered: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch line.outcome {
        case .off: Theme.textMuted
        case .sent, .delivered: Theme.good
        case .failed: Theme.dangerText
        }
    }
}

/// The editor on the demo hub, for previews.
struct AlertsSettingsPreview: View {
    @Environment(HubStore.self) private var store
    @State private var model = AlertsEditorModel()
    var ruleKind: AlertRule.Kind?

    var body: some View {
        AlertsSettingsScreen(model: model, directory: AlertsDirectory(store.devices))
            .onChange(of: store.alerts.settings, initial: true) { _, settings in
                if let ruleKind, model.editedRuleID == nil {
                    model.editedRuleID = settings?.rules.first { $0.type == ruleKind }?.id
                }
            }
    }
}

#Preview("Alert settings") {
    NavigationStack { AlertsSettingsPreview().dmScreen() }
        .demoEnvironment(tab: .alerts)
}

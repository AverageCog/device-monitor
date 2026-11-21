import DMCore
import SwiftUI

/// One rule of the draft: what it watches, on which device, above which limit and for how long.
/// Every change goes into the editor's draft at once; Save (here or one screen back) sends the
/// whole draft to the hub.
///
/// Limits are shown and typed in the unit this device displays temperatures in, and kept in the
/// hub's (°C): `AlertThresholds` converts, and `AlertValidation` words what is wrong.
struct AlertsRuleScreen: View {
    let model: AlertsEditorModel
    let ruleID: String
    let directory: AlertsDirectory

    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var limitText = ""
    @State private var minutesText = ""
    @State private var isConfirmingDelete = AlertsLaunch.confirms(.delete)
    @FocusState private var focus: AlertsRuleField?

    var body: some View {
        let unit = AlertsLaunch.unit(preferences.temperatureUnit)
        let currency = store.energySettings?.currency
        let rule = model.editor?.rule(ruleID)
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                if let rule, let editor = model.editor {
                    form(rule, issues: editor.issues(forRule: ruleID, unit: unit, currency: currency), unit: unit, currency: currency)
                }
            }
            .frame(maxWidth: AlertsLayout.formWidth)
            .padding(Theme.Layout.screenPadding(for: sizeClass))
            .alertsDebugWidth()
            .frame(maxWidth: .infinity)
            .disabled(model.isSaving)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("screen-alert-rule")
        .dmScreen()
        .navigationTitle(rule?.type.label ?? "Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AlertsSaveItem(model: model, store: store)
            // The number pads have no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
                    .accessibilityIdentifier("alert-rule-keyboard-done")
            }
        }
        .modifier(AlertsFollowHub(model: model))
        .sensoryFeedback(.success, trigger: model.saves)
        .sensoryFeedback(.error, trigger: model.failures)
        // What the fields show follows the draft whenever it changes by other means than typing:
        // another kind (new defaults), Cancel, the stepper, a change on the hub.
        .onChange(of: rule?.threshold, initial: true) { syncLimit(unit) }
        .onChange(of: rule?.type) { syncLimit(unit) }
        .onChange(of: unit) { syncLimit(unit) }
        .onChange(of: rule?.minutes, initial: true) { syncMinutes() }
        .onChange(of: limitText) { _, text in
            model.edit { $0.setThreshold(of: ruleID, toText: text, unit: unit) }
        }
        .onChange(of: minutesText) { _, text in
            let digits = text.filter { $0.isASCII && $0.isNumber }
            if digits != text { minutesText = digits }
            // An empty field is no minutes at all, as it is for the hub.
            model.edit { $0.setMinutes(of: ruleID, to: digits.isEmpty ? 0 : Int(digits) ?? Int.max) }
        }
        // Deleted here, or gone from the hub while the draft had no edits.
        .onChange(of: rule == nil) { _, gone in
            if gone, model.editedRuleID == ruleID { model.editedRuleID = nil }
        }
    }

    // MARK: Form

    @ViewBuilder
    private func form(_ rule: AlertRule, issues: [AlertIssue], unit: TemperatureUnit, currency: String?) -> some View {
        let spec = AlertRuleCatalog.spec(for: rule.type)
        if let failure = model.saveFailure {
            BannerView("Not saved. \(failure)", kind: .critical)
                .accessibilityIdentifier("alerts-save-error")
        }
        AlertsRuleSummary(rule: rule, issues: issues, deviceName: directory.name(of: rule.device), unit: unit, currency: currency)

        SettingsSection(footer: spec == nil ? "This kind of rule is newer than the app. It can be switched off or deleted here, and changed on the hub." : nil) {
            SettingsToggleRow("Enabled", isOn: Binding(get: { rule.enabled }, set: { on in model.edit { $0.setEnabled(on, for: ruleID) } }))
                .accessibilityIdentifier("alert-rule-enabled-toggle")
            if spec != nil {
                AlertsRow {
                    AlertsSplitRow("Type") {
                        AlertsSelect(
                            "Type", selection: Binding(get: { rule.type }, set: { kind in model.edit { $0.setKind(of: ruleID, to: kind) } }),
                            options: AlertRuleCatalog.specs.map { DMSegment($0.kind, $0.label) }, identifier: "alert-rule-kind-picker"
                        )
                    }
                }
                AlertsRow {
                    AlertsSplitRow("Device") {
                        AlertsSelect(
                            "Device", selection: Binding(get: { rule.device }, set: { device in model.edit { $0.setDevice(of: ruleID, to: device) } }),
                            options: deviceOptions(for: rule), identifier: "alert-rule-device-picker"
                        )
                    }
                    if let issue = issues.first(where: { $0.field == .ruleDevice(ruleID: ruleID) }) {
                        AlertsIssueLabel(issue)
                    }
                }
            }
        }

        if let spec, spec.thresholdRange != nil || spec.usesDuration {
            SettingsSection("Condition") {
                if spec.thresholdRange != nil {
                    limitRow(rule, issue: issues.first { $0.field == .ruleThreshold(ruleID: ruleID) }, unit: unit, currency: currency)
                }
                if spec.usesDuration {
                    durationRow(rule, spec: spec, issue: issues.first { $0.field == .ruleMinutes(ruleID: ruleID) })
                }
                if rule.type == .dailyCost, !AlertsLaunch.priceSet(store.alerts.priceSet) {
                    AlertsRow {
                        AlertsPriceNotice { router.showElectricityPrice() }
                    }
                }
            }
        }

        Button("Delete rule", role: .destructive) { isConfirmingDelete = true }
            .buttonStyle(.dm(.destructive, fillsWidth: true))
            .accessibilityIdentifier("alert-rule-delete-button")
            .alertsDebugConfirm(.delete, isPresented: $isConfirmingDelete)
            .confirmationDialog("Delete this rule?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete rule", role: .destructive) { model.deleteRule(ruleID) }
                    .accessibilityIdentifier("alert-rule-delete-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It is gone from the hub once you save.")
            }
    }

    private func limitRow(_ rule: AlertRule, issue: AlertIssue?, unit: TemperatureUnit, currency: String?) -> some View {
        let unitLabel = AlertThresholds.unitLabel(kind: rule.type, unit: unit, currency: currency)
        return AlertsRow {
            AlertsSplitRow("Limit") {
                HStack(spacing: Theme.Spacing.s) {
                    AlertsNumberField(title: "Limit", text: $limitText, isInvalid: issue != nil, width: 76, field: .limit, focus: $focus)
                        .keyboardType(.decimalPad)
                        .accessibilityValue(limitText.isEmpty ? "Empty" : "\(limitText) \(unitLabel)")
                        .accessibilityIdentifier("alert-rule-limit-field")
                    if !unitLabel.isEmpty {
                        AlertsUnitLabel(unitLabel)
                    }
                }
            }
            if let issue {
                AlertsIssueLabel(issue)
                    .accessibilityIdentifier("alert-rule-limit-issue")
            } else {
                AlertsRowNote(rule.type == .dailyCost ? "Alerts once today's electricity has cost more than this." : "Alerts when the reading goes above it.")
            }
        }
    }

    private func durationRow(_ rule: AlertRule, spec: AlertRuleSpec, issue: AlertIssue?) -> some View {
        let range = spec.minutesRange
        return AlertsRow {
            AlertsSplitRow("Duration") {
                HStack(spacing: Theme.Spacing.s) {
                    AlertsNumberField(title: "Duration in minutes", text: $minutesText, isInvalid: issue != nil, width: 52, field: .minutes, focus: $focus)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("alert-rule-minutes-field")
                    AlertsUnitLabel("min")
                    Stepper(
                        "Duration in minutes",
                        value: Binding(
                            get: { min(max(rule.minutes, range.lowerBound), range.upperBound) },
                            set: { minutes in model.edit { $0.setMinutes(of: ruleID, to: minutes) } }
                        ),
                        in: range
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("alert-rule-minutes-stepper")
                }
            }
            if let issue {
                AlertsIssueLabel(issue)
                    .accessibilityIdentifier("alert-rule-minutes-issue")
            } else {
                AlertsRowNote(
                    rule.type == .offline
                        ? "How long a device must be silent before the alert."
                        : "How long the reading must stay above the limit. 0 means at once."
                )
            }
        }
    }

    /// "All devices", every device the hub knows, and the rule's own device when it is gone.
    private func deviceOptions(for rule: AlertRule) -> [DMSegment<String>] {
        var options = [DMSegment(AlertRule.allDevices, AlertText.allDevices)]
        options += directory.devices.map { DMSegment($0.id, $0.displayName) }
        if !options.contains(where: { $0.value == rule.device }) {
            options.append(DMSegment(rule.device, directory.name(of: rule.device)))
        }
        return options
    }

    // MARK: Fields and draft

    /// Refills the limit's field unless what it shows already stands for the draft's limit, so
    /// typing is never rewritten under the user's hands.
    private func syncLimit(_ unit: TemperatureUnit) {
        guard let rule = model.editor?.rule(ruleID) else { return }
        let typed = NumberEntry.parse(limitText).map {
            AlertThresholds.storedValue(fromDisplay: $0, kind: rule.type, unit: unit, current: rule.threshold)
        }
        if typed != rule.threshold {
            limitText = AlertThresholds.fieldText(rule.threshold, kind: rule.type, unit: unit)
        }
    }

    private func syncMinutes() {
        guard let rule = model.editor?.rule(ruleID) else { return }
        let typed = minutesText.isEmpty ? 0 : Int(minutesText) ?? Int.max
        // An emptied field stands for 0 while it is being typed in, and is filled in otherwise.
        if typed != rule.minutes || (minutesText.isEmpty && focus != .minutes) {
            minutesText = String(rule.minutes)
        }
    }
}

nonisolated enum AlertsRuleField: Hashable, Sendable {
    case limit, minutes
}

/// The unit after a number field. It keeps its width: the text beside it wraps instead.
private struct AlertsUnitLabel: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .dmFont(.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A line of explanation under a row's control.
private struct AlertsRowNote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .dmFont(.callout)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short right-aligned number field in the dashboard's field look.
private struct AlertsNumberField: View {
    let title: String
    @Binding var text: String
    let isInvalid: Bool
    let width: CGFloat
    let field: AlertsRuleField
    let focus: FocusState<AlertsRuleField?>.Binding

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        TextField(title, text: $text)
            // The title does not reach VoiceOver by itself.
            .accessibilityLabel(title)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused(focus, equals: field)
            .frame(width: width * min(scale, 1.8))
            .frame(minHeight: 44)
            .dmField(isInvalid: isInvalid)
    }
}

/// The rule in one sentence, as its alert will read, with the device and when it clears.
private struct AlertsRuleSummary: View {
    let rule: AlertRule
    let issues: [AlertIssue]
    let deviceName: String
    let unit: TemperatureUnit
    let currency: String?

    var body: some View {
        let title = AlertsRuleWording.title(of: rule, issues: issues, unit: unit, currency: currency)
        let isSound = !issues.contains { $0.severity == .error }
        let clearing = isSound ? AlertText.clearing(of: rule, unit: unit, currency: currency) : ""
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AlertsIconPlate(symbol: AlertsGlyph.symbol(for: rule.type), tint: rule.enabled ? Theme.accent : Theme.textMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .dmFont(.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(rule.enabled ? deviceName : "\(deviceName) \u{B7} Off")
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textSecondary)
                if !clearing.isEmpty {
                    Text(clearing)
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Layout.cardPadding)
        .dmSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alert-rule-summary")
    }
}

#Preview("Rule") {
    NavigationStack { AlertsSettingsPreview(ruleKind: .cpuTemp).dmScreen() }
        .demoEnvironment(tab: .alerts)
}

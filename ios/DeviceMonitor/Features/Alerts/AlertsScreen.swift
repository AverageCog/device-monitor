import DMCore
import SwiftUI

/// The Alerts tab: what is firing now and the hub's log of what fired and cleared, kept current
/// by the live stream. The hub evaluates the rules (alerts.js) and the web dashboard has no page
/// for them, so this screen is the app's own, drawn with the dashboard's surfaces and type.
/// Its toolbar leads to the rules and channels (`AlertsSettingsScreen`).
struct AlertsScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The draft of the alert settings. Here, not in the editor, so it outlives a visit there.
    @State private var model = AlertsEditorModel()
    @State private var directory = AlertsDirectory()
    @State private var dayStart: Double = 0
    @State private var showsSettings = AlertsLaunch.opensSettings
    @State private var loadFailure: String? = AlertsLaunch.loadFailure
    @State private var isRetrying = false

    var body: some View {
        // What is on show; a DEBUG launch argument can stand in for the hub's answer.
        let alerts = AlertsLaunch.shown(store.alerts)
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, and directly in the scroll view: the log can hold 150 entries.
                LazyVStack(alignment: .leading, spacing: 0) {
                    AlertsDeviceBanner()
                    if alerts.isLoaded {
                        AlertsActiveSection(alerts: alerts, directory: directory, editRule: edit(rule:)) { showsSettings = true }
                        AlertsLogSection(alerts: alerts, dayStart: dayStart, directory: directory, editRule: edit(rule:))
                    } else if let loadFailure {
                        EmptyStateView(
                            title: "Can't load alerts", message: loadFailure, systemImage: "exclamationmark.triangle",
                            actionTitle: isRetrying ? "Trying\u{2026}" : "Try again"
                        ) {
                            Task { await load() }
                        }
                        .disabled(isRetrying)
                        .accessibilityIdentifier("alerts-load-error")
                    } else {
                        AlertsLoadingView("Loading alerts\u{2026}")
                            .accessibilityIdentifier("alerts-loading")
                    }
                }
                .frame(maxWidth: AlertsLayout.listWidth, alignment: .leading)
                .padding(Theme.Layout.screenPadding(for: sizeClass))
                .alertsDebugWidth()
                .frame(maxWidth: .infinity)
            }
            .refreshable { _ = try? await store.refreshAlerts() }
            .accessibilityIdentifier("screen-alerts")
            .task {
                // DEBUG launch argument only: open further down.
                guard let anchor = AlertsLaunch.listAnchor else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .navigationTitle("Alerts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsSettings = true
                } label: {
                    Label("Alert settings", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("alerts-settings-button")
            }
        }
        .navigationDestination(isPresented: $showsSettings) {
            AlertsSettingsScreen(model: model, directory: directory)
        }
        .background { AlertsStoreWatcher(directory: $directory, dayStart: $dayStart) }
        .modifier(AlertsPermissionRefresh())
        .onChange(of: store.alerts.settings, initial: true) { _, settings in model.follow(settings) }
        .onAppear { AlertsNotificationCenter.shared.clearDelivered() }
        .task {
            // The store asks with every connection. This is for when that answer never came.
            try? await Task.sleep(for: .seconds(1))
            if !store.alerts.isLoaded, loadFailure == nil { await load() }
        }
        .task { await AlertsLaunch.prepare(model, store: store) }
    }

    private func load() async {
        isRetrying = true
        defer { isRetrying = false }
        do {
            try await store.refreshAlerts()
            loadFailure = nil
        } catch {
            let failure = HubError(error)
            if failure != .cancelled { loadFailure = failure.errorDescription ?? "The hub did not answer." }
        }
    }

    /// "Edit rule" on an alert: the editor, opened at the rule that raised it.
    private func edit(rule id: String) {
        model.editedRuleID = id
        showsSettings = true
    }
}

/// The places a DEBUG launch argument can scroll to.
nonisolated enum AlertsAnchor: String, Hashable, Sendable {
    case history
    case iphone, rules, channels, messages, test
}

/// A spinner and a line of text, for something the hub has not answered yet.
struct AlertsLoadingView: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
                .tint(Theme.textSecondary)
            Text(text)
                .dmFont(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active

/// What an alert's menu offers.
nonisolated struct AlertsRowActions: Equatable, Sendable {
    /// The device whose history can be shown; nil for a rule over all devices and for a device that is gone.
    var historyDeviceID: String?
    /// The rule that raised it, while it still exists.
    var ruleID: String?

    var isEmpty: Bool { historyDeviceID == nil && ruleID == nil }

    init(device: String?, rule: String?, directory: AlertsDirectory, settings: AlertSettings?) {
        if let device, directory.contains(device) { historyDeviceID = device }
        if let rule, settings?.rules.contains(where: { $0.id == rule }) == true { ruleID = rule }
    }
}

/// "Active": everything firing now, or a calm word when nothing is.
private struct AlertsActiveSection: View {
    @Environment(HubStore.self) private var store
    let alerts: AlertsState
    let directory: AlertsDirectory
    let editRule: (String) -> Void
    let openSettings: () -> Void

    var body: some View {
        // The hub's heartbeat: "5m ago" moves with it, every three seconds, and nothing else here does.
        let _ = store.lastStatusAt
        let rows = AlertRows.activeRows(alerts.active, now: store.clock.now)
        let rules = Dictionary(alerts.active.map { ($0.id, $0.ruleId) }, uniquingKeysWith: { first, _ in first })

        AlertsHeading(AlertRows.activeHeading)
            .padding(.bottom, Theme.Spacing.xs)
        if rows.isEmpty {
            calm
                .dmSurface()
                .padding(.bottom, Theme.Spacing.xl)
        } else {
            ForEach(rows) { row in
                AlertsActiveCard(
                    row: row,
                    actions: AlertsRowActions(device: row.deviceID, rule: rules[row.id], directory: directory, settings: alerts.settings),
                    editRule: editRule
                )
                .padding(.bottom, row.id == rows.last?.id ? Theme.Spacing.xl : Theme.Spacing.s)
            }
        }
    }

    @ViewBuilder
    private var calm: some View {
        if alerts.settings?.rules.contains(where: \.enabled) ?? true {
            EmptyStateView(title: "All clear", message: AlertRows.noActiveAlerts, systemImage: "checkmark.circle", isCompact: true)
                .accessibilityIdentifier("alerts-all-clear")
        } else {
            // "All clear" would be a promise nobody is keeping.
            EmptyStateView(
                title: "No rules are on", message: "Nothing is being watched, so no alert can fire.", systemImage: "bell.slash",
                isCompact: true, actionTitle: "Alert settings", action: openSettings
            )
            .accessibilityIdentifier("alerts-no-rules")
        }
    }
}

/// One firing alert: the hub's title and message, since when, and a menu when there is
/// somewhere to go from it.
private struct AlertsActiveCard: View {
    let row: ActiveAlertRow
    let actions: AlertsRowActions
    let editRule: (String) -> Void

    var body: some View {
        AlertsRowMenu(actions: actions, label: row.spokenText, value: row.ago, editRule: editRule) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                AlertsIconPlate(symbol: AlertsGlyph.symbol(for: row.kind), tint: Theme.critical)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .dmFont(.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                    if !row.message.isEmpty {
                        Text(row.message)
                            .dmFont(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("\(row.since) \u{B7} \(row.ago)")
                        .dmFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 1)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !actions.isEmpty { AlertsMoreGlyph() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Theme.Spacing.m)
            .dmSurface()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .accessibilityIdentifier("alert-active-\(row.id.replacingOccurrences(of: "|", with: "-"))")
    }
}

/// The quiet "…" that says a row opens a menu, as on a device card.
private struct AlertsMoreGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// An alert that opens a menu when tapped: "Show history" for its device, "Edit rule" for the
/// rule that raised it. Without either it is plain content.
private struct AlertsRowMenu<Content: View>: View {
    @Environment(AppRouter.self) private var router
    private let actions: AlertsRowActions
    private let label: String
    private let value: String?
    private let editRule: (String) -> Void
    private let content: Content

    init(actions: AlertsRowActions, label: String, value: String? = nil, editRule: @escaping (String) -> Void, @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.label = label
        self.value = value
        self.editRule = editRule
        self.content = content()
    }

    var body: some View {
        if actions.isEmpty {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value ?? "")
        } else {
            Menu {
                if let device = actions.historyDeviceID {
                    Button {
                        router.openHistory(deviceID: device)
                    } label: {
                        Label("Show history", systemImage: AppTab.history.systemImage)
                    }
                }
                if let rule = actions.ruleID {
                    Button {
                        editRule(rule)
                    } label: {
                        Label("Edit rule", systemImage: "slider.horizontal.3")
                    }
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint("Shows actions for this alert")
        }
    }
}

// MARK: - History

/// "History": the hub's log by day, newest first, and the way to empty it.
private struct AlertsLogSection: View {
    @Environment(HubStore.self) private var store
    let alerts: AlertsState
    let dayStart: Double
    let directory: AlertsDirectory
    let editRule: (String) -> Void

    @State private var isConfirming = AlertsLaunch.confirms(.clear)
    @State private var isClearing = false
    @State private var failure: String?
    @State private var cleared = 0

    var body: some View {
        // Today and Yesterday are told from the day the watcher reports; before its first word, from the clock.
        let sections = AlertRows.logSections(alerts.events, now: dayStart > 0 ? dayStart : store.clock.now)
        let rules = Dictionary(alerts.events.map { ($0.id, $0.ruleId) }, uniquingKeysWith: { first, _ in first })

        AlertsHeading(AlertRows.logHeading) {
            if !sections.isEmpty { clearButton }
        }
        .padding(.bottom, Theme.Spacing.xs)
        .id(AlertsAnchor.history)
        if sections.isEmpty {
            EmptyStateView(message: AlertRows.emptyLog, isCompact: true)
                .dmSurface()
                .accessibilityIdentifier("alerts-log-empty")
        } else {
            ForEach(sections) { section in
                Text(section.title)
                    .dmFont(.captionStrong)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.top, section.id == sections.first?.id ? 2 : Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.s)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(section.rows) { row in
                        if row.id != section.rows.first?.id { Hairline() }
                        AlertsEventRow(
                            row: row,
                            actions: AlertsRowActions(device: row.deviceID, rule: rules[row.id] ?? nil, directory: directory, settings: alerts.settings),
                            editRule: editRule
                        )
                    }
                }
                .padding(.horizontal, 14)
                .dmSurface()
            }
        }
    }

    private var clearButton: some View {
        Button("Clear log") { isConfirming = true }
            .buttonStyle(.dm(size: .small))
            .disabled(isClearing)
            .accessibilityIdentifier("alerts-clear-log-button")
            .confirmationDialog("Clear the alert log?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Clear log", role: .destructive) {
                    Task { await clear() }
                }
                .accessibilityIdentifier("alerts-clear-log-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every entry is removed from the hub, for everyone who uses it. Alerts that are firing stay.")
            }
            .alert("The log was not cleared", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .sensoryFeedback(.success, trigger: cleared)
    }

    private func clear() async {
        isClearing = true
        defer { isClearing = false }
        do {
            try await store.clearAlertLog()
            cleared += 1
        } catch {
            failure = HubError(error).errorDescription ?? "The hub did not answer."
        }
    }
}

/// One entry of the log. An alert and its "back to normal" differ in glyph and colour, and in
/// the word VoiceOver starts with.
private struct AlertsEventRow: View {
    let row: AlertEventRow
    let actions: AlertsRowActions
    let editRule: (String) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AlertsRowMenu(actions: actions, label: row.spokenText, editRule: editRule) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                AlertsIconPlate(symbol: symbol, tint: tint, side: 28)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if typeSize.isAccessibilitySize {
                        title
                        meta
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            title
                                .frame(maxWidth: .infinity, alignment: .leading)
                            meta
                        }
                    }
                    if !row.message.isEmpty {
                        Text(row.message)
                            .dmFont(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("alert-event-\(row.id)")
    }

    private var title: some View {
        Text(row.title)
            .dmFont(.rowTitle)
            .foregroundStyle(Theme.textPrimary)
    }

    /// "Resolved · 2:36 PM": the state in its colour, then the time.
    private var meta: some View {
        HStack(spacing: 5) {
            if row.state != .firing {
                Text(row.state.label)
                    .foregroundStyle(tint)
                Text("\u{B7}")
                    .foregroundStyle(Theme.textMuted)
            }
            Text(row.time)
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
        }
        .dmFont(.caption)
        .lineLimit(1)
        .fixedSize()
    }

    private var symbol: String {
        switch row.state {
        case .firing, .other: AlertsGlyph.symbol(for: row.kind)
        case .resolved: "checkmark"
        case .test: "paperplane.fill"
        }
    }

    private var tint: Color {
        switch row.state {
        case .firing: Theme.critical
        case .resolved: Theme.good
        case .test: Theme.accent
        case .other: Theme.textMuted
        }
    }
}

#Preview("Alerts") {
    NavigationStack { AlertsScreen().dmScreen() }
        .demoEnvironment(tab: .alerts)
}

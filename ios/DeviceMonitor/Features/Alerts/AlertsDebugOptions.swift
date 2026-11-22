import DMCore
import SwiftUI
import UIKit

// DEBUG launch arguments of the Alerts tab, its editor and a rule's screen, so that every state
// can be opened without a tap (screenshots, UI tests). Combine them with `-dm-demo` or
// `-dm-phase live`, and `-dm-tab alerts`. None of them exists in a release build: there
// `AlertsLaunch` answers nil, false or "unchanged" to everything and reads nothing.
//
//     -dm-alerts-list <loading|error|empty|all-clear|no-rules|kinds>
//                                 the Alerts tab as if the hub had answered that way: not yet,
//                                 not at all, with nothing, with nothing firing, with every rule
//                                 off, or with the kinds of log entry a demo never has (a test
//                                 alert, an unknown state, no device, a device that is gone)
//     -dm-alerts-open settings    the editor ("Alert settings") is pushed
//     -dm-alerts-rule <n|kind|new:kind>
//                                 a rule's screen is opened the way "Edit rule" on an alert opens
//                                 it, editor and rule at once: the n-th rule (from 0), the first
//                                 of that kind (cpuTemp, offline, dailyCost…), or a rule of that
//                                 kind added as "Add rule" adds it
//     -dm-alerts-scroll <history|iphone|rules|channels|messages|test>
//                                 scrolled to that part (history: the tab; the others: the editor)
//     -dm-alerts-notify <undecided|off|asking|on|blocked>
//                                 "Notify on this iPhone" drawn in that state, whatever the
//                                 preference and the system's permission say. Two things on the
//                                 Alerts tab still follow the real session and preference: the
//                                 invitation (undecided, asking) is not shown in a demo, so look
//                                 at it with `-dm-phase live`; and the blocked banner is there
//                                 only while the preference is on (add `-dm.notifications YES`),
//                                 which its "Don't notify" switches off
//     -dm-alerts-confirm <clear|discard|delete>
//                                 that confirmation is up: clear the log, discard the edits
//                                 (needs an edit from the script), delete the rule on screen
//     -dm-alerts-confirm-after <seconds>
//                                 with -dm-alerts-confirm: the confirmation comes up that long
//                                 after its button, as it does after a tap, and not with it.
//                                 For reading identifiers: the system is handed the identifier
//                                 of a dialog's button only for a dialog made after something
//                                 first asked the app for its accessibility tree. Any UI test
//                                 that found the button to tap has asked; a screenshot of a
//                                 dialog that was up from the start has not
//     -dm-alerts-script step,step,…
//                                 done in order once the editor has the hub's settings, as taps
//                                 and typing would do it. A step is an edit of the draft,
//                                     apps|ntfy|webhook|resolved=on|off   topic|server|email|url=<text>
//                                     msgunit=C|F   replace=on   remove=on   rules=none
//                                     kind=<kind>   device=<id>   limit=<text>   minutes=<n>
//                                     enabled=on|off          (these five: the rule on screen)
//                                 or one of
//                                     save            Save
//                                     test            Send test alert
//                                     test-failed     a test result with a delivery that failed
//                                     back            leave the rule's screen for the editor
//                                     disk-alert      a demo hub raises a disk alert (see -dm-alerts-probe)
//                                     price           "Set electricity price": the shared price sheet
//                                     elsewhere       the hub's settings change behind the draft's
//                                                     back (offline after 45 min, resolved flipped)
//                                 e.g. webhook=on,url=https://chat.example/hook,save,replace=on
//     -dm-alerts-fail <save|test> the hub cannot be reached for that request (a stand-in: the
//                                 demo hub itself is left alone)
//     -dm-alerts-price none       as if the hub had no electricity price
//     -dm-alerts-unit <C|F>       limits shown in that unit; the stored preference is not touched
//     -dm-alerts-width <points>   lay these screens out at that width and shrink the picture to
//                                 fit, to look at an iPad's or a sideways phone's arrangement
//     -dm-alerts-probe            an invisible accessibility element on the Alerts tab,
//                                 `debug-alerts-notifier`, whose label lists what the notifier
//                                 did, e.g. "stream: up; log: 6 entries; notify: [] …; live:
//                                 <title>; notify: [<title>] posted". The script step `disk-alert`
//                                 has a demo hub raise an alert and clear it eight seconds later.
//                                 In a demo the trace ends "kept back, a demo" whatever the
//                                 preference; with `-dm-phase live -dm.notifications YES` it
//                                 ends "posted".
//
// `save` and `test` in a script go through the store like the buttons do, so on a demo hub they
// change that hub (which lives in memory, for this launch only).
#if DEBUG
nonisolated struct AlertsDebugOptions: Sendable {
    enum List: String, Sendable {
        case loading, error, empty, kinds
        case allClear = "all-clear"
        case noRules = "no-rules"
    }

    var list: List?
    var opensSettings = false
    var rule: String?
    var scroll: AlertsAnchor?
    var notice: String?
    var confirm: String?
    var confirmDelay: Double?
    var script: [String] = []
    var fails: String?
    var hasNoPrice = false
    var unit: TemperatureUnit?
    var width: CGFloat?
    var showsProbe = false

    static let current = AlertsDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        list = value(after: "-dm-alerts-list").flatMap(List.init(rawValue:))
        rule = value(after: "-dm-alerts-rule")
        opensSettings = value(after: "-dm-alerts-open") == "settings"
        scroll = value(after: "-dm-alerts-scroll").flatMap(AlertsAnchor.init(rawValue:))
        notice = value(after: "-dm-alerts-notify")
        confirm = value(after: "-dm-alerts-confirm")
        confirmDelay = value(after: "-dm-alerts-confirm-after").flatMap(Double.init).flatMap { $0 > 0 && $0 <= 120 ? $0 : nil }
        script = value(after: "-dm-alerts-script")?.split(separator: ",").map(String.init) ?? []
        fails = value(after: "-dm-alerts-fail")
        hasNoPrice = value(after: "-dm-alerts-price") == "none"
        unit = value(after: "-dm-alerts-unit").flatMap(TemperatureUnit.init(rawValue:))
        width = value(after: "-dm-alerts-width").flatMap(Double.init).flatMap { $0 >= 200 && $0 <= 2000 ? CGFloat($0) : nil }
        showsProbe = arguments.contains("-dm-alerts-probe")
    }
}

/// `-dm-alerts-probe`: what `AlertsNotifier` did, as one invisible accessibility element.
private struct AlertsNotifierProbe: View {
    var body: some View {
        // The notifier is not observable; once a second is often enough for a test to follow it.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(AlertsNotifier.shared.trace.joined(separator: "; "))
                .accessibilityIdentifier("debug-alerts-notifier")
        }
    }
}

/// `-dm-alerts-width`: the content at the asked width, drawn smaller.
private struct AlertsDebugWidth: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? width
        content
            .frame(width: width)
            .scaleEffect(min(1, screen / width), anchor: .top)
            .frame(width: min(width, screen))
    }
}
#endif

extension View {
    /// Applies `-dm-alerts-width` in a DEBUG build; the view itself otherwise.
    @ViewBuilder
    func alertsDebugWidth() -> some View {
        #if DEBUG
        if let width = AlertsDebugOptions.current.width {
            modifier(AlertsDebugWidth(width: width))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// `-dm-alerts-confirm-after`: brings a confirmation up a while after the button that asks
    /// for it has appeared. The view itself in a release build.
    @ViewBuilder
    func alertsDebugConfirm(_ confirmation: AlertsLaunch.Confirmation, isPresented: Binding<Bool>) -> some View {
        #if DEBUG
        task {
            guard let delay = AlertsLaunch.confirmDelay(confirmation) else { return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { isPresented.wrappedValue = true }
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Adds the `-dm-alerts-probe` element in a DEBUG build that was asked for it.
    @ViewBuilder
    func alertsDebugProbe() -> some View {
        #if DEBUG
        if AlertsDebugOptions.current.showsProbe {
            overlay(alignment: .topLeading) { AlertsNotifierProbe() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// What a DEBUG launch argument asked these screens to open with. In a release build every
/// answer is nil, false or the value it was given, and nothing is read.
nonisolated enum AlertsLaunch {
    enum Confirmation: String, Sendable {
        case clear, discard, delete
    }

    #if DEBUG
    private static var options: AlertsDebugOptions { .current }
    private static let unreachable = HubError.unreachable("The hub did not answer in time.")
    @MainActor private static var isPrepared = false

    static var opensSettings: Bool { options.opensSettings }
    static var loadFailure: String? { options.list == .error ? unreachable.errorDescription : nil }
    static var listAnchor: AlertsAnchor? { options.scroll == .history ? .history : nil }
    static var settingsAnchor: AlertsAnchor? { options.scroll == .history ? nil : options.scroll }
    static var saveFailure: HubError? { options.fails == "save" ? unreachable : nil }
    static var testFailure: HubError? { options.fails == "test" ? unreachable : nil }

    static var notice: AlertsDeviceNotice? {
        switch options.notice {
        case "undecided": .undecided
        case "off": .off
        case "asking": .asking
        case "on": .on
        case "blocked": .blocked
        default: nil
        }
    }

    static func confirms(_ confirmation: Confirmation) -> Bool {
        options.confirm == confirmation.rawValue && options.confirmDelay == nil
    }

    static func confirmDelay(_ confirmation: Confirmation) -> Duration? {
        guard options.confirm == confirmation.rawValue else { return nil }
        return options.confirmDelay.map { .seconds($0) }
    }

    static func unit(_ unit: TemperatureUnit) -> TemperatureUnit {
        options.unit ?? unit
    }

    static func priceSet(_ isSet: Bool) -> Bool {
        isSet && !options.hasNoPrice
    }

    /// The hub's alerts as `-dm-alerts-list` wants them seen.
    static func shown(_ alerts: AlertsState) -> AlertsState {
        guard let list = options.list else { return alerts }
        var alerts = alerts
        switch list {
        case .loading, .error:
            alerts.isLoaded = false
        case .empty:
            alerts.active = []
            alerts.events = []
        case .kinds:
            // What the demo's log never holds: a test alert, a state this app does not know, an
            // alert without a device, and one whose device and rule are gone.
            let newest = alerts.events.first?.t ?? 0
            alerts.events.insert(contentsOf: [
                AlertEvent(id: "sample-test", t: newest + 4000, title: "Device Monitor test alert", message: "Alerts from your hub will arrive like this.", test: true),
                AlertEvent(id: "sample-state", t: newest + 3000, type: .mem, device: "gaming", deviceName: "Gaming PC", state: .other("snoozed"), title: "Gaming PC: Memory use 93%", message: "Above 90% for 5 min."),
                AlertEvent(id: "sample-cost", t: newest + 2000, ruleId: "0", type: .dailyCost, device: AlertRule.allDevices, deviceName: "All devices", title: "All devices: electricity today is $5.12", message: "Over your $5.00 daily limit."),
                AlertEvent(id: "sample-gone", t: newest + 1000, ruleId: "0", type: .power, device: "gone", deviceName: "Old Laptop", state: .resolved, value: 40, title: "Old Laptop: Power draw back to normal", message: "Now 40 W (limit 90 W)."),
            ], at: 0)
        case .allClear:
            alerts.active = []
        case .noRules:
            alerts.active = []
            if var settings = alerts.settings {
                for index in settings.rules.indices { settings.rules[index].enabled = false }
                alerts.settings = settings
            }
        }
        return alerts
    }

    /// `-dm-alerts-rule` and `-dm-alerts-script`, once, when the editor has the hub's settings.
    @MainActor
    static func prepare(_ model: AlertsEditorModel, store: HubStore) {
        guard !isPrepared, options.rule != nil || !options.script.isEmpty else { return }
        isPrepared = true
        // A task of its own: the screen that asks is covered by the editor a moment later, and
        // a task tied to it would be cancelled half-way through the script.
        Task { await run(model, store: store) }
    }

    @MainActor
    private static func run(_ model: AlertsEditorModel, store: HubStore) async {
        for _ in 0..<80 where model.editor == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let editor = model.editor else { return }
        if let rule = options.rule {
            let rules = editor.settings.rules
            if rule.hasPrefix("new:") {
                // "Add rule" is a button of the editor: open that first.
                model.isOpen = true
                try? await Task.sleep(for: .milliseconds(600))
                model.addRule(AlertRule.Kind(rawValue: String(rule.dropFirst(4))))
            } else if let index = Int(rule), rules.indices.contains(index) {
                model.open(rule: rules[index].id)
            } else if let id = rules.first(where: { $0.type.rawValue == rule })?.id {
                model.open(rule: id)
            }
            // The script's steps are for the rule's screen: wait until the editor has let it through.
            try? await Task.sleep(for: .milliseconds(900))
        }
        let unit = unit(store.preferences.temperatureUnit)
        for step in options.script {
            switch step {
            case "save":
                await model.save(to: store)
            case "test":
                await model.sendTest(through: store)
            case "test-failed":
                let result = AlertTestResult(ntfy: .init(ok: false, error: "HTTP 404"), webhook: .init(ok: true))
                model.debugShow(AlertsTestReport(result: result, sendsToApps: true))
            case "back":
                model.editedRuleID = nil
            case "disk-alert":
                // The demo's hub, or the one behind a `-dm-phase` session.
                (AppModel.shared.session.demoHub ?? AppModel.shared.debugHub)?.simulateDiskAlert()
            case "price":
                AppModel.shared.router.showElectricityPrice()
            case "elsewhere":
                // Not through the draft: as another app or the dashboard would change the settings.
                if var settings = store.alerts.settings {
                    settings.notifyResolved.toggle()
                    if let index = settings.rules.firstIndex(where: { $0.type == .offline }) { settings.rules[index].minutes = 45 }
                    _ = try? await store.saveAlerts(settings)
                    // Let the screens hear of it before the next step.
                    try? await Task.sleep(for: .milliseconds(300))
                }
            default:
                let parts = step.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 { edit(model, parts[0], parts[1], unit: unit) }
            }
        }
    }

    @MainActor
    private static func edit(_ model: AlertsEditorModel, _ key: String, _ value: String, unit: TemperatureUnit) {
        let on = value == "on"
        let rule = model.editedRuleID ?? ""
        switch key {
        case "apps": model.edit { $0.setAppNotifications(on) }
        case "ntfy": model.edit { $0.setNtfyEnabled(on) }
        case "webhook": model.edit { $0.setWebhookEnabled(on) }
        case "resolved": model.edit { $0.setNotifyResolved(on) }
        case "topic": model.edit { $0.setNtfyTopic(value) }
        case "server": model.edit { $0.setNtfyServer(value) }
        case "email": model.edit { $0.setNtfyEmail(value) }
        case "url": model.edit { $0.setWebhookURL(value) }
        case "msgunit": model.edit { $0.setTemperatureUnit(value == "F" ? .fahrenheit : .celsius) }
        case "replace": model.isReplacingWebhook = on
        case "remove": model.edit { $0.removeWebhookURL() }
        case "rules":
            let ids = model.editor?.settings.rules.map(\.id) ?? []
            model.edit { editor in
                for id in ids { editor.deleteRule(id) }
            }
        case "kind": model.edit { $0.setKind(of: rule, to: AlertRule.Kind(rawValue: value)) }
        case "device": model.edit { $0.setDevice(of: rule, to: value) }
        case "limit": model.edit { $0.setThreshold(of: rule, toText: value, unit: unit) }
        case "minutes": model.edit { $0.setMinutes(of: rule, to: Int(value) ?? 0) }
        case "enabled": model.edit { $0.setEnabled(on, for: rule) }
        default: break
        }
    }
    #else
    static var opensSettings: Bool { false }
    static var loadFailure: String? { nil }
    static var listAnchor: AlertsAnchor? { nil }
    static var settingsAnchor: AlertsAnchor? { nil }
    static var notice: AlertsDeviceNotice? { nil }
    static func confirms(_ confirmation: Confirmation) -> Bool { false }
    static func unit(_ unit: TemperatureUnit) -> TemperatureUnit { unit }
    static func priceSet(_ isSet: Bool) -> Bool { isSet }
    static func shown(_ alerts: AlertsState) -> AlertsState { alerts }
    @MainActor static func prepare(_ model: AlertsEditorModel, store: HubStore) {}
    #endif
}

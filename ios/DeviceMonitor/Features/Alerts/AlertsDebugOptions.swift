import DMCore
import SwiftUI
import UIKit

// DEBUG launch arguments of the Alerts tab, its editor and a rule's screen, so that every state
// can be opened without a tap (screenshots, UI tests). Combine them with `-dm-demo` or
// `-dm-phase live`, and `-dm-tab alerts`. None of them exists in a release build: there
// `AlertsLaunch` answers nil, false or "unchanged" to everything and reads nothing.
//
//     -dm-alerts-list <loading|error|empty|all-clear|no-rules>
//                                 the Alerts tab as if the hub had answered that way: not yet,
//                                 not at all, with nothing, with nothing firing, with every rule off
//     -dm-alerts-open settings    the editor ("Alert settings") is pushed
//     -dm-alerts-rule <n|kind|new:kind>
//                                 a rule's screen is pushed over the editor: the n-th rule (from 0),
//                                 the first of that kind (cpuTemp, offline, dailyCost…), or a rule
//                                 of that kind added as "Add rule" adds it
//     -dm-alerts-scroll <history|iphone|rules|channels|messages|test>
//                                 scrolled to that part (history: the tab; the others: the editor)
//     -dm-alerts-notify <undecided|off|asking|on|blocked>
//                                 "Notify on this iPhone" drawn in that state; neither the
//                                 preference nor the system's permission is read or changed
//     -dm-alerts-confirm <clear|discard|delete>
//                                 that confirmation is up: clear the log, discard the edits
//                                 (needs an edit from the script), delete the rule on screen
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
//                                 e.g. webhook=on,url=https://chat.example/hook,save,replace=on
//     -dm-alerts-fail <save|test> the hub cannot be reached for that request (a stand-in: the
//                                 demo hub itself is left alone)
//     -dm-alerts-price none       as if the hub had no electricity price
//     -dm-alerts-unit <C|F>       limits shown in that unit; the stored preference is not touched
//     -dm-alerts-width <points>   lay these screens out at that width and shrink the picture to
//                                 fit, to look at an iPad's or a sideways phone's arrangement
//
// `save` and `test` in a script go through the store like the buttons do, so on a demo hub they
// change that hub (which lives in memory, for this launch only).
#if DEBUG
nonisolated struct AlertsDebugOptions: Sendable {
    enum List: String, Sendable {
        case loading, error, empty
        case allClear = "all-clear"
        case noRules = "no-rules"
    }

    var list: List?
    var opensSettings = false
    var rule: String?
    var scroll: AlertsAnchor?
    var notice: String?
    var confirm: String?
    var script: [String] = []
    var fails: String?
    var hasNoPrice = false
    var unit: TemperatureUnit?
    var width: CGFloat?

    static let current = AlertsDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        list = value(after: "-dm-alerts-list").flatMap(List.init(rawValue:))
        rule = value(after: "-dm-alerts-rule")
        opensSettings = value(after: "-dm-alerts-open") == "settings" || rule != nil
        scroll = value(after: "-dm-alerts-scroll").flatMap(AlertsAnchor.init(rawValue:))
        notice = value(after: "-dm-alerts-notify")
        confirm = value(after: "-dm-alerts-confirm")
        script = value(after: "-dm-alerts-script")?.split(separator: ",").map(String.init) ?? []
        fails = value(after: "-dm-alerts-fail")
        hasNoPrice = value(after: "-dm-alerts-price") == "none"
        unit = value(after: "-dm-alerts-unit").flatMap(TemperatureUnit.init(rawValue:))
        width = value(after: "-dm-alerts-width").flatMap(Double.init).flatMap { $0 >= 200 && $0 <= 2000 ? CGFloat($0) : nil }
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
        options.confirm == confirmation.rawValue
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
    static func prepare(_ model: AlertsEditorModel, store: HubStore) async {
        guard !isPrepared, options.rule != nil || !options.script.isEmpty else { return }
        isPrepared = true
        for _ in 0..<80 where model.editor == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let editor = model.editor else { return }
        if let rule = options.rule {
            if rule.hasPrefix("new:") {
                model.addRule(AlertRule.Kind(rawValue: String(rule.dropFirst(4))))
            } else if let index = Int(rule) {
                model.editedRuleID = editor.settings.rules.indices.contains(index) ? editor.settings.rules[index].id : nil
            } else {
                model.editedRuleID = editor.settings.rules.first { $0.type.rawValue == rule }?.id
            }
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
    @MainActor static func prepare(_ model: AlertsEditorModel, store: HubStore) async {}
    #endif
}

import DMCore
import SwiftUI
import UIKit

// DEBUG launch arguments of the Settings tab, the electricity price editor and the add-device
// sheet, so that every state can be opened without a tap (screenshots, UI tests). Combine them
// with `-dm-demo` or `-dm-phase live`, and with `-dm-tab settings`, `-dm-sheet electricityPrice`
// or `-dm-sheet addDevice`. None of them stores anything, and none exists in a release build:
// there `SettingsLaunch` answers nil or false to everything.
//
//     -dm-settings-scroll <device|hub|advanced|about|link>
//                                 open the Settings tab scrolled to that section; `link` is the
//                                 add-device sheet scrolled to "View from another device"
//     -dm-settings-advanced <open|closed>
//                                 "Advanced settings" expanded or collapsed for this run (the
//                                 remembered choice is neither read nor changed)
//     -dm-settings-confirm disconnect
//                                 the "Disconnect this iPhone…?" confirmation is up
//     -dm-settings-identity full  the hub's TLS identity shown whole
//     -dm-settings-show license   the license screen is pushed
//     -dm-settings-link <ready|loading|error|expired|noshare>
//                                 the "Dashboard link" row of Settings in that state
//     -dm-settings-invite <loading|error|expired|noshare>
//                                 the add-device sheet's browser link in that state
//     -dm-settings-price <state>  the price editor, wherever it is shown:
//         tou          switched to "Time of use" (saved on the demo hub, as a tap would)
//         invalid      time of use, with a rate typed into the first period that is not one
//         full         time of use with the twelve periods the hub allows
//         loading      the hub has not answered yet
//         load-error   the hub could not be asked for the price
//         save-error   a change the hub could not be told about
//         regions      the "Where you live" list is open
//     -dm-settings-width <points> lay the Settings tab, the price sheet and the add-device sheet
//                                 out at that width and shrink the picture to fit the screen, to
//                                 look at the arrangement of an iPad or of a phone on its side
//                                 where only an upright phone can be had (nothing can be tapped
//                                 accurately in that picture)
//
// `loading`, `error`, `load-error` and `save-error` stand in for the hub's answer; the demo hub
// itself is left alone, so the rest of the app keeps running.
#if DEBUG
nonisolated struct SettingsDebugOptions: Sendable {
    enum Link: String, Sendable {
        case ready, loading, error, expired, noshare
    }

    enum Price: String, Sendable {
        case tou, invalid, full, loading, regions
        case loadError = "load-error"
        case saveError = "save-error"
    }

    var scroll: String?
    var advanced: Bool?
    var confirmsDisconnect = false
    var showsWholeIdentity = false
    var showsLicense = false
    var link: Link?
    var invite: Link?
    var price: Price?
    var width: CGFloat?

    static let current = SettingsDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        scroll = value(after: "-dm-settings-scroll")
        advanced = value(after: "-dm-settings-advanced").flatMap { $0 == "open" ? true : $0 == "closed" ? false : nil }
        confirmsDisconnect = value(after: "-dm-settings-confirm") == "disconnect"
        showsWholeIdentity = value(after: "-dm-settings-identity") == "full"
        showsLicense = value(after: "-dm-settings-show") == "license"
        link = value(after: "-dm-settings-link").flatMap(Link.init(rawValue:))
        invite = value(after: "-dm-settings-invite").flatMap(Link.init(rawValue:))
        price = value(after: "-dm-settings-price").flatMap(Price.init(rawValue:))
        width = value(after: "-dm-settings-width").flatMap(Double.init).flatMap { $0 >= 200 && $0 <= 2000 ? CGFloat($0) : nil }
    }
}

/// `-dm-settings-width`: the content at the asked width, drawn smaller.
private struct SettingsDebugWidth: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? width
        content
            .frame(width: width)
            .scaleEffect(min(1, screen / width), anchor: .top)
    }
}
#endif

extension View {
    /// Applies `-dm-settings-width` in a DEBUG build; the view itself otherwise.
    @ViewBuilder
    func settingsDebugWidth() -> some View {
        #if DEBUG
        if let width = SettingsDebugOptions.current.width {
            modifier(SettingsDebugWidth(width: width))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// What a DEBUG launch argument asked these screens to open with. In a release build every answer
/// is nil or false and nothing is read.
nonisolated enum SettingsLaunch {
    /// A stand-in for the hub's answer to a request.
    enum Answer: Sendable {
        /// Never answers.
        case silence
        case failure(HubError)
    }

    /// What the hub is made to answer when asked for a browser link.
    struct LinkScript: Sendable {
        /// Ask as soon as the screen appears.
        var asksAtOnce = false
        var answer: Answer?
        /// The link lapses as soon as it is shown.
        var expiresAtOnce = false
        /// The hub says this caller may not share.
        var refusesSharing = false
    }

    /// What the price editor is made to open with.
    struct PriceScript: Sendable {
        var loadAnswer: Answer?
        var saveAnswer: Answer?
        /// Changes made once the editor has loaded, as taps and typing would make them.
        var steps: [@Sendable (inout PriceEditor) -> EnergySettings?] = []
        var showsRegions = false
    }

    static var scrollAnchor: SettingsAnchor? {
        #if DEBUG
        SettingsDebugOptions.current.scroll.flatMap(SettingsAnchor.init(rawValue:))
        #else
        nil
        #endif
    }

    static var advancedExpanded: Bool? {
        #if DEBUG
        SettingsDebugOptions.current.advanced
        #else
        nil
        #endif
    }

    static var confirmsDisconnect: Bool {
        #if DEBUG
        SettingsDebugOptions.current.confirmsDisconnect
        #else
        false
        #endif
    }

    static var showsWholeIdentity: Bool {
        #if DEBUG
        SettingsDebugOptions.current.showsWholeIdentity
        #else
        false
        #endif
    }

    static var showsLicense: Bool {
        #if DEBUG
        SettingsDebugOptions.current.showsLicense
        #else
        false
        #endif
    }

    /// The "Dashboard link" row of Settings.
    static var settingsLink: LinkScript? {
        #if DEBUG
        SettingsDebugOptions.current.link.map(script(for:))
        #else
        nil
        #endif
    }

    /// The browser link of the add-device sheet.
    static var addDeviceLink: LinkScript? {
        #if DEBUG
        SettingsDebugOptions.current.invite.map(script(for:))
        #else
        nil
        #endif
    }

    static var price: PriceScript? {
        #if DEBUG
        SettingsDebugOptions.current.price.map(script(for:))
        #else
        nil
        #endif
    }

    #if DEBUG
    private static let unreachable = HubError.unreachable("Could not connect to the hub.")

    private static func script(for link: SettingsDebugOptions.Link) -> LinkScript {
        switch link {
        case .ready: LinkScript(asksAtOnce: true)
        case .loading: LinkScript(asksAtOnce: true, answer: .silence)
        case .error: LinkScript(asksAtOnce: true, answer: .failure(unreachable))
        case .expired: LinkScript(asksAtOnce: true, expiresAtOnce: true)
        case .noshare: LinkScript(asksAtOnce: true, refusesSharing: true)
        }
    }

    private static func script(for price: SettingsDebugOptions.Price) -> PriceScript {
        let timeOfUse: @Sendable (inout PriceEditor) -> EnergySettings? = { $0.setMode(.timeOfUse) }
        switch price {
        case .tou:
            return PriceScript(steps: [timeOfUse])
        case .invalid:
            return PriceScript(steps: [timeOfUse, { $0.setPeriodRate(at: 0, text: "abc") }])
        case .full:
            // Hour-long periods through the day; adding stops at the hub's limit.
            return PriceScript(steps: [timeOfUse] + Array(repeating: { $0.addPeriod() }, count: EnergyPricing.maxPeriods))
        case .loading:
            return PriceScript(loadAnswer: .silence)
        case .loadError:
            return PriceScript(loadAnswer: .failure(unreachable))
        case .saveError:
            return PriceScript(saveAnswer: .failure(unreachable), steps: [{ $0.setMode($0.mode == .flat ? .timeOfUse : .flat) }])
        case .regions:
            return PriceScript(showsRegions: true)
        }
    }
    #endif
}

#if DEBUG
import Foundation

/// DEBUG launch arguments of the Devices tab, for looking at its states and running its actions
/// where nothing can tap, type or drag (screenshots, UI tests). None of them exists in a release
/// build. Combine them with `-dm-demo` (see App/Debug/DebugLaunchOptions.swift).
///
/// States:
///
///     -dm-dashboard-scroll <device id|debug>[:top|center|bottom]
///                                              scroll so that edge of the card (or of the debug
///                                              tools) meets the same edge of the screen
///     -dm-dashboard-details <id,id…|all>       open Details on those cards
///     -dm-dashboard-offline                    open the offline list
///     -dm-dashboard-wake <sending|sent|failed> show the offline list's Wake buttons in that state
///     -dm-dashboard-rename <device id>         open the rename question for that device
///     -dm-dashboard-rename-text <text>         …with this typed instead of the current name
///                                              (an underscore stands for a space)
///     -dm-dashboard-remove <device id>         open the remove confirmation for that device
///     -dm-dashboard-removed-elsewhere          …and, while it is up, have the device removed as
///                                              the web dashboard or another phone would (an
///                                              online device; demo hub only)
///     -dm-dashboard-error <text>               show the failure alert with this explanation
///                                              (an underscore stands for a space)
///     -dm-dashboard-scrub <0…1>                every chart starts scrubbed at that fraction of
///                                              its width, with its tooltip
///     -dm-dashboard-card-width <points>        the narrowest a column of the grid may be (290),
///                                              to see several columns on a phone
///     -dm-dashboard-header <page|bar>          where the logo, name and summary go, whatever the
///                                              window's size: in a row pinned above the page (as
///                                              on an iPad) or in the navigation bar
///     -dm-dashboard-state <loading|empty|all-offline|offline-and-back>
///                                              loading: draw the state before the first snapshot;
///                                              empty: remove every device (demo hub only);
///                                              all-offline: stop every device reporting (demo hub
///                                              only; the hub calls them offline 30 s later);
///                                              offline-and-back: the same, and eight seconds after
///                                              the last of them has gone they all report again
///
/// Actions, done as the control would do them:
///
///     -dm-dashboard-commit                     answer the open rename or remove question with
///                                              its Rename or Remove button
///     -dm-dashboard-wake press                 press Wake on the first device that has one
///     -dm-dashboard-range <device id>:<10m|1h|6h>
///                                              choose that range in the card's range menu (it is
///                                              remembered, like any choice made there)
///     -dm-dashboard-move <device id>:<-1|1>    the card's "Move up" or "Move down" action
///     -dm-dashboard-drag <device id>:<over id|bottom>[:hold]
///                                              drag the card by its grip onto another card and
///                                              drop it; with `hold`, keep it in the air there.
///                                              `bottom` rests the finger at the lower edge of the
///                                              screen for two seconds instead, so the page scrolls
///
/// The default range of the cards and the temperature unit need no argument of their own: the
/// defaults they are kept in can be given for one launch, e.g. `-dm.range 1h` or `-dm.unit F`.
nonisolated struct DashboardDebugOptions: Sendable {
    enum ForcedState: String, Sendable {
        case loading, empty
        case allOffline = "all-offline"
        case offlineAndBack = "offline-and-back"
    }

    struct Drag: Sendable {
        var id: String
        var over: String
        var holds: Bool
    }

    var scrollAnchor: String?
    var openDetails: [String] = []
    var showsOfflineList = false
    var wake: String?
    var renameID: String?
    var renameText: String?
    var removeID: String?
    var removedElsewhere = false
    var commits = false
    var failure: String?
    var scrub: Double?
    var cardWidth: Double?
    var header: String?
    var range: (id: String, range: String)?
    var move: (id: String, offset: Int)?
    var drag: Drag?
    var state: ForcedState?

    static let current = DashboardDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        func parts(after flag: String) -> [String] {
            value(after: flag)?.split(separator: ":", omittingEmptySubsequences: false).map(String.init) ?? []
        }
        scrollAnchor = value(after: "-dm-dashboard-scroll")
        openDetails = value(after: "-dm-dashboard-details")?.split(separator: ",").map(String.init) ?? []
        showsOfflineList = arguments.contains("-dm-dashboard-offline")
        wake = value(after: "-dm-dashboard-wake")
        renameID = value(after: "-dm-dashboard-rename")
        renameText = value(after: "-dm-dashboard-rename-text")?.replacingOccurrences(of: "_", with: " ")
        removeID = value(after: "-dm-dashboard-remove")
        removedElsewhere = arguments.contains("-dm-dashboard-removed-elsewhere")
        commits = arguments.contains("-dm-dashboard-commit")
        failure = value(after: "-dm-dashboard-error")?.replacingOccurrences(of: "_", with: " ")
        scrub = value(after: "-dm-dashboard-scrub").flatMap(Double.init).map { min(1, max(0, $0)) }
        cardWidth = value(after: "-dm-dashboard-card-width").flatMap(Double.init).map { max(60, $0) }
        header = value(after: "-dm-dashboard-header")
        let range = parts(after: "-dm-dashboard-range")
        if range.count == 2 { self.range = (range[0], range[1]) }
        let move = parts(after: "-dm-dashboard-move")
        if move.count == 2, let offset = Int(move[1]) { self.move = (move[0], offset) }
        let drag = parts(after: "-dm-dashboard-drag")
        if drag.count >= 2 { self.drag = Drag(id: drag[0], over: drag[1], holds: drag.dropFirst(2).first == "hold") }
        state = value(after: "-dm-dashboard-state").flatMap(ForcedState.init(rawValue:))
    }

    func opensDetails(for id: String) -> Bool {
        openDetails.contains("all") || openDetails.contains(id)
    }
}
#endif

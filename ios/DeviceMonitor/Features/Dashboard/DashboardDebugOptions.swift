#if DEBUG
import Foundation

/// DEBUG launch arguments of the Devices tab, for looking at its states where nothing can tap,
/// type or drag (screenshots, UI tests). None of them exists in a release build. Combine them with
/// `-dm-demo` (see App/Debug/DebugLaunchOptions.swift).
///
///     -dm-dashboard-scroll <device id|debug>   scroll that card (or the debug tools) to the top
///     -dm-dashboard-details <id,id…|all>       open Details on those cards
///     -dm-dashboard-offline                    open the offline list
///     -dm-dashboard-wake <sending|sent|failed> show the offline list's Wake buttons in that state
///     -dm-dashboard-rename <device id>         open the rename question for that device
///     -dm-dashboard-rename-text <text>         …with this typed instead of the current name
///     -dm-dashboard-remove <device id>         open the remove confirmation for that device
///     -dm-dashboard-error <text>               show the failure alert with this explanation
///                                              (underscores are shown as spaces)
///     -dm-dashboard-scrub <0…1>                every chart starts scrubbed at that fraction of
///                                              its width, with its tooltip
///     -dm-dashboard-lift <device id>[:dx:dy]   show that card lifted, as while it is dragged,
///                                              moved by (dx, dy) points from its place
///     -dm-dashboard-state <loading|empty|all-offline>
///                                              loading: draw the state before the first snapshot;
///                                              empty: remove every device (demo hub only);
///                                              all-offline: stop every device reporting (demo hub
///                                              only; the hub calls them offline 30 s later)
///
/// A card's chart range and the temperature unit need no argument of their own: the defaults they
/// are kept in can be given for one launch, e.g. `-dm.range 1h` or `-dm.unit F`.
nonisolated struct DashboardDebugOptions: Sendable {
    enum ForcedState: String, Sendable {
        case loading, empty
        case allOffline = "all-offline"
    }

    struct Lift: Sendable {
        var id: String
        var dx: Double
        var dy: Double
    }

    var scrollAnchor: String?
    var openDetails: [String] = []
    var showsOfflineList = false
    var wake: String?
    var renameID: String?
    var renameText: String?
    var removeID: String?
    var failure: String?
    var scrub: Double?
    var lift: Lift?
    var state: ForcedState?

    static let current = DashboardDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        scrollAnchor = value(after: "-dm-dashboard-scroll")
        openDetails = value(after: "-dm-dashboard-details")?.split(separator: ",").map(String.init) ?? []
        showsOfflineList = arguments.contains("-dm-dashboard-offline")
        wake = value(after: "-dm-dashboard-wake")
        renameID = value(after: "-dm-dashboard-rename")
        renameText = value(after: "-dm-dashboard-rename-text")
        removeID = value(after: "-dm-dashboard-remove")
        failure = value(after: "-dm-dashboard-error")?.replacingOccurrences(of: "_", with: " ")
        scrub = value(after: "-dm-dashboard-scrub").flatMap(Double.init).map { min(1, max(0, $0)) }
        if let parts = value(after: "-dm-dashboard-lift")?.split(separator: ":", omittingEmptySubsequences: false), let id = parts.first {
            lift = Lift(
                id: String(id),
                dx: parts.count > 1 ? Double(parts[1]) ?? 0 : 0,
                dy: parts.count > 2 ? Double(parts[2]) ?? 0 : 0)
        }
        state = value(after: "-dm-dashboard-state").flatMap(ForcedState.init(rawValue:))
    }

    func opensDetails(for id: String) -> Bool {
        openDetails.contains("all") || openDetails.contains(id)
    }
}
#endif

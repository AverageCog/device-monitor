#if DEBUG
import Foundation

/// Launch arguments understood by DEBUG builds, so UI tests and screenshots can start anywhere
/// without tapping their way there:
///
///     -dm-phase <onboarding|connecting|live|unreachable|revoked>   initial phase (default onboarding)
///     -dm-tab <devices|history|advanced|alerts|settings>           initial tab
///     -dm-history <device id>                                      open History for that device
///     -dm-gallery [section]                                        open the component gallery,
///                                                                  optionally scrolled to a section
///     -dm-probe phase-container                                    open the PhaseContainer check
nonisolated struct DebugLaunchOptions: Sendable {
    var phase: AppPhase?
    var tab: AppTab?
    var historyDeviceID: String?
    var showsGallery = false
    var gallerySection: String?
    var probe: String?

    static let current = DebugLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        phase = value(after: "-dm-phase").flatMap(AppPhase.init(rawValue:))
        tab = value(after: "-dm-tab").flatMap(AppTab.init(rawValue:))
        historyDeviceID = value(after: "-dm-history")
        showsGallery = arguments.contains("-dm-gallery")
        gallerySection = value(after: "-dm-gallery")
        probe = value(after: "-dm-probe")
        // The gallery, the probes and History live behind the tabs.
        if showsGallery || historyDeviceID != nil || probe != nil, phase == nil { phase = .live }
    }
}
#endif

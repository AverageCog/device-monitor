#if DEBUG
import Foundation

/// Launch arguments understood by DEBUG builds, so UI tests and screenshots can start anywhere
/// without tapping their way there. None of them exists in a release build.
///
///     -dm-demo                              start in demo mode (implies an in-memory credential store)
///     -dm-reset                             forget the stored enrollment and every preference first
///     -dm-memory-credentials                keep the enrollment in memory instead of the Keychain
///     -dm-invitation <text>                 pre-fill the invitation on the pairing screen
///                                           (or the environment variable DM_INVITATION)
///     -dm-name <label>                      pre-fill the name this device gets on the hub
///     -dm-autoconnect                       pair with the pre-filled invitation at launch
///     -dm-phase <onboarding|connecting|live|unreachable|revoked>
///                                           show that phase, "paired" with a demo hub that is
///                                           made to behave that way; nothing is stored
///     -dm-tab <devices|history|advanced|alerts|settings>
///                                           initial tab
///     -dm-history <device id>               open History for that device
///     -dm-sheet <addDevice|electricityPrice>
///                                           present that shared sheet
///     -dm-gallery [section]                 open the component gallery, optionally at a section
///     -dm-probe phase-container             open the PhaseContainer check
///     -dm-then <disconnect|pair-again|retry|outage>
///                                           once the session has settled (live, unreachable or
///                                           revoked), do what that button does, for showing
///                                           those paths where nothing can tap; `outage` takes a
///                                           demo hub away for twenty seconds
///
/// `-dm-tab`, `-dm-history` and `-dm-sheet` take effect once the tabs are showing, so combine them
/// with `-dm-demo` or `-dm-phase live` unless the app is paired. The gallery and the probe cover
/// the tabs and imply `-dm-demo`.
nonisolated struct DebugLaunchOptions: Sendable {
    /// A phase to show without a real hub.
    enum Phase: String, Sendable, CaseIterable {
        case onboarding, connecting, live, unreachable, revoked
    }

    /// What a button would do, done without the tap.
    enum Action: String, Sendable {
        case disconnect
        case pairAgain = "pair-again"
        case retry
        /// Demo hubs only: the hub is unreachable for twenty seconds.
        case outage
    }

    var startsDemo = false
    var resetsState = false
    var usesMemoryCredentials = false
    var invitation: String?
    var deviceName: String?
    var autoConnects = false
    var phase: Phase?
    var tab: AppTab?
    var historyDeviceID: String?
    var sheet: AppSheet?
    var showsGallery = false
    var gallerySection: String?
    var probe: String?
    var action: Action?

    static let current = DebugLaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)

    init(arguments: [String], environment: [String: String] = [:]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        startsDemo = arguments.contains("-dm-demo")
        resetsState = arguments.contains("-dm-reset")
        usesMemoryCredentials = arguments.contains("-dm-memory-credentials")
        invitation = value(after: "-dm-invitation") ?? environment["DM_INVITATION"].flatMap { $0.isEmpty ? nil : $0 }
        deviceName = value(after: "-dm-name")
        autoConnects = arguments.contains("-dm-autoconnect")
        phase = value(after: "-dm-phase").flatMap(Phase.init(rawValue:))
        tab = value(after: "-dm-tab").flatMap(AppTab.init(rawValue:))
        historyDeviceID = value(after: "-dm-history")
        sheet = value(after: "-dm-sheet").flatMap(AppSheet.init(rawValue:))
        showsGallery = arguments.contains("-dm-gallery")
        gallerySection = value(after: "-dm-gallery")
        probe = value(after: "-dm-probe")
        action = value(after: "-dm-then").flatMap(Action.init(rawValue:))
        // The debug screens cover the tabs, and must open whatever this simulator is paired with.
        if showsGallery || probe != nil, phase == nil { startsDemo = true }
    }

    /// The debug screen to open at launch.
    var debugScreen: DebugScreen? {
        if showsGallery { return .gallery }
        if probe == "phase-container" { return .phaseContainer }
        return nil
    }
}

/// A debug screen that covers the tabs.
nonisolated enum DebugScreen: String, Identifiable, Hashable, Sendable {
    case gallery
    case phaseContainer

    var id: String { rawValue }
}
#endif

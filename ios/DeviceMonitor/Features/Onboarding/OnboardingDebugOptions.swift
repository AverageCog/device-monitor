#if DEBUG
import DMCore
import SwiftUI

/// Launch arguments of the first-run and system-state screens, DEBUG builds only. Nothing can tap
/// or type on the simulator these screens are looked at on, so every state that needs a tap, a
/// camera or a slow hub can be asked for at launch. None of them exists in a release build, and
/// none changes what the session does: they only decide what these screens draw first.
///
///     -dm-onboarding-scanner <state>   open the scanner sheet without the camera, as if it were
///                                      preparing | scanning | interrupted | denied | restricted |
///                                      unavailable | failed, or scanning and just shown a
///                                      desktop | browser | other code (the transport's message
///                                      for it), or `accept`: a good invitation was scanned
///                                      (the sheet closes and pairing starts)
///     -dm-onboarding-camera <0|1>      whether the Scan button believes the device has a camera
///     -dm-onboarding-focus <invitation|name>
///                                      put the keyboard focus in that field at launch
///     -dm-onboarding-scroll <fields|end>
///                                      scroll the pairing screen so that its fields and Connect,
///                                      or its last line, are at the bottom of what is on show
///     -dm-onboarding-busy              draw the pairing form as while "Verifying the hub…"
///     -dm-onboarding-slow <0|1>        Connecting: the "taking long" note at once, or never
///     -dm-onboarding-confirm           Unreachable: the "Change setup" confirmation open
///     -dm-onboarding-retrying          Unreachable: as while "Try again" is under way
///     -dm-onboarding-as-demo           Unreachable and Revoked: the wording of a demo session
///     -dm-onboarding-canvas <W>x<H>    lay the screen out in a canvas of that many points, scaled
///                                      to fit and turned a quarter when it is wider than tall
///                                      (874x402 is this phone in landscape, 1194x834 an iPad)
///
/// Combine them with the app's own arguments (`-dm-phase onboarding|connecting|unreachable|revoked`,
/// `-dm-invitation`, `-dm-name`, `-dm-autoconnect`; see App/Debug/DebugLaunchOptions.swift).
nonisolated struct OnboardingDebugOptions: Sendable {
    var scanner: String?
    var hasCamera: Bool?
    var focus: String?
    var scroll: String?
    var showsBusy = false
    var isSlow: Bool?
    var confirmsChange = false
    var showsRetrying = false
    var actsAsDemo = false
    var canvas: CGSize?

    static let current = OnboardingDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        scanner = value(after: "-dm-onboarding-scanner")
        hasCamera = value(after: "-dm-onboarding-camera").map { $0 == "1" }
        focus = value(after: "-dm-onboarding-focus")
        scroll = value(after: "-dm-onboarding-scroll")
        showsBusy = arguments.contains("-dm-onboarding-busy")
        isSlow = value(after: "-dm-onboarding-slow").map { $0 == "1" }
        confirmsChange = arguments.contains("-dm-onboarding-confirm")
        showsRetrying = arguments.contains("-dm-onboarding-retrying")
        actsAsDemo = arguments.contains("-dm-onboarding-as-demo")
        if let size = value(after: "-dm-onboarding-canvas")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2, size[0] >= 200, size[1] >= 200 {
            canvas = CGSize(width: size[0], height: size[1])
        }
    }
}

/// `-dm-onboarding-canvas`: the screen as it lays out at another size (a phone on its side, an
/// iPad), drawn small enough to fit this one. Only the simulator's portrait screen can be looked
/// at, so this is how the other shapes are checked.
struct OnboardingDebugCanvas<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let isTurned = size.width > size.height
            let footprint = isTurned ? CGSize(width: size.height, height: size.width) : size
            let scale = min(1, proxy.size.width / footprint.width, proxy.size.height / footprint.height)
            content
                .frame(width: size.width, height: size.height)
                .environment(\.horizontalSizeClass, size.width >= 700 ? .regular : .compact)
                .environment(\.verticalSizeClass, size.height < 500 ? .compact : .regular)
                .background(Theme.page)
                .border(Theme.axis)
                .rotationEffect(isTurned ? .degrees(90) : .zero)
                .scaleEffect(scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
extension View {
    /// A phase screen in a preview: a session of its own that a demo hub holds in `phase`
    /// (the `-dm-phase` session of App/Debug/DebugSession.swift). Nothing is stored.
    func onboardingPreview(_ phase: DebugLaunchOptions.Phase) -> some View {
        modifier(OnboardingPreviewModifier(phase: phase))
    }
}

private struct OnboardingPreviewModifier: ViewModifier {
    @State private var scripted: DebugSession
    @State private var router = AppRouter()

    init(phase: DebugLaunchOptions.Phase) {
        let scripted = DebugSession(phase: phase, preferences: Preferences(defaults: DebugSession.volatileDefaults()))
        scripted.session.launch()
        _scripted = State(initialValue: scripted)
    }

    func body(content: Content) -> some View {
        content.appEnvironment(session: scripted.session, router: router)
    }
}
#endif

import DMCore
import SwiftUI
import UIKit

/// The objects that live as long as the app does: the session, the preferences and the router.
///
/// Made on first use, which is in `application(_:didFinishLaunchingWithOptions:)` and not in
/// `App.init()`. When iOS pre-warms the process, `App.init()` runs long before anybody opens the
/// app, possibly before the phone was first unlocked, when neither `UserDefaults` nor the
/// Keychain can be read.
final class AppModel {
    static let shared = AppModel()

    let router = AppRouter()
    let preferences: Preferences
    let session: SessionController
    #if DEBUG
    /// The demo hub behind a `-dm-phase` session, for the debug tools to direct.
    let debugHub: DemoHubAPI?
    #endif

    private init() {
        #if DEBUG
        let options = DebugLaunchOptions.current
        if options.resetsState { Self.resetStoredState() }
        let preferences = Preferences()
        if let phase = options.phase, phase != .onboarding {
            let scripted = DebugSession(phase: phase, preferences: preferences)
            session = scripted.session
            debugHub = scripted.hub
        } else if options.usesMemoryCredentials || options.startsDemo || options.phase == .onboarding {
            // Nothing about this run is to outlive it, the "has launched" mark included.
            session = SessionController(credentials: InMemoryCredentialStore(), preferences: preferences, defaults: DebugSession.volatileDefaults())
            debugHub = nil
        } else {
            session = SessionController(credentials: KeychainCredentialStore(), preferences: preferences)
            debugHub = nil
        }
        if let tab = options.tab { router.selectedTab = tab }
        if let deviceID = options.historyDeviceID { router.openHistory(deviceID: deviceID) }
        router.sheet = options.sheet
        router.debugScreen = options.debugScreen
        #else
        let preferences = Preferences()
        session = SessionController(credentials: KeychainCredentialStore(), preferences: preferences)
        #endif
        self.preferences = preferences
        session.alertNotifier = AlertsIntegration.makeAlertNotifier(preferences: preferences)
    }

    /// Called once, when the app has finished launching.
    /// - Parameter inBackground: the system started the app without showing it (a background refresh).
    func launch(inBackground: Bool) {
        AlertsIntegration.appDidFinishLaunching(session: session)
        // The stream waits until there is someone to show it to; requests still work meanwhile.
        if inBackground { session.enterBackground() }
        session.launch()
        #if DEBUG
        let options = DebugLaunchOptions.current
        if options.startsDemo {
            session.startDemo()
        } else if options.autoConnects, let invitation = options.invitation, session.phase == .onboarding {
            Task { await session.pair(invitationText: invitation, name: options.deviceName ?? Self.deviceName) }
        }
        if let action = options.action { perform(action) }
        #endif
    }

    #if DEBUG
    /// `-dm-then`: waits for the session to settle, then does what the button would.
    private func perform(_ action: DebugLaunchOptions.Action) {
        Task {
            for _ in 0..<300 {
                switch session.phase {
                case .live, .unreachable, .revoked:
                    switch action {
                    case .disconnect: await session.disconnect()
                    case .pairAgain: session.pairAgain()
                    case .retry: session.retryNow()
                    case .outage:
                        if let hub = session.demoHub ?? debugHub { DebugTools.interrupt(hub, for: .seconds(20)) }
                    case .blip:
                        if let hub = session.demoHub ?? debugHub { DebugTools.interrupt(hub, for: .seconds(5)) }
                    }
                    return
                case .onboarding, .connecting:
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }
    #endif

    /// The scene changed phase; `old == new` for the phase it starts in.
    func scenePhaseChanged(from old: ScenePhase, to new: ScenePhase) {
        switch new {
        case .active:
            session.enterForeground()
        // A scene may report `.background` before it first appears; that is not the app leaving.
        case .background where old != .background:
            session.enterBackground()
            AlertsIntegration.scheduleRefresh()
        default:
            break
        }
    }

    /// The system granted the background refresh task.
    static func handleBackgroundRefresh() async {
        await AlertsIntegration.handleRefresh(session: shared.session)
    }

    /// What the pairing screen suggests as this device's name on the hub. iOS only tells an app
    /// the model ("iPhone") unless it holds the user-assigned-device-name entitlement.
    static var deviceName: String { UIDevice.current.name }

    #if DEBUG
    /// `-dm-reset`: as if the app had just been installed on a device it was never on.
    private static func resetStoredState() {
        try? KeychainCredentialStore().clear()
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }
    #endif
}

/// Forwards the one moment SwiftUI's `App` has no hook for.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.launch(inBackground: application.applicationState == .background)
        return true
    }
}

extension View {
    /// Puts what every screen may read into the environment: the session, the preferences and
    /// the router. The hub's `HubStore` is added where the tabs are (`RootView`).
    ///
    /// A screen reads them with `@Environment(SessionController.self)`, `@Environment(Preferences.self)`,
    /// `@Environment(AppRouter.self)` and, under the tabs, `@Environment(HubStore.self)`.
    func appEnvironment(session: SessionController, router: AppRouter) -> some View {
        environment(session)
            .environment(session.preferences)
            .environment(router)
            // The palette is dark only; Info.plist pins UIUserInterfaceStyle as well so system
            // surfaces (launch screen, alerts) never flash light.
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }
}

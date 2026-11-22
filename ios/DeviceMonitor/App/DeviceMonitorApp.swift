import SwiftUI

@main
struct DeviceMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // App-wide, not per window: Info.plist turns multiple scenes off, so there is one window to
        // route. Supporting several windows on iPad means giving each its own router first.
        let model = AppModel.shared
        WindowGroup {
            RootView()
                .appEnvironment(session: model.session, router: model.router)
        }
        .onChange(of: scenePhase, initial: true) { old, new in
            model.scenePhaseChanged(from: old, to: new)
        }
        // Registered here, scheduled by `AlertsIntegration.scheduleRefresh()` when the app leaves
        // the foreground. The identifier is also in Info.plist (BGTaskSchedulerPermittedIdentifiers).
        .backgroundTask(.appRefresh(AlertsIntegration.refreshTaskIdentifier)) {
            await AppModel.handleBackgroundRefresh()
        }
    }
}

import DMCore
import Foundation

// INTERIM STUB — replaced by the Alerts feature.
//
// The app shell (App/) calls these at the moments named below and is not edited again, so keep
// the names and signatures and fill in the bodies: local notifications for alerts that arrive on
// the live stream, and a background refresh that looks for alerts while the app is not running.
// Every one of them is called on the main actor.
enum AlertsIntegration {
    /// The background refresh task. Info.plist lists it under BGTaskSchedulerPermittedIdentifiers,
    /// and the app's scene registers `handleRefresh(session:)` for it with
    /// `.backgroundTask(.appRefresh(refreshTaskIdentifier))`.
    static let refreshTaskIdentifier = "com.devicemonitor.ios.refresh"

    /// Called once, from `application(_:didFinishLaunchingWithOptions:)`, before the session looks
    /// for its enrollment and before any scene exists. The place to become the notification
    /// centre's delegate.
    static func appDidFinishLaunching(session: SessionController) {}

    /// Called once at launch. The notifier is handed to every `HubStore` the session creates, the
    /// demo's included, and receives each alert the hub wants announced while the stream is
    /// connected. Whether this device shows it (`preferences.notificationsEnabled`, the system's
    /// permission) is for the notifier to decide.
    static func makeAlertNotifier(preferences: Preferences) -> any AlertNotifier {
        ClosureAlertNotifier { _ in }
    }

    /// Called every time the app enters the background: ask the system for the next refresh.
    static func scheduleRefresh() {}

    /// Runs when the system grants the refresh task; the system ends it when the task's time is
    /// up. The app may have been started just for this: `session.store` then exists for a paired
    /// hub but is not connected, and still answers requests (`try await store.refreshAlerts()`).
    /// It is nil when the app is not paired.
    static func handleRefresh(session: SessionController) async {}
}

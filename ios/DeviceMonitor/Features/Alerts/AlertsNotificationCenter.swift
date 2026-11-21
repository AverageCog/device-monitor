import DMCore
import Observation
import UIKit
import UserNotifications

/// What iOS lets this app do with notifications.
nonisolated enum AlertsPermission: Sendable, Equatable {
    /// Not looked up yet.
    case unknown
    /// iOS has not asked the user yet.
    case undecided
    case denied
    case allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .undecided
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .allowed
        @unknown default: self = .denied
        }
    }
}

/// The system's notification centre as the app uses it: the permission, which the screens
/// observe, and posting an alert as a local notification.
@Observable
final class AlertsNotificationCenter {
    static let shared = AlertsNotificationCenter()

    private(set) var permission = AlertsPermission.unknown
    /// True while the system's "Allow notifications?" question is up.
    private(set) var isAsking = false

    private init() {}

    /// Looks the permission up again. The user can change it in Settings at any time, so the
    /// screens that show it ask whenever they appear and whenever the app comes forward.
    func refreshPermission() async {
        let fresh = AlertsPermission(await Self.authorizationStatus())
        if permission != fresh { permission = fresh }
    }

    /// Has iOS ask the user. It only ever asks once; after that this just reports the answer.
    @discardableResult
    func requestPermission() async -> Bool {
        isAsking = true
        defer { isAsking = false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshPermission()
        return granted
    }

    /// The app's page in the Settings app, where a refused permission is granted after all.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// The user is looking at the alerts themselves: what is still in Notification Centre is old news.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Posts one alert. The request's identifier is the alert's, so posting it twice replaces the
    /// first instead of adding a second. Without permission this does nothing.
    nonisolated static func post(_ notification: AlertNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        // An alert asks for attention; its "back to normal" arrives without a sound.
        content.sound = notification.isFiring ? .default : nil
        content.interruptionLevel = notification.isFiring ? .active : .passive
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Shows alerts as banners while the app is in front too, and opens the Alerts tab when one is tapped.
nonisolated final class AlertsNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // The only notifications this app posts are alerts.
        Task { @MainActor in AlertsNotifier.shared.openAlerts() }
        completionHandler()
    }
}

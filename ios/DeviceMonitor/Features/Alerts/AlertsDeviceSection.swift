import DMCore
import SwiftUI

/// Where "Notify on this iPhone" stands: what the user chose, and what iOS allows.
nonisolated enum AlertsDeviceNotice: Equatable, Sendable {
    /// Off, and iOS has never been asked: worth offering.
    case undecided
    case off
    /// The system's question is on screen.
    case asking
    case on
    /// iOS does not let the app show notifications, whatever the user chose here.
    case blocked

    init(wanted: Bool, permission: AlertsPermission, isAsking: Bool) {
        if isAsking {
            self = .asking
            return
        }
        switch permission {
        case .denied: self = .blocked
        // Wanted or not: nothing is shown before iOS has been asked.
        case .undecided: self = wanted ? .off : .undecided
        case .allowed, .unknown: self = wanted ? .on : .off
        }
    }

    var isOn: Bool { self == .on }

    /// The state to show: what the launch arguments ask for in a DEBUG build, else the real one.
    @MainActor
    static func current(_ preferences: Preferences, _ center: AlertsNotificationCenter) -> AlertsDeviceNotice {
        AlertsLaunch.notice ?? AlertsDeviceNotice(wanted: preferences.notificationsEnabled, permission: center.permission, isAsking: center.isAsking)
    }
}

/// What the switch and the buttons around it do.
enum AlertsDeviceNotifications {
    static let title = "Notify on this \(AlertsLayout.deviceName)"

    /// Switching on asks iOS for permission the first time; the switch stays off when the
    /// answer is no.
    static func set(_ wanted: Bool, preferences: Preferences) async {
        let center = AlertsNotificationCenter.shared
        guard wanted else {
            preferences.notificationsEnabled = false
            return
        }
        await center.refreshPermission()
        switch center.permission {
        case .allowed: preferences.notificationsEnabled = true
        case .undecided, .unknown: preferences.notificationsEnabled = await center.requestPermission()
        // The wish is kept, for when iOS allows it after all.
        case .denied: preferences.notificationsEnabled = true
        }
    }

    /// Someone who goes to Settings to allow notifications wants them: once allowed, they are on.
    static func openSettings(preferences: Preferences) {
        preferences.notificationsEnabled = true
        AlertsNotificationCenter.shared.openSystemSettings()
    }

    /// The wish is given up while iOS stands in its way. The switch cannot do this: it is off
    /// and disabled for as long as iOS refuses.
    static func withdraw(preferences: Preferences) {
        preferences.notificationsEnabled = false
    }
}

/// Looks the permission up when the view appears and whenever the app comes back to the front
/// (the way back from the Settings app).
struct AlertsPermissionRefresh: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await AlertsNotificationCenter.shared.refreshPermission() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await AlertsNotificationCenter.shared.refreshPermission() }
            }
    }
}

/// The strip at the top of the Alerts tab, shown only when there is something to decide or to
/// put right: notifications were never set up, or iOS is blocking them.
struct AlertsDeviceBanner: View {
    @Environment(Preferences.self) private var preferences
    @Environment(SessionController.self) private var session

    var body: some View {
        let state = AlertsDeviceNotice.current(preferences, AlertsNotificationCenter.shared)
        switch state {
        case .undecided, .asking:
            // Not offered in the demo, whose alerts are never shown as notifications.
            if !session.isDemo {
                BannerView(
                    "Get a notification on this \(AlertsLayout.deviceName) when an alert fires.", kind: .info, systemImage: "bell.badge",
                    showsProgress: state == .asking, actionTitle: "Turn on"
                ) {
                    Task { await AlertsDeviceNotifications.set(true, preferences: preferences) }
                }
                .disabled(state == .asking)
                .accessibilityIdentifier("alerts-notify-banner")
                .padding(.bottom, Theme.Spacing.l)
            }
        // Blocked, and the user did ask for notifications: otherwise there is nothing to put right.
        case .blocked where preferences.notificationsEnabled:
            AlertsBlockedBanner(
                openSettings: { AlertsDeviceNotifications.openSettings(preferences: preferences) },
                withdraw: { AlertsDeviceNotifications.withdraw(preferences: preferences) }
            )
            .padding(.bottom, Theme.Spacing.l)
        case .off, .on, .blocked:
            EmptyView()
        }
    }
}

/// iOS is blocking the notifications the user asked for. There are two ways out: allow them in
/// the Settings app, or stop asking for them here. Without the second the banner would stay for
/// good on a phone whose owner turned notifications off in Settings on purpose.
///
/// Drawn like the design system's warning banner, which has room for one answer only.
private struct AlertsBlockedBanner: View {
    let openSettings: () -> Void
    let withdraw: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: "bell.slash")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.warning)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Notifications for Device Monitor are turned off in Settings, so alerts cannot show on this \(AlertsLayout.deviceName).")
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("alerts-blocked-banner")
                // Side by side while they fit; one under the other at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) { answers }
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) { answers }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .dmSurface(Theme.warning.opacity(0.08), radius: Theme.Radius.banner, border: Theme.warning.opacity(0.35))
    }

    @ViewBuilder private var answers: some View {
        Button("Open Settings", action: openSettings)
            .buttonStyle(.dm(.primary, size: .small))
            .accessibilityIdentifier("alerts-blocked-settings-button")
        Button("Don't notify", action: withdraw)
            .buttonStyle(.dm(size: .small))
            .accessibilityHint("Switches \u{201C}\(AlertsDeviceNotifications.title)\u{201D} off")
            .accessibilityIdentifier("alerts-blocked-dismiss-button")
    }
}

/// "This iPhone" in the alert settings: the one setting that is this device's own. It takes
/// effect at once and is not part of what Save sends to the hub.
struct AlertsDeviceSection: View {
    @Environment(Preferences.self) private var preferences
    @Environment(SessionController.self) private var session
    /// Whether the hub sends alerts to apps at all (its saved "Device Monitor apps" channel).
    let hubSendsToApps: Bool

    var body: some View {
        let state = AlertsDeviceNotice.current(preferences, AlertsNotificationCenter.shared)
        SettingsSection("This \(AlertsLayout.deviceName)", footer: footer) {
            SettingsToggleRow(AlertsDeviceNotifications.title, description: description(for: state), isOn: isOn(state))
                .disabled(state == .blocked || state == .asking)
                .accessibilityIdentifier("alerts-notify-toggle")
            if state == .blocked {
                AlertsRow {
                    AlertsSplitRow("Notifications are turned off", description: "Allow them for Device Monitor in the Settings app.") {
                        Button("Open Settings") { AlertsDeviceNotifications.openSettings(preferences: preferences) }
                            .buttonStyle(.dm(size: .small))
                            .accessibilityIdentifier("alerts-open-settings-button")
                    }
                }
            }
            if state == .on, !hubSendsToApps {
                AlertsRow {
                    AlertsIssueLabel("The hub's \u{201C}\(AlertsChannel.apps)\u{201D} channel is off, so nothing is sent to this app. Switch it on below.", isError: false)
                        .accessibilityIdentifier("alerts-notify-channel-off")
                }
            }
        }
    }

    private func isOn(_ state: AlertsDeviceNotice) -> Binding<Bool> {
        Binding(
            get: { state.isOn },
            set: { wanted in Task { await AlertsDeviceNotifications.set(wanted, preferences: preferences) } }
        )
    }

    private func description(for state: AlertsDeviceNotice) -> String {
        switch state {
        case .asking: "Waiting for your answer\u{2026}"
        case .blocked: "iOS is not letting Device Monitor show notifications."
        case .undecided, .off, .on: "Show a notification here when the hub raises an alert."
        }
    }

    /// The honest part: only an open app hears of an alert at once, and a demo's alerts are
    /// about devices that do not exist.
    private var footer: String {
        let timing = "While Device Monitor is open, alerts arrive at once. In the background iOS decides when the app may check the hub, so a notification can be late. For instant alerts, set up ntfy below."
        return session.isDemo ? timing + " The demo's devices are simulated: its alerts are never shown as notifications." : timing
    }
}

#Preview("This iPhone") {
    ScrollView {
        AlertsDeviceSection(hubSendsToApps: true)
            .padding()
    }
    .modifier(AlertsPermissionRefresh())
    .dmScreen()
    .demoEnvironment()
}

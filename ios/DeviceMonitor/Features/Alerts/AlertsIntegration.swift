import BackgroundTasks
import DMCore
import Foundation
import UserNotifications

/// Where the app shell meets the alert notifications. `App/` calls these at the moments named
/// below, always on the main actor.
enum AlertsIntegration {
    /// The background refresh task. Info.plist lists it under BGTaskSchedulerPermittedIdentifiers,
    /// and the app's scene registers `handleRefresh(session:)` for it with
    /// `.backgroundTask(.appRefresh(refreshTaskIdentifier))`.
    static let refreshTaskIdentifier = "com.devicemonitor.ios.refresh"

    /// How soon the next background refresh may run. A wish, not an appointment: iOS decides
    /// when, from how the app is used, and rarely as often as this.
    static let refreshInterval: TimeInterval = 15 * 60

    /// Called once, from `application(_:didFinishLaunchingWithOptions:)`, before the session looks
    /// for its enrollment and before any scene exists.
    static func appDidFinishLaunching(session: SessionController) {
        AlertsNotifier.shared.attach(to: session)
    }

    /// Called once at launch. The notifier is handed to every `HubStore` the session creates and
    /// receives each alert the hub wants announced while the stream is connected.
    static func makeAlertNotifier(preferences: Preferences) -> any AlertNotifier {
        AlertsNotifier.shared.use(preferences)
        return ClosureAlertNotifier { event in AlertsNotifier.shared.received(event) }
    }

    /// Called every time the app enters the background: asks the system for the next refresh,
    /// or takes the request back when this device is not to be notified.
    static func scheduleRefresh() {
        let scheduler = BGTaskScheduler.shared
        guard AlertsNotifier.shared.wantsBackgroundRefresh else {
            scheduler.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        // Refused on a simulator and while Background App Refresh is switched off. Neither can
        // be helped from here; alerts then show when the app is next opened.
        try? scheduler.submit(request)
    }

    /// Runs when the system grants the refresh task; the system cancels it when its time is up.
    static func handleRefresh(session: SessionController) async {
        // First, so that the next refresh is asked for even if this one is cut short.
        scheduleRefresh()
        await AlertsNotifier.shared.refresh(in: session)
    }
}

/// Turns the hub's alerts into local notifications on this device. A real hub's only: in demo
/// mode everything is planned as it would be, and nothing is posted.
///
/// Alerts reach it two ways. While the stream is connected the store hands over each alert the
/// hub wants announced. Whatever happened while it was not (the app in the background, the hub
/// out of reach) is read from the hub's log: every time the stream comes up, and in the
/// background refresh. `AlertNotifications` decides what of that is worth a notification, and
/// the newest alert dealt with is remembered in `Preferences`, which is what keeps an alert from
/// being announced twice.
final class AlertsNotifier {
    static let shared = AlertsNotifier()

    private weak var session: SessionController?
    private var preferences: Preferences?
    private let delegate = AlertsNotificationDelegate()

    /// The hub the session was paired with when last looked at: the one whose alerts were posted.
    private var pairedHub: PairedHub?
    /// The store whose log has been gone through since its stream last came up.
    private var caughtUp: ObjectIdentifier?
    /// Counts the changes of the connection, so a log that was fetched across one is fetched again.
    private var changes = 0
    private var isCatchingUp = false
    /// Live alerts held back until the log has been gone through: a live alert moves the marker
    /// past anything older that was missed.
    private var waiting: [AlertEvent] = []
    /// The batch being handed to the system. The next one waits for it, so the order holds.
    private var posting: Task<Void, Never>?

    #if DEBUG
    /// What the notifier did, oldest first, for the DEBUG probe on the Alerts tab
    /// (`-dm-alerts-probe`): the only way to watch it decide where nothing can answer the
    /// system's permission question.
    private(set) var trace: [String] = []
    #endif

    private init() {}

    func use(_ preferences: Preferences) {
        self.preferences = preferences
    }

    func attach(to session: SessionController) {
        self.session = session
        pairedHub = session.hub
        UNUserNotificationCenter.current().delegate = delegate
        watch()
    }

    /// A notification was tapped.
    func openAlerts() {
        AppModel.shared.router.showAlerts()
    }

    /// Whether a background refresh would have anything to do: this device is to be notified,
    /// and there is a real hub to ask.
    var wantsBackgroundRefresh: Bool {
        guard let preferences, let session else { return false }
        return preferences.notificationsEnabled && !session.isDemo && session.hub != nil
    }

    // MARK: Live

    /// An alert arrived on the stream, and the hub wants apps to announce it.
    func received(_ event: AlertEvent) {
        note("live: \(event.title)")
        guard let store = session?.store, caughtUp != ObjectIdentifier(store) else {
            announce(AlertNotifications.plan(live: event, notify: true, seen: marker))
            return
        }
        waiting.append(event)
        catchUp()
    }

    /// Follows the session's hub, its store and the store's connection, for as long as the app runs.
    private func watch() {
        guard let session else { return }
        withObservationTracking {
            _ = session.hub
            _ = session.store?.connection
        } onChange: { [weak self] in
            // Called before the change is made; by the time the task runs it has been.
            Task { @MainActor [weak self] in
                self?.connectionChanged()
                self?.watch()
            }
        }
    }

    private func connectionChanged() {
        // Only the hub going counts as leaving it: the connection changes with every outage, and
        // "Try again" after a revocation replaces the store, with the hub still the same.
        if let pairedHub, pairedHub != session?.hub { leftHub() }
        pairedHub = session?.hub
        changes += 1
        caughtUp = nil
        let isLive = session?.store?.connection == .live
        note(isLive ? "stream: up" : "stream: down")
        if isLive { catchUp() }
    }

    private func catchUp() {
        guard !isCatchingUp else { return }
        isCatchingUp = true
        Task {
            await goThroughLog()
            isCatchingUp = false
            let held = waiting
            waiting = []
            for event in held {
                announce(AlertNotifications.plan(live: event, notify: true, seen: marker))
            }
        }
    }

    /// Fetches the log through the store and announces what was missed. Left undone when the hub
    /// cannot be asked; the alerts held back are then announced as they came.
    private func goThroughLog() async {
        while let store = session?.store, store.connection == .live {
            let change = changes
            do {
                try await store.refreshAlerts()
            } catch {
                return
            }
            // The stream went away and came back meanwhile: this answer may predate the gap.
            guard change == changes else { continue }
            note("log: \(store.alerts.events.count) entries")
            announce(fetched: store.alerts, now: store.clock.now)
            caughtUp = ObjectIdentifier(store)
            return
        }
    }

    /// Disconnect or Pair again: the hub is forgotten, and so is what was posted about it. Its
    /// alerts name devices, disks and times, and would otherwise stay on the lock screen and in
    /// Notification Centre, for whoever has the phone next.
    private func leftHub() {
        note("hub: left, its notifications removed")
        waiting = []
        let previous = posting
        posting = Task {
            // A notification still being handed over would land after a removal made now.
            await previous?.value
            AlertsNotificationCenter.shared.removeAll()
        }
    }

    // MARK: Background

    /// The background refresh: asks the hub for its log and announces what happened since the
    /// app last looked. Never in demo mode, and not at all when this device is not to be notified.
    func refresh(in session: SessionController) async {
        guard wantsBackgroundRefresh, let store = session.store else { return }
        do {
            // The session's own connection to its hub: built from the stored enrollment, pinned
            // to the hub's key, and idle while the app is in the background.
            try await store.refreshAlerts()
        } catch {
            return
        }
        announce(fetched: store.alerts, now: store.clock.now)
        // The time the system granted lasts until this returns; after that the app may be
        // suspended with a notification half handed over.
        await posting?.value
    }

    // MARK: Announcing

    /// The demo's store while the demo runs. What was seen of a demo hub is kept in memory, for
    /// that demo only: nothing about a hub that is not real is stored, and every demo raises
    /// its alerts under the same ids, which a stored marker would take for old news.
    private var demoStore: ObjectIdentifier? {
        guard let session, session.isDemo, let store = session.store else { return nil }
        return ObjectIdentifier(store)
    }

    private var demoMarker: (store: ObjectIdentifier, marker: AlertSeenMarker)?

    /// The newest alert already dealt with.
    private var marker: AlertSeenMarker? {
        if let demoStore { return demoMarker?.store == demoStore ? demoMarker?.marker : nil }
        guard let preferences, let id = preferences.lastSeenAlertID, let time = preferences.lastSeenAlertTime else { return nil }
        return AlertSeenMarker(id: id, t: time)
    }

    private func remember(_ marker: AlertSeenMarker) {
        if let demoStore {
            demoMarker = (demoStore, marker)
        } else {
            preferences?.markAlertSeen(id: marker.id, time: marker.t)
        }
    }

    private func announce(fetched alerts: AlertsState, now: Double) {
        guard alerts.isLoaded, let settings = alerts.settings else { return }
        announce(AlertNotifications.plan(fetched: alerts.events, settings: settings, seen: marker, now: now))
    }

    private func announce(_ plan: AlertNotifications.Plan) {
        // Once the session has left its hub, what is still on its way (a log answer, alerts held
        // back for it) is about a hub this device has forgotten: nothing of it is remembered or posted.
        guard let preferences, session?.store != nil else { return }
        // Remembered whether or not this device shows anything, so that switching notifications
        // on later does not bring up alerts from before.
        if let marker = plan.marker { remember(marker) }
        // A demo's alerts are about devices that do not exist: they stay inside the app, and
        // never reach the lock screen or Notification Centre.
        let isDemo = session?.isDemo ?? false
        let verdict = isDemo ? "kept back, a demo" : preferences.notificationsEnabled ? "posted" : "kept back, off on this device"
        note("notify: [\(plan.notifications.map(\.title).joined(separator: " + "))] \(verdict)")
        guard preferences.notificationsEnabled, !isDemo, !plan.notifications.isEmpty else { return }
        let notifications = plan.notifications
        let hub = session?.hub
        let previous = posting
        posting = Task {
            await previous?.value
            for notification in notifications {
                // The session left the hub while this batch waited its turn (`leftHub()`).
                guard self.session?.hub == hub else { return }
                await AlertsNotificationCenter.post(notification)
            }
        }
    }

    /// One line for the DEBUG probe; nothing at all in a release build.
    private func note(_ text: @autoclosure () -> String) {
        #if DEBUG
        trace.append(text())
        if trace.count > 24 { trace.removeFirst(trace.count - 24) }
        #endif
    }
}

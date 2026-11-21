import Foundation

/// A local notification to post for an alert. Title and body are the hub's own wording, the same
/// text it sends to ntfy and to webhooks.
public struct AlertNotification: Sendable, Hashable, Identifiable {
    /// Use as the notification request's identifier: posting the same alert twice then replaces
    /// the first instead of stacking a second.
    public let id: String
    /// The log entry it is about; nil for the "and N more" summary.
    public let eventID: String?
    public let title: String
    public let body: String
    /// The same for an alert and for its "back to normal", so the system groups the two.
    public let threadID: String
    /// True for an alert that needs attention; false for one that cleared (deliver it quietly).
    public let isFiring: Bool
    public let isTest: Bool
    /// ms since 1970.
    public let time: Double
}

/// The newest alert the app has already dealt with. Keep it across launches (it is `Codable`):
/// it is what stops an alert from being announced twice.
public struct AlertSeenMarker: Codable, Sendable, Hashable {
    public var id: String
    /// ms since 1970.
    public var t: Double

    public init(id: String, t: Double) {
        self.id = id
        self.t = t
    }

    public init(_ event: AlertEvent) {
        self.init(id: event.id, t: event.t)
    }
}

/// Which alerts become local notifications.
///
/// The hub decides whether an alert is worth announcing (`emit()` in alerts.js): always when it
/// fires, when it clears only if `notifyResolved` is on, and to the apps only while the "desktop"
/// channel is on. While the app is connected that decision arrives with each `alert` event; for
/// what happened while it was not, the same rule is applied here to the log.
public enum AlertNotifications {
    /// The most notifications one catch-up posts. With more alerts waiting, the newest are shown
    /// one by one and the older ones counted in a single summary.
    public static let maxBurst = 4
    /// Alerts older than this are not announced when the app catches up: they are history.
    public static let maxAge: Double = 24 * 3600 * 1000

    /// What to post, and the marker to remember afterwards.
    public struct Plan: Sendable, Hashable {
        /// In the order to post them, oldest first.
        public let notifications: [AlertNotification]
        /// How many alerts were due but share the first notification ("5 earlier alerts").
        public let omitted: Int
        /// Store this for the next call.
        public let marker: AlertSeenMarker?

        public static func nothing(marker: AlertSeenMarker?) -> Plan {
            Plan(notifications: [], omitted: 0, marker: marker)
        }
    }

    // const notify = state === 'firing' || this.cfg.notifyResolved;  …  notify: notify && this.cfg.channels.desktop
    /// Whether the hub would have told the apps to announce this log entry under `settings`.
    public static func shouldNotify(_ event: AlertEvent, settings: AlertSettings) -> Bool {
        guard settings.channels.desktop else { return false }
        switch event.state {
        case .firing: return true
        case .resolved: return settings.notifyResolved
        case .other: return false
        }
    }

    /// The notification for a log entry or a test alert.
    public static func notification(for event: AlertEvent) -> AlertNotification {
        let thread = event.test ? "test" : "\(event.ruleId ?? event.id)|\(event.device ?? "")"
        return AlertNotification(
            id: "alert-" + event.id, eventID: event.id,
            title: event.title.isEmpty ? "Device Monitor alert" : event.title, body: event.message,
            threadID: "alert-" + thread, isFiring: event.isFiring, isTest: event.test, time: event.t
        )
    }

    /// An `alert` event arrived on the live stream. `notify` is the hub's verdict; the marker
    /// keeps an alert that was already announced (or was picked up by a fetch in the meantime)
    /// from showing again.
    public static func plan(live event: AlertEvent, notify: Bool, seen: AlertSeenMarker?) -> Plan {
        let alreadySeen = seen.map { $0.id == event.id || event.t < $0.t } ?? false
        let marker = newer(AlertSeenMarker(event), than: seen)
        guard notify, !alreadySeen else { return .nothing(marker: marker) }
        return Plan(notifications: [notification(for: event)], omitted: 0, marker: marker)
    }

    /// The log was fetched (`GET /api/alerts`: the newest 150 entries, newest first).
    ///
    /// The very first fetch announces nothing: everything in the log happened before this app
    /// was watching. After that, the entries newer than the marker are announced if the hub
    /// would have announced them, unless they are older than `maxAge`.
    ///
    /// Fetch when the live stream (re)connects, before acting on its events: a live alert moves
    /// the marker past anything older that was missed.
    public static func plan(
        fetched events: [AlertEvent], settings: AlertSettings, seen: AlertSeenMarker?, now: Double,
        maxBurst: Int = maxBurst, maxAge: Double = maxAge
    ) -> Plan {
        // Newest first; entries of the same millisecond keep the hub's order.
        let ordered = events.enumerated().sorted { $0.element.t != $1.element.t ? $0.element.t > $1.element.t : $0.offset < $1.offset }.map(\.element)
        guard let seen else {
            // An empty log is remembered too, so that whatever comes next counts as new.
            return .nothing(marker: ordered.first.map(AlertSeenMarker.init) ?? AlertSeenMarker(id: "", t: 0))
        }
        let marker = ordered.first.map { newer(AlertSeenMarker($0), than: seen) } ?? seen

        // Everything listed above the marked entry is new. When the entry is gone (the log was
        // cleared or has moved on, or the marker is a test alert), go by time alone.
        let unseen: [AlertEvent]
        if let index = ordered.firstIndex(where: { $0.id == seen.id }) {
            unseen = Array(ordered[..<index])
        } else {
            unseen = ordered.filter { $0.t > seen.t }
        }
        let due = unseen.filter { shouldNotify($0, settings: settings) && now - $0.t <= maxAge }.reversed().map(notification(for:))
        let limit = max(1, maxBurst)
        guard due.count > limit else { return Plan(notifications: Array(due), omitted: 0, marker: marker) }

        // Too many to post one by one: the newest keep their own notification, the older ones
        // share one that is posted first.
        let shown = Array(due.suffix(limit - 1)), folded = Array(due.dropLast(shown.count))
        let summary = AlertNotification(
            id: "alert-summary-" + (folded.last?.eventID ?? ""), eventID: nil,
            title: folded.count == 1 ? "1 earlier alert" : "\(folded.count) earlier alerts", body: "Open Device Monitor to see what happened.",
            threadID: "alert-summary", isFiring: folded.contains { $0.isFiring }, isTest: false, time: folded.last?.time ?? now
        )
        return Plan(notifications: [summary] + shown, omitted: folded.count, marker: marker)
    }

    /// Markers only move forward in time.
    private static func newer(_ candidate: AlertSeenMarker, than seen: AlertSeenMarker?) -> AlertSeenMarker {
        guard let seen, candidate.t < seen.t else { return candidate }
        return seen
    }
}

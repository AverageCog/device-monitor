import Foundation

/// An alert that is firing now, ready for a list. Title and message are the hub's own words
/// (`text()` in alerts.js), in its language, units and time zone.
public struct ActiveAlertRow: Sendable, Hashable, Identifiable {
    /// `ActiveAlert.id`: one per rule and device.
    public let id: String
    public let title: String
    public let message: String
    /// "Since 2:36 PM", or "Since Nov 19 at 2:36 PM" when it began on another day.
    public let since: String
    /// How long ago that was: "5m ago" (`Format.ago`).
    public let ago: String
    public let kind: AlertRule.Kind
    /// A device id, or "*" for a rule that sums every device.
    public let deviceID: String
    public let deviceName: String?
    /// When it started firing, ms since 1970.
    public let sinceTime: Double

    /// One sentence for VoiceOver.
    public var spokenText: String { "\(title). \(message) \(since)." }
}

/// An entry of the alert log, ready for a list.
public struct AlertEventRow: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// A rule's condition was met.
        case firing
        /// It is over.
        case resolved
        /// "Send a test alert".
        case test
        /// A state this app does not know.
        case other(String)

        /// A word for a badge: "Alert", "Resolved", "Test".
        public var label: String {
            switch self {
            case .firing: "Alert"
            case .resolved: "Resolved"
            case .test: "Test"
            case .other(let raw): raw
            }
        }
    }

    public let id: String
    public let title: String
    public let message: String
    /// The time of day, "2:36 PM".
    public let time: String
    public let state: State
    public let kind: AlertRule.Kind?
    public let deviceID: String?
    public let deviceName: String?
    /// ms since 1970.
    public let t: Double

    public var isFiring: Bool { state == .firing }

    /// One sentence for VoiceOver.
    public var spokenText: String { "\(state.label): \(title). \(message) \(time)." }
}

/// The log entries of one day.
public struct AlertLogSection: Sendable, Hashable, Identifiable {
    /// The day's first instant, ms since 1970.
    public let id: Double
    /// "Today", "Yesterday", "Wednesday, Nov 18", or with the year for another year.
    public let title: String
    /// Newest first.
    public let rows: [AlertEventRow]
}

/// The Alerts screen's lists.
public enum AlertRows {
    /// Shown when nothing is firing.
    public static let noActiveAlerts = "No alerts right now."
    /// Shown for an empty log.
    public static let emptyLog = "Alerts will be listed here when they fire."
    public static let activeHeading = "Active"
    public static let logHeading = "History"

    /// The firing alerts in the hub's order, most recent first.
    public static func activeRows(
        _ active: [ActiveAlert], now: Double, locale: Locale = .current, timeZone: TimeZone = .current, calendar: Calendar? = nil
    ) -> [ActiveAlertRow] {
        let calendar = resolved(calendar, locale, timeZone)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        let time = style.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        let today = calendar.startOfDay(for: Date(hubTime: now))
        return active.map { alert in
            let date = alert.sinceDate
            let sameDay = calendar.startOfDay(for: date) == today
            let when = date.formatted(sameDay ? time : time.month(.abbreviated).day(.defaultDigits))
            return ActiveAlertRow(
                id: alert.id, title: alert.title, message: alert.message, since: "Since " + when, ago: Format.ago(alert.since, now: now),
                kind: alert.type, deviceID: alert.device, deviceName: alert.deviceName, sinceTime: alert.since
            )
        }
    }

    public static func eventRow(_ event: AlertEvent, locale: Locale = .current, timeZone: TimeZone = .current) -> AlertEventRow {
        let state: AlertEventRow.State
        if event.test {
            state = .test
        } else {
            switch event.state {
            case .firing: state = .firing
            case .resolved: state = .resolved
            case .other(let raw): state = .other(raw)
            }
        }
        return AlertEventRow(
            id: event.id, title: event.title, message: event.message, time: Format.clock(event.t, locale: locale, timeZone: timeZone),
            state: state, kind: event.type, deviceID: event.device, deviceName: event.deviceName, t: event.t
        )
    }

    /// The log grouped by local day, newest day and newest entry first. The hub's order is kept
    /// within a day (it lists the newest first, and entries of the same millisecond in the order
    /// they happened, reversed).
    public static func logSections(
        _ events: [AlertEvent], now: Double, locale: Locale = .current, timeZone: TimeZone = .current, calendar: Calendar? = nil
    ) -> [AlertLogSection] {
        let calendar = resolved(calendar, locale, timeZone)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        let today = calendar.startOfDay(for: Date(hubTime: now))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).map { calendar.startOfDay(for: $0) }
        let thisYear = calendar.component(.year, from: today)

        // Stable: Swift's sort does not promise to keep equal times in the hub's order.
        let ordered = events.enumerated().sorted { $0.element.t != $1.element.t ? $0.element.t > $1.element.t : $0.offset < $1.offset }.map(\.element)
        var sections: [(day: Date, rows: [AlertEventRow])] = []
        for event in ordered {
            let day = calendar.startOfDay(for: event.date)
            let row = eventRow(event, locale: locale, timeZone: timeZone)
            if let last = sections.indices.last, sections[last].day == day {
                sections[last].rows.append(row)
            } else {
                sections.append((day, [row]))
            }
        }
        return sections.map { section in
            let title: String
            if section.day == today {
                title = "Today"
            } else if section.day == yesterday {
                title = "Yesterday"
            } else {
                let dayStyle = style.weekday(.wide).month(.abbreviated).day(.defaultDigits)
                title = section.day.formatted(calendar.component(.year, from: section.day) == thisYear ? dayStyle : dayStyle.year(.defaultDigits))
            }
            return AlertLogSection(id: section.day.hubTime, title: title, rows: section.rows)
        }
    }

    private static func resolved(_ calendar: Calendar?, _ locale: Locale, _ timeZone: TimeZone) -> Calendar {
        var calendar = calendar ?? locale.calendar
        calendar.timeZone = timeZone
        return calendar
    }
}

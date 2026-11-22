import Foundation
import Testing
@testable import DMCore

/// The Alerts screen's lists, fed with what a real hub returned (the captured GET /api/alerts
/// payloads and the active lists of events.json).
@Suite struct AlertRowsTests {
    private typealias F = AlertFixtures
    private let fold = { (text: String) in FormatVectors.foldSpaces(text).replacingOccurrences(of: " at ", with: ", ") }

    private func zone(_ name: String) throws -> TimeZone {
        try #require(TimeZone(identifier: name))
    }

    @Test func activeAlertsKeepTheHubsWordsAndOrder() throws {
        let response = try HubJSON.decode(AlertsResponse.self, from: try Fixture.data("models/alerts.json"))
        let now = 1_795_214_200_000.0
        let rows = AlertRows.activeRows(response.active, now: now, locale: F.enUS, timeZone: try zone("America/Los_Angeles"))
        #expect(rows.count == 4)
        #expect(rows.map(\.id) == response.active.map(\.id))
        #expect(rows.map(\.title) == response.active.map(\.title))
        #expect(rows.map(\.message) == response.active.map(\.message))
        #expect(rows.map(\.kind) == [.dailyCost, .offline, .power, .disk])
        #expect(rows.map(\.deviceName) == ["All devices", "htpc", "dgx-station", "Lab PC"])
        #expect(rows.map(\.deviceID) == response.active.map(\.device))
        #expect(rows.map(\.sinceTime) == response.active.map(\.since))
        #expect(rows.map { fold($0.since) } == ["Since 2:36 PM", "Since 2:32 PM", "Since 2:31 PM", "Since 2:31 PM"])
        #expect(rows.map(\.ago) == response.active.map { Format.ago($0.since, now: now) })
        #expect(rows[0].ago == "33s ago")
        #expect(fold(rows[1].spokenText) == "htpc is offline. No reports since 2:36 PM. Since 2:32 PM.")
    }

    @Test func sinceNamesTheDayWhenItIsNotToday() throws {
        let los = try zone("America/Los_Angeles")
        let since = 1_795_213_927_000.0   // Nov 20, 2:32 PM in Los Angeles
        let alert = ActiveAlert(ruleId: "r", type: .offline, device: "d", deviceName: "D", since: since, title: "D is offline", message: "No reports since 2:32 PM.")
        func row(_ now: Double, _ zone: TimeZone) -> ActiveAlertRow {
            AlertRows.activeRows([alert], now: now, locale: F.enUS, timeZone: zone)[0]
        }
        #expect(fold(row(since + 60_000, los).since) == "Since 2:32 PM")
        #expect(fold(row(since + 9 * 3_600_000, los).since) == "Since 2:32 PM")          // 11:32 PM the same day
        #expect(fold(row(since + 10 * 3_600_000, los).since) == "Since Nov 20, 2:32 PM")  // past midnight
        #expect(row(since + 10 * 3_600_000, los).ago == "10h ago")
        // The phone's zone decides what "today" is: in Tokyo it is already the 21st, 7:32 AM.
        let tokyo = try zone("Asia/Tokyo")
        #expect(fold(row(since + 60_000, tokyo).since) == "Since 7:32 AM")
        #expect(fold(row(since + 17 * 3_600_000, tokyo).since) == "Since Nov 21, 7:32 AM")
        #expect(AlertRows.activeRows([], now: since, locale: F.enUS, timeZone: los).isEmpty)
    }

    @Test func activeListsOfTheHubMapOneToOne() throws {
        let fixture = try F.load(F.Events.self, "events.json")
        let tz = try zone(fixture.tz)
        var seen = 0
        for scenario in fixture.scenarios {
            for step in scenario.steps {
                let rows = AlertRows.activeRows(step.active, now: step.t, locale: F.enUS, timeZone: tz)
                #expect(rows.map(\.id) == step.active.map { $0.ruleId + "|" + $0.device })
                #expect(Set(rows.map(\.id)).count == rows.count)
                // The hub lists the most recent first; the rows keep that.
                #expect(rows.map(\.sinceTime) == rows.map(\.sinceTime).sorted(by: >))
                #expect(rows.allSatisfy { $0.since.hasPrefix("Since ") && !$0.title.isEmpty })
                seen += rows.count
            }
        }
        #expect(seen > 100)
    }

    @Test func eventRows() throws {
        let response = try HubJSON.decode(AlertsResponse.self, from: try Fixture.data("models/alerts.json"))
        let tz = try zone("America/Los_Angeles")
        let rows = response.events.map { AlertRows.eventRow($0, locale: F.enUS, timeZone: tz) }
        #expect(rows.count == response.events.count && rows.count == 10)
        #expect(rows.map(\.id) == response.events.map(\.id))
        #expect(rows.map(\.title) == response.events.map(\.title))
        #expect(rows.map(\.message) == response.events.map(\.message))
        #expect(rows.map(\.t) == response.events.map(\.t))
        #expect(rows.map { fold($0.time) } == response.events.map { fold(Format.clock($0.t, locale: F.enUS, timeZone: tz)) })
        #expect(fold(rows[0].time) == "2:36 PM")
        #expect(rows[0].state == .resolved && rows[0].state.label == "Resolved" && !rows[0].isFiring)
        #expect(rows[1].state == .firing && rows[1].state.label == "Alert" && rows[1].isFiring)
        #expect(rows[0].kind == .offline && rows[0].deviceID == "nas-01" && rows[0].deviceName == "nas")
        #expect(fold(rows[0].spokenText) == "Resolved: nas is back online. It was offline since 2:32 PM. 2:36 PM.")
        let test = AlertRows.eventRow(AlertEvent(id: "t", t: 1_795_214_200_000, title: "Device Monitor test alert", message: "Alerts from your hub will arrive like this.", test: true), locale: F.enUS, timeZone: tz)
        #expect(test.state == .test && test.state.label == "Test" && test.kind == nil && test.deviceID == nil)
        let odd = AlertRows.eventRow(AlertEvent(id: "o", t: 1, state: .other("snoozed")), locale: F.enUS, timeZone: tz)
        #expect(odd.state == .other("snoozed") && odd.state.label == "snoozed")
    }

    @Test func logIsGroupedByLocalDay() throws {
        let los = try zone("America/Los_Angeles")
        let noon = 1_795_204_800_000.0   // Fri Nov 20 2026, 12:00 in Los Angeles
        let day = 86_400_000.0
        func event(_ id: String, _ t: Double) -> AlertEvent {
            AlertEvent(id: id, t: t, state: .firing, title: id, message: "")
        }
        let events = [
            event("today-late", noon + 2 * 3_600_000), event("today-early", noon - 11 * 3_600_000),
            event("yesterday-late", noon - 13 * 3_600_000), event("yesterday", noon - day),
            event("wednesday", noon - 2 * day), event("last-week", noon - 8 * day),
            event("last-year", noon - 330 * day),
        ]
        let sections = AlertRows.logSections(events, now: noon + 3 * 3_600_000, locale: F.enUS, timeZone: los)
        #expect(sections.map { fold($0.title) } == ["Today", "Yesterday", "Wednesday, Nov 18", "Thursday, Nov 12", "Thursday, Dec 25, 2025"])
        #expect(sections.map { $0.rows.map(\.id) } == [["today-late", "today-early"], ["yesterday-late", "yesterday"], ["wednesday"], ["last-week"], ["last-year"]])
        #expect(sections[0].id == noon - 12 * 3_600_000)
        #expect(Set(sections.map(\.id)).count == sections.count)
        // The same log in Tokyo falls on other days: noon in Los Angeles is 5 AM the next day there.
        let tokyo = AlertRows.logSections(events, now: noon + 3 * 3_600_000, locale: F.enUS, timeZone: try zone("Asia/Tokyo"))
        #expect(tokyo.map { $0.rows.map(\.id) } == [["today-late"], ["today-early", "yesterday-late", "yesterday"], ["wednesday"], ["last-week"], ["last-year"]])
        #expect(tokyo.map { fold($0.title) } == ["Today", "Yesterday", "Thursday, Nov 19", "Friday, Nov 13", "Friday, Dec 26, 2025"])
        // Shuffled input comes out newest first; entries of one instant keep the order given.
        let tied = [event("b", noon), event("old", noon - 5000), event("a", noon), event("new", noon + 5000)]
        #expect(AlertRows.logSections(tied, now: noon + 6000, locale: F.enUS, timeZone: los).flatMap { $0.rows.map(\.id) } == ["new", "b", "a", "old"])
        #expect(AlertRows.logSections([], now: noon, locale: F.enUS, timeZone: los).isEmpty)
    }

    @Test func theCapturedLogIsOneDay() throws {
        let response = try HubJSON.decode(AlertsResponse.self, from: try Fixture.data("models/alerts.json"))
        let sections = AlertRows.logSections(response.events, now: 1_795_214_200_000, locale: F.enUS, timeZone: try zone("America/Los_Angeles"))
        #expect(sections.map(\.title) == ["Today"])
        #expect(sections[0].rows.map(\.id) == response.events.map(\.id))
        // A day later the same log is yesterday's.
        let later = AlertRows.logSections(response.events, now: 1_795_214_200_000 + 86_400_000, locale: F.enUS, timeZone: try zone("America/Los_Angeles"))
        #expect(later.map(\.title) == ["Yesterday"])
    }

    @Test func calendarCanBeGiven() throws {
        let los = try zone("America/Los_Angeles")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = try zone("UTC")   // replaced by the zone that is passed
        let noon = 1_795_204_800_000.0
        let events = [AlertEvent(id: "x", t: noon - 13 * 3_600_000)]
        let sections = AlertRows.logSections(events, now: noon, locale: Locale(identifier: "th_TH"), timeZone: los, calendar: gregorian)
        #expect(sections.count == 1 && sections[0].title == "Yesterday")
        #expect(!AlertRows.noActiveAlerts.isEmpty && !AlertRows.emptyLog.isEmpty && !AlertRows.activeHeading.isEmpty && !AlertRows.logHeading.isEmpty)
    }
}

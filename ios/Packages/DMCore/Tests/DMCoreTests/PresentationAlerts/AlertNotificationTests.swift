import Foundation
import Testing
@testable import DMCore

/// Which alerts become notifications, against events.json: a real Alerts instance was walked
/// through alerts firing and clearing under every combination of "notify when resolved" and the
/// app channel, and what it broadcast was recorded.
@Suite struct AlertNotificationTests {
    private typealias F = AlertFixtures
    private static let loaded = Result { try F.load(F.Events.self, "events.json") }

    private func event(_ id: String, t: Double, state: AlertEvent.State = .firing, rule: String = "r1", device: String = "d1") -> AlertEvent {
        AlertEvent(id: id, t: t, ruleId: rule, type: .cpu, device: device, deviceName: "Dev", state: state, value: 95, title: "Dev: CPU load 95% (\(id))", message: "Above 90%.")
    }

    // MARK: The hub's verdict

    @Test func shouldNotifyIsTheHubsNotifyFlag() throws {
        let fixture = try Self.loaded.get()
        #expect(fixture.scenarios.count == 4)
        var checked = 0, yes = 0
        for scenario in fixture.scenarios {
            #expect(scenario.settings.notifyResolved == scenario.notifyResolved && scenario.settings.channels.desktop == scenario.desktop)
            for message in scenario.steps.flatMap(\.messages) {
                #expect(message.type == "alert")
                checked += 1
                if message.notify { yes += 1 }
                if message.event.test {
                    // A test alert is announced whenever the app channel is on.
                    #expect(message.notify == scenario.desktop)
                } else {
                    #expect(AlertNotifications.shouldNotify(message.event, settings: scenario.settings) == message.notify, "\(message.event.title) with resolved \(scenario.notifyResolved), app channel \(scenario.desktop)")
                }
            }
        }
        #expect(checked == 60 && yes == 23)
        #expect(!AlertNotifications.shouldNotify(event("x", t: 1, state: .other("snoozed")), settings: AlertSettings()))
    }

    // MARK: Live events

    @Test func liveEventsNotifyOnceEach() throws {
        for scenario in try Self.loaded.get().scenarios {
            var marker: AlertSeenMarker?
            var posted: [String] = []
            let messages = scenario.steps.flatMap(\.messages)
            for message in messages {
                let plan = AlertNotifications.plan(live: message.event, notify: message.notify, seen: marker)
                #expect(plan.notifications.count == (message.notify ? 1 : 0), "\(message.event.title)")
                #expect(plan.omitted == 0)
                if let notification = plan.notifications.first {
                    #expect(notification.title == message.event.title && notification.body == message.event.message)
                    #expect(notification.eventID == message.event.id && notification.id == "alert-" + message.event.id)
                    #expect(notification.isFiring == (message.event.state == .firing) && notification.isTest == message.event.test)
                    posted.append(message.event.id)
                }
                marker = plan.marker
                #expect(marker?.id == message.event.id)
                // The stream reconnecting and repeating itself changes nothing.
                let again = AlertNotifications.plan(live: message.event, notify: message.notify, seen: marker)
                #expect(again.notifications.isEmpty && again.marker == marker)
            }
            #expect(posted == messages.filter(\.notify).map(\.event.id))
            #expect(Set(posted).count == posted.count)
            // Anything older than the marker, replayed, stays quiet too.
            for message in messages.dropLast() where message.event.t < (marker?.t ?? 0) {
                #expect(AlertNotifications.plan(live: message.event, notify: true, seen: marker).notifications.isEmpty)
            }
        }
    }

    // MARK: Catching up from the log

    @Test func pollingTheLogAnnouncesWhatTheHubWouldHave() throws {
        for scenario in try Self.loaded.get().scenarios {
            let byID = Dictionary(uniqueKeysWithValues: scenario.log.map { ($0.id, $0) })
            let verdicts = Dictionary(uniqueKeysWithValues: scenario.steps.flatMap(\.messages).map { ($0.event.id, $0.notify) })
            // First look at the log: nothing is announced, the newest entry is remembered.
            let first = AlertNotifications.plan(fetched: scenario.initialLog, settings: scenario.settings, seen: nil, now: scenario.steps[0].t)
            #expect(first.notifications.isEmpty)
            #expect(first.marker?.id == scenario.initialLog.first?.id)
            var marker = first.marker
            var posted: [String] = []
            for step in scenario.steps {
                let log = try step.logIds.map { try #require(byID[$0]) }
                let plan = AlertNotifications.plan(fetched: log, settings: scenario.settings, seen: marker, now: step.t, maxBurst: 100)
                #expect(plan.omitted == 0)
                // Exactly this step's log entries the hub flagged, oldest first.
                let expected = step.messages.filter { $0.notify && !$0.event.test }.map(\.event.id)
                #expect(plan.notifications.map(\.eventID) == expected, "\(step.label)")
                posted += plan.notifications.compactMap(\.eventID)
                marker = plan.marker
                #expect(marker?.id == log.first?.id)
                // Asking again without anything new is silent.
                #expect(AlertNotifications.plan(fetched: log, settings: scenario.settings, seen: marker, now: step.t).notifications.isEmpty)
            }
            #expect(Set(posted).count == posted.count)
            #expect(Set(posted) == Set(verdicts.filter { $0.value && byID[$0.key] != nil }.keys))
        }
    }

    @Test func oneLateFetchCatchesUpInOrderAndInBounds() throws {
        let scenario = try #require(try Self.loaded.get().scenarios.first { $0.notifyResolved && $0.desktop })
        let marker = AlertSeenMarker(try #require(scenario.initialLog.first))
        let now = try #require(scenario.steps.last).t
        let due = scenario.log.filter { $0.id != marker.id }.reversed().map(\.id)
        #expect(due.count == 14)

        let all = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now, maxBurst: 50)
        #expect(all.notifications.map(\.eventID) == due.map(Optional.some))
        #expect(all.marker?.id == scenario.log.first?.id)

        // The default burst: the newest three on their own, the eleven before them in one.
        let capped = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now)
        #expect(capped.notifications.count == AlertNotifications.maxBurst)
        #expect(capped.omitted == 11)
        #expect(capped.notifications.dropFirst().map(\.eventID) == due.suffix(3).map(Optional.some))
        let summary = try #require(capped.notifications.first)
        #expect(summary.eventID == nil && summary.title == "11 earlier alerts" && !summary.body.isEmpty && summary.isFiring)
        #expect(summary.id == "alert-summary-" + due[10])
        #expect(capped.marker == all.marker)
        // A cap of one leaves only the summary; exactly as many as the cap need none.
        let one = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now, maxBurst: 1)
        #expect(one.notifications.count == 1 && one.omitted == 14)
        let exact = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now, maxBurst: 14)
        #expect(exact.notifications.count == 14 && exact.omitted == 0)
        let oneOver = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now, maxBurst: 13)
        #expect(oneOver.notifications.count == 13 && oneOver.omitted == 2 && oneOver.notifications.first?.title == "2 earlier alerts")

        // Old news is not announced.
        let later = AlertNotifications.plan(fetched: scenario.log, settings: scenario.settings, seen: marker, now: now + AlertNotifications.maxAge + 3_600_000)
        #expect(later.notifications.isEmpty && later.marker == all.marker)
    }

    @Test func markerRules() {
        let settings = AlertSettings()
        let a = event("a", t: 1000), b = event("b", t: 2000), c = event("c", t: 2000, state: .resolved), d = event("d", t: 3000)
        // Never anything on the first fetch, also when the log is empty; what follows is new.
        let empty = AlertNotifications.plan(fetched: [], settings: settings, seen: nil, now: 5000)
        #expect(empty.notifications.isEmpty && empty.marker != nil)
        #expect(AlertNotifications.plan(fetched: [a], settings: settings, seen: empty.marker, now: 5000).notifications.map(\.eventID) == ["a"])
        // Entries of the same millisecond: everything listed above the marked one is new.
        let sameTime = AlertNotifications.plan(fetched: [d, c, b, a], settings: settings, seen: AlertSeenMarker(b), now: 5000)
        #expect(sameTime.notifications.map(\.eventID) == ["c", "d"])
        // The marked entry is gone (the log was cleared): go by time.
        let cleared = AlertNotifications.plan(fetched: [d], settings: settings, seen: AlertSeenMarker(id: "gone", t: 2000), now: 5000)
        #expect(cleared.notifications.map(\.eventID) == ["d"])
        #expect(AlertNotifications.plan(fetched: [b, a], settings: settings, seen: AlertSeenMarker(id: "gone", t: 2000), now: 5000).notifications.isEmpty)
        // An emptied log keeps the marker, and a marker never moves back.
        #expect(AlertNotifications.plan(fetched: [], settings: settings, seen: AlertSeenMarker(d), now: 5000).marker == AlertSeenMarker(d))
        #expect(AlertNotifications.plan(fetched: [a], settings: settings, seen: AlertSeenMarker(d), now: 5000).marker == AlertSeenMarker(d))
        #expect(AlertNotifications.plan(live: a, notify: true, seen: AlertSeenMarker(d)).marker == AlertSeenMarker(d))
        // A list that is not newest-first is put in order.
        let shuffled = AlertNotifications.plan(fetched: [a, d, b], settings: settings, seen: AlertSeenMarker(id: "x", t: 0), now: 5000)
        #expect(shuffled.notifications.map(\.eventID) == ["a", "b", "d"] && shuffled.marker?.id == "d")
        // The settings at the time of the fetch decide.
        var quiet = settings
        quiet.channels.desktop = false
        #expect(AlertNotifications.plan(fetched: [d, c, b, a], settings: quiet, seen: AlertSeenMarker(a), now: 5000).notifications.isEmpty)
        quiet.channels.desktop = true
        quiet.notifyResolved = false
        #expect(AlertNotifications.plan(fetched: [d, c, b, a], settings: quiet, seen: AlertSeenMarker(a), now: 5000).notifications.map(\.eventID) == ["b", "d"])
    }

    @Test func liveAndFetchedNeverDouble() {
        let settings = AlertSettings()
        let a = event("a", t: 1000), b = event("b", t: 2000), c = event("c", t: 3000)
        var marker = AlertNotifications.plan(fetched: [a], settings: settings, seen: nil, now: 4000).marker
        let live = AlertNotifications.plan(live: b, notify: true, seen: marker)
        #expect(live.notifications.count == 1)
        marker = live.marker
        // The fetch that follows already knows b, and announces only what came after.
        let fetched = AlertNotifications.plan(fetched: [c, b, a], settings: settings, seen: marker, now: 4000)
        #expect(fetched.notifications.map(\.eventID) == ["c"])
        marker = fetched.marker
        // And the stream delivering c late stays quiet.
        #expect(AlertNotifications.plan(live: c, notify: true, seen: marker).notifications.isEmpty)
        // A test alert is not in the log; the next fetch goes by its time.
        let test = AlertEvent(id: "t", t: 3500, title: "Device Monitor test alert", message: "Alerts from your hub will arrive like this.", test: true)
        let shown = AlertNotifications.plan(live: test, notify: true, seen: marker)
        #expect(shown.notifications.first?.isTest == true && shown.notifications.first?.threadID == "alert-test")
        #expect(AlertNotifications.plan(fetched: [c, b, a], settings: settings, seen: shown.marker, now: 4000).notifications.isEmpty)
        let d = event("d", t: 3600)
        #expect(AlertNotifications.plan(fetched: [d, c, b, a], settings: settings, seen: shown.marker, now: 4000).notifications.map(\.eventID) == ["d"])
    }

    @Test func notificationContent() throws {
        let firing = event("abc", t: 1000), resolved = event("def", t: 2000, state: .resolved)
        let one = AlertNotifications.notification(for: firing), two = AlertNotifications.notification(for: resolved)
        #expect(one.id == "alert-abc" && one.title == firing.title && one.body == "Above 90%." && one.isFiring && !one.isTest && one.time == 1000)
        #expect(!two.isFiring)
        // An alert and its all-clear share a thread; another device's alert does not.
        #expect(one.threadID == two.threadID)
        #expect(AlertNotifications.notification(for: event("x", t: 1, device: "d2")).threadID != one.threadID)
        #expect(AlertNotifications.notification(for: AlertEvent(id: "n", t: 1)).title == "Device Monitor alert")
        // The marker survives a relaunch.
        let marker = AlertSeenMarker(firing)
        #expect(try JSONDecoder().decode(AlertSeenMarker.self, from: JSONEncoder().encode(marker)) == marker)
    }
}

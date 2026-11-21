import Foundation
import Testing
@testable import DMCore

/// The demo hub's rule evaluation, against what `evaluate` in alerts.js does with the same readings.
@Suite struct DemoAlertsTests {
    static let device = DemoAlerts.Subject(id: "pc", name: "PC", online: true, lastSeen: 0)

    /// Alerts with one rule for the device "pc", and that rule as the hub stored it.
    final class Bench {
        var alerts = DemoAlerts(seed: 1, timeZone: DemoHubTests.gmt)
        let rule: AlertRule

        init(_ type: AlertRule.Kind, threshold: Double, minutes: Int = 0) {
            var settings = alerts.settings
            settings.rules = [AlertRule(type: type, device: "pc", threshold: threshold, minutes: minutes)]
            rule = alerts.update(settings)?.rules.first ?? settings.rules[0]
        }

        /// What the hub announces when `report` comes in at `now`.
        func report(_ report: Report, at now: Double, from device: DemoAlerts.Subject = DemoAlertsTests.device) -> [DemoAlerts.Emission] {
            alerts.onReport(report, from: device, now: now)
        }

        var active: [ActiveAlert] { alerts.active([DemoAlertsTests.device]) }
    }

    static func memory(_ percent: Double) -> Report {
        Report(memory: .init(total: 100e9, used: percent * 1e9))
    }

    @Test func anAlertClearsOnlyOnceTheReadingIsWellBelowTheLimit() {
        let bench = Bench(.mem, threshold: 50)
        #expect(bench.report(Self.memory(50), at: 1000).isEmpty)                                 // at the limit is not over it
        let fired = bench.report(Self.memory(51), at: 2000)
        #expect(fired.map(\.event.state) == [.firing] && fired.first?.event.title == "PC: Memory use 51%" && fired.first?.event.value == 51)
        #expect(fired.first?.notify == true && fired.first?.event.message == "Above 50%.")
        #expect(bench.report(Self.memory(80), at: 3000).isEmpty)                                 // still firing: said once
        #expect(bench.active.map(\.value) == [80] && bench.active.first?.since == 2000)
        // Memory has three points of hysteresis: 49 and 47.1 are below the limit but not clear of it.
        #expect(bench.report(Self.memory(49), at: 4000).isEmpty)
        #expect(bench.report(Self.memory(47.1), at: 5000).isEmpty)
        #expect(bench.active.count == 1)
        let cleared = bench.report(Self.memory(47), at: 6000)
        #expect(cleared.map(\.event.state) == [.resolved] && cleared.first?.event.title == "PC: Memory use back to normal")
        #expect(cleared.first?.event.message == "Now 47% (limit 50%)." && cleared.first?.event.ruleId == bench.rule.id)
        #expect(bench.active.isEmpty && bench.alerts.log.map(\.state) == [.firing, .resolved])
    }

    @Test func aRuleWithADurationWaitsThatLong() {
        let bench = Bench(.cpu, threshold: 90, minutes: 2)
        let busy = Report(cpu: .init(usage: 97)), calm = Report(cpu: .init(usage: 20))
        #expect(bench.report(busy, at: 0).isEmpty)
        #expect(bench.report(busy, at: 119_000).isEmpty)
        // Dropping below the limit starts the count again.
        #expect(bench.report(calm, at: 119_500).isEmpty)
        #expect(bench.report(busy, at: 120_000).isEmpty)
        #expect(bench.report(busy, at: 239_999).isEmpty)
        let fired = bench.report(busy, at: 240_000)
        #expect(fired.first?.event.title == "PC: CPU load 97%" && fired.first?.event.message == "Above 90% for 2 min.")
        // Five points of hysteresis for load.
        #expect(bench.report(Report(cpu: .init(usage: 86)), at: 241_000).isEmpty)
        #expect(bench.report(Report(cpu: .init(usage: 85)), at: 242_000).map(\.event.state) == [.resolved])
    }

    @Test func powerClearsFivePercentUnderItsLimit() {
        let bench = Bench(.power, threshold: 1000)
        let drawing = { (watts: Double) in Report(powerEst: PowerEstimate(watts: watts)) }
        let fired = bench.report(drawing(1270), at: 0)
        #expect(fired.first?.event.title == "PC: Power draw 1.27 kW" && fired.first?.event.message == "Above 1.00 kW.")
        #expect(bench.report(drawing(951), at: 1).isEmpty)
        #expect(bench.report(drawing(950), at: 2).first?.event.message == "Now 950 W (limit 1.00 kW).")
    }

    @Test func readingsADeviceDoesNotReportAreNotJudged() {
        let bench = Bench(.gpuTemp, threshold: 60)
        #expect(bench.report(Report(), at: 0).isEmpty)                                           // no GPU at all
        #expect(bench.report(Report(gpus: [.init(usage: 99)]), at: 1).isEmpty)                   // a GPU without a sensor
        // The hottest card counts, and the wording follows the unit the hub was told to use.
        var settings = bench.alerts.settings
        settings.tempUnit = .fahrenheit
        _ = bench.alerts.update(settings)
        let fired = bench.report(Report(gpus: [.init(temp: 55), .init(temp: 71)]), at: 2)
        #expect(fired.first?.event.title == "PC: GPU temperature 160\u{B0}F" && fired.first?.event.message == "Above 140\u{B0}F.")
        // A rule for one device does not look at another.
        let other = DemoAlerts.Subject(id: "other", name: "Other", online: true, lastSeen: 0)
        #expect(bench.report(Report(gpus: [.init(temp: 99)]), at: 3, from: other).isEmpty)
    }
}

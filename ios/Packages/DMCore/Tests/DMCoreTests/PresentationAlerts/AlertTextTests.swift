import Foundation
import Testing
@testable import DMCore

/// Alert wording against values.json (the hub's fmt() and temp()) and texts.json (its text()).
@Suite struct AlertTextTests {
    private typealias F = AlertFixtures
    private let fold = FormatVectors.foldSpaces

    @Test func valuesAreWrittenAsTheHubWritesThem() throws {
        let rows = try F.load(F.Values.self, "values.json").rows
        #expect(rows.count > 2000)
        var failures: [String] = []
        for row in rows {
            let ours: String
            if row.type == "temp()" {
                ours = AlertText.temperature(try #require(row.value), unit: row.unit)
            } else {
                ours = AlertText.value(AlertRule.Kind(rawValue: row.type), row.value, unit: row.unit, currency: row.currency)
            }
            if fold(ours) != fold(row.text) { failures.append("\(row.type) \(row.value.map(JS.string) ?? "nil") \(row.unit.rawValue) \(row.currency ?? "-"): ours \"\(ours)\", hub \"\(row.text)\"") }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(rows.count) differ:\n\(failures.prefix(25).joined(separator: "\n"))")
    }

    @Test func limitsNamesAndDurationsFitTheHubsMessages() throws {
        let fixture = try F.load(F.Texts.self, "texts.json")
        #expect(fixture.rows.count == 104)
        #expect(AlertText.allDevices == fixture.allDevices)
        let devices = fixture.devices.map { Device(id: $0.id, name: $0.name) }
        var checkedMessages = 0
        for row in fixture.rows {
            let rule = row.rule, currency = row.detail?.currency
            let limit = AlertText.limit(of: rule, unit: row.unit, currency: currency)
            let name = AlertText.deviceName(row.device, devices: devices)
            #expect(fold(limit) == fold(row.limit), "\(rule)")
            #expect(name == row.deviceName, "\(row.device)")
            let value = AlertText.value(rule.type, row.value, unit: row.unit, currency: currency)
            let duration = AlertText.duration(minutes: rule.minutes)
            // The hub's own sentences, rebuilt from the parts the app writes.
            switch (rule.type, row.state) {
            case (.cpuTemp, "firing"), (.gpuTemp, "firing"), (.cpu, "firing"), (.gpu, "firing"), (.mem, "firing"), (.power, "firing"):
                #expect(row.title == "\(name): \(rule.type.label) \(value)")
                #expect(row.message == "Above \(limit)\(duration).")
                // The rule's one-line description says the same thing.
                #expect(AlertText.condition(of: rule, unit: row.unit, currency: currency) == "\(rule.type.label) above \(limit)\(duration)")
                checkedMessages += 1
            case (.cpuTemp, _), (.gpuTemp, _), (.cpu, _), (.gpu, _), (.mem, _), (.power, _):
                #expect(row.message == "Now \(value) (limit \(limit)).")
                checkedMessages += 1
            case (.disk, "firing"):
                #expect(row.message.hasPrefix("Over your \(limit) limit"))
                #expect(row.title.hasSuffix("is \(value) full"))
                checkedMessages += 1
            case (.disk, _):
                #expect(row.title == "\(name): disk space back under \(limit)")
                #expect(row.message == "Now \(value) used.")
                checkedMessages += 1
            case (.dailyCost, _):
                #expect(fold(row.title) == fold("\(name): electricity today is \(value)"))
                #expect(fold(row.message) == fold("Over your \(limit) daily limit."))
                #expect(fold(AlertText.condition(of: rule, unit: row.unit, currency: currency)) == fold("Electricity cost today above \(limit)"))
                checkedMessages += 1
            case (.offline, "firing"):
                #expect(row.title == "\(name) is offline")
                #expect(limit.isEmpty)
            default:
                #expect(row.title == "\(name) is back online")
            }
        }
        #expect(checkedMessages == 92)
    }

    // The wording below is the app's own; these pin it down.

    @Test func ruleSummaries() {
        let devices = [Device(id: "nas-01", name: "nas"), Device(id: "lab", name: "Lab PC")]
        func summary(_ rule: AlertRule, _ unit: TemperatureUnit = .celsius, _ currency: String? = nil) -> String {
            fold(AlertText.summary(of: rule, devices: devices, unit: unit, currency: currency))
        }
        #expect(summary(AlertRule(type: .cpuTemp, threshold: 90, minutes: 2)) == "CPU temperature above 90°C for 2 min · All devices")
        #expect(summary(AlertRule(type: .cpuTemp, threshold: 90, minutes: 2), .fahrenheit) == "CPU temperature above 194°F for 2 min · All devices")
        #expect(summary(AlertRule(type: .gpuTemp, device: "lab", threshold: 85, minutes: 0)) == "GPU temperature above 85°C · Lab PC")
        #expect(summary(AlertRule(type: .offline, minutes: 10)) == "Offline for 10 min · All devices")
        #expect(summary(AlertRule(type: .offline, device: "nas-01", minutes: 1)) == "Offline for 1 min · nas")
        #expect(summary(AlertRule(type: .disk, device: "gone", threshold: 90)) == "Disk space used above 90% · gone")
        #expect(summary(AlertRule(type: .cpu, threshold: 95, minutes: 10)) == "CPU load above 95% for 10 min · All devices")
        #expect(summary(AlertRule(type: .mem, threshold: 97.5, minutes: 5)) == "Memory use above 98% for 5 min · All devices")
        #expect(summary(AlertRule(type: .power, threshold: 1000, minutes: 5)) == "Power draw above 1.00 kW for 5 min · All devices")
        #expect(summary(AlertRule(type: .power, threshold: 450)) == "Power draw above 450 W · All devices")
        #expect(summary(AlertRule(type: .dailyCost, threshold: 5, minutes: 30), .celsius, "EUR") == "Electricity cost today above €5.00 · All devices")
        #expect(summary(AlertRule(type: .dailyCost, threshold: 2.5)) == "Electricity cost today above $2.50 · All devices")
        // A rule without its limit yet still reads as a sentence.
        #expect(summary(AlertRule(type: .cpu)) == "CPU load above  · All devices")
    }

    @Test func clearingSentences() {
        func clearing(_ rule: AlertRule, _ unit: TemperatureUnit = .celsius, _ currency: String? = nil) -> String {
            AlertText.clearing(of: rule, unit: unit, currency: currency)
        }
        #expect(clearing(AlertRule(type: .cpuTemp, threshold: 90)) == "Clears at 87°C or below.")
        #expect(clearing(AlertRule(type: .cpuTemp, threshold: 90), .fahrenheit) == "Clears at 189°F or below.")
        #expect(clearing(AlertRule(type: .cpu, threshold: 90)) == "Clears at 85% or below.")
        #expect(clearing(AlertRule(type: .mem, threshold: 80)) == "Clears at 77% or below.")
        #expect(clearing(AlertRule(type: .disk, threshold: 90)) == "Clears at 89% or below.")
        #expect(clearing(AlertRule(type: .power, threshold: 1000)) == "Clears at 950 W or below.")
        #expect(clearing(AlertRule(type: .offline, minutes: 5)) == "Clears when the device reports again.")
        #expect(clearing(AlertRule(type: .dailyCost, threshold: 5)) == "Starts over at midnight.")
        #expect(clearing(AlertRule(type: .gpu)) == "")
        #expect(clearing(AlertRule(type: .other("fan"), threshold: 3)) == "")
        #expect(!AlertText.needsPrice.isEmpty)
    }

    @Test func deviceNames() {
        let devices = [Device(id: "a", name: "Alpha"), Device(id: "b", name: ""), Device(id: "c")]
        #expect(AlertText.deviceName("*", devices: devices) == "All devices")
        #expect(AlertText.deviceName("a", devices: devices) == "Alpha")
        #expect(AlertText.deviceName("b", devices: devices) == "b")
        #expect(AlertText.deviceName("c", devices: devices) == "c")
        #expect(AlertText.deviceName("gone", devices: devices) == "gone")
    }
}

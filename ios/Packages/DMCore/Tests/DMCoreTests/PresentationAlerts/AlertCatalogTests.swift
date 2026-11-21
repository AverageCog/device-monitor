import Foundation
import Testing
@testable import DMCore

/// The rule types, defaults and limits against types.json (TYPES, DEFAULT_RULES and a fresh
/// hub's settings), and when an alert clears against events.json (the hub's evaluate()).
@Suite struct AlertCatalogTests {
    private typealias F = AlertFixtures

    @Test func ruleTypesMatchTheHubsTable() throws {
        let fixture = try F.load(F.Types.self, "types.json")
        #expect(fixture.types.count == 9)
        #expect(AlertRuleCatalog.specs.map(\.kind.rawValue) == fixture.types.map(\.type))
        #expect(AlertRule.Kind.allCases == AlertRuleCatalog.specs.map(\.kind))
        for (spec, theirs) in zip(AlertRuleCatalog.specs, fixture.types) {
            #expect(spec.label == theirs.label, "\(theirs.type)")
            #expect(spec.thresholdRange.map { [$0.lowerBound, $0.upperBound] } == theirs.threshold, "\(theirs.type)")
            #expect((spec.unit == .none) == (theirs.threshold == nil), "\(theirs.type)")
            switch (spec.clearing, theirs.hyst) {
            case (.below(let margin), .fixed(let hyst)): #expect(margin == hyst, "\(theirs.type)")
            case (.belowFraction(let share), .unset): #expect(share == 0.05 && spec.kind == .power, "\(theirs.type)")
            // The daily cost has no hysteresis entry either, but evaluate() never sees it.
            case (.nextDay, .unset): #expect(spec.kind == .dailyCost)
            case (.onReport, .absent): #expect(spec.kind == .offline)
            default: Issue.record("\(theirs.type): clearing \(spec.clearing) does not fit hyst \(theirs.hyst)")
            }
            #expect(spec.id == theirs.type)
            #expect(AlertRuleCatalog.spec(for: spec.kind) == spec)
        }
        #expect(AlertRuleCatalog.spec(for: .other("fan")) == nil)
        #expect(AlertRuleCatalog.maxRules == fixture.maxRules)
    }

    @Test func unitsDurationsAndMinutes() {
        let units = AlertRuleCatalog.specs.map(\.unit)
        #expect(units == [.none, .temperature, .temperature, .percent, .percent, .percent, .percent, .watts, .currency])
        #expect(AlertRuleCatalog.specs.filter { !$0.usesDuration }.map(\.kind) == [.dailyCost])
        #expect(AlertRuleCatalog.specs.map(\.minutesRange.lowerBound) == [1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(AlertRuleCatalog.specs.allSatisfy { $0.minutesRange.upperBound == 1440 })
    }

    @Test func defaultRulesAreTheHubs() throws {
        let fixture = try F.load(F.Types.self, "types.json")
        var counter = 0
        let ours = AlertRuleCatalog.defaultRules {
            counter += 1
            return String(repeating: "0", count: 11) + String(counter)
        }
        #expect(ours.count == fixture.defaultRules.count)
        for (rule, theirs) in zip(ours, fixture.defaultRules) {
            #expect(rule.type.rawValue == theirs.type)
            #expect(rule.device == theirs.device)
            #expect(rule.threshold == theirs.threshold)
            #expect(rule.minutes == theirs.minutes)
            #expect(rule.enabled == theirs.enabled)
        }
        #expect(ours.map(\.id) == ["000000000001", "000000000002", "000000000003", "000000000004"])
        // Fresh ids are of the form the hub keeps, and differ.
        let fresh = AlertRuleCatalog.defaultRules()
        #expect(fresh.allSatisfy { AlertValidation.isRuleID($0.id) })
        #expect(Set(fresh.map(\.id)).count == 4)
        // A fresh hub's whole settings are what the model's defaults say.
        let defaults = fixture.defaultSettings
        #expect(defaults.channels == AlertChannels())
        #expect(defaults.notifyResolved == AlertSettings().notifyResolved && defaults.tempUnit == AlertSettings().tempUnit)
        #expect(AlertValidation.isAcceptable(defaults))
    }

    @Test func everyNewRuleIsOneTheHubAccepts() {
        for spec in AlertRuleCatalog.specs {
            let rule = AlertRuleCatalog.newRule(spec.kind, device: "nas-01", id: "0123456789ab")
            #expect(AlertValidation.issues(for: rule).isEmpty, "\(spec.kind)")
            #expect(rule.isAcceptable && rule.enabled && rule.device == "nas-01" && rule.id == "0123456789ab")
            #expect((rule.threshold == nil) == (spec.thresholdRange == nil))
            #expect(rule.minutes == spec.defaultMinutes && rule.threshold == spec.defaultThreshold)
        }
        #expect(AlertRuleCatalog.newRule(.cpu).appliesToAllDevices)
    }

    @Test func alertsClearWhereTheHubClearsThem() throws {
        let rows = try F.load(F.Events.self, "events.json").clears
        #expect(rows.count > 90)
        #expect(rows.contains { $0.cleared } && rows.contains { !$0.cleared })
        for row in rows {
            let spec = try #require(AlertRuleCatalog.spec(for: AlertRule.Kind(rawValue: row.type)))
            let level = try #require(spec.clearsAt(threshold: row.threshold), "\(row.type)")
            #expect((row.value <= level) == row.cleared, "\(row.type) limit \(row.threshold) reading \(row.value): clears at \(level)")
        }
        #expect(AlertRuleCatalog.spec(for: .offline)?.clearsAt(threshold: 1) == nil)
        #expect(AlertRuleCatalog.spec(for: .dailyCost)?.clearsAt(threshold: 1) == nil)
    }

    // MARK: Limits in the user's unit

    @Test func celsiusAndOtherLimitsAreShownAsStored() {
        for kind in AlertRule.Kind.allCases {
            for value in [1.0, 20, 85, 90.5, 97.5, 1000, 0.01] {
                #expect(AlertThresholds.displayValue(value, kind: kind, unit: .celsius) == value)
                #expect(AlertThresholds.storedValue(fromDisplay: value, kind: kind, unit: .celsius) == value)
                guard kind != .cpuTemp, kind != .gpuTemp else { continue }
                #expect(AlertThresholds.displayValue(value, kind: kind, unit: .fahrenheit) == value)
                #expect(AlertThresholds.storedValue(fromDisplay: value, kind: kind, unit: .fahrenheit, current: 3) == value)
            }
            #expect(AlertThresholds.displayRange(kind: kind, unit: .celsius) == kind.thresholdRange)
        }
    }

    @Test func fahrenheitLimitsRoundTripWithoutDrift() {
        // Every whole Fahrenheit limit the hub accepts: store it, show it, store it again.
        for fahrenheit in stride(from: 68.0, through: 302.0, by: 1) {
            let stored = AlertThresholds.storedValue(fromDisplay: fahrenheit, kind: .cpuTemp, unit: .fahrenheit)
            #expect(AlertThresholds.displayValue(stored, kind: .cpuTemp, unit: .fahrenheit) == fahrenheit)
            #expect(AlertThresholds.storedValue(fromDisplay: fahrenheit, kind: .cpuTemp, unit: .fahrenheit, current: stored) == stored)
            #expect(AlertRule.Kind.cpuTemp.thresholdRange?.contains(stored) == true, "\(fahrenheit)°F is \(stored)°C")
            // The hub's own text for the stored limit says the number that was typed.
            #expect(AlertText.temperature(stored, unit: .fahrenheit) == "\(Int(fahrenheit))°F")
        }
        // Limits saved in Celsius survive being opened and saved in Fahrenheit, however odd.
        for celsius in [20.0, 37.5, 85, 90, 90.3, 91, 99.99, 150] {
            let shown = AlertThresholds.displayValue(celsius, kind: .gpuTemp, unit: .fahrenheit)
            #expect(shown == shown.rounded())
            #expect(AlertThresholds.storedValue(fromDisplay: shown, kind: .gpuTemp, unit: .fahrenheit, current: celsius) == celsius)
        }
        // A changed number is converted, exactly.
        #expect(AlertThresholds.storedValue(fromDisplay: 194, kind: .cpuTemp, unit: .fahrenheit, current: 85) == 90)
        #expect(AlertThresholds.storedValue(fromDisplay: 195, kind: .cpuTemp, unit: .fahrenheit, current: 90) == (195.0 - 32) * 5 / 9)
        #expect(AlertThresholds.displayRange(kind: .cpuTemp, unit: .fahrenheit) == 68...302)
    }

    @Test func fieldTextAndUnitLabels() {
        let enUS = F.enUS
        #expect(AlertThresholds.fieldText(90, kind: .cpuTemp, unit: .celsius, locale: enUS) == "90")
        #expect(AlertThresholds.fieldText(90, kind: .cpuTemp, unit: .fahrenheit, locale: enUS) == "194")
        #expect(AlertThresholds.fieldText(97.5, kind: .mem, unit: .fahrenheit, locale: enUS) == "97.5")
        #expect(AlertThresholds.fieldText(2.5, kind: .dailyCost, unit: .celsius, locale: Locale(identifier: "de_DE")) == "2,5")
        #expect(AlertThresholds.fieldText(nil, kind: .offline, unit: .celsius, locale: enUS) == "")
        #expect(AlertThresholds.unitLabel(kind: .cpuTemp, unit: .celsius) == "°C")
        #expect(AlertThresholds.unitLabel(kind: .gpuTemp, unit: .fahrenheit) == "°F")
        #expect(AlertThresholds.unitLabel(kind: .disk, unit: .fahrenheit) == "%")
        #expect(AlertThresholds.unitLabel(kind: .power, unit: .celsius) == "W")
        #expect(AlertThresholds.unitLabel(kind: .dailyCost, unit: .celsius, currency: "EUR") == "EUR")
        #expect(AlertThresholds.unitLabel(kind: .dailyCost, unit: .celsius) == "")
        #expect(AlertThresholds.unitLabel(kind: .offline, unit: .celsius) == "")
        #expect(AlertThresholds.unitLabel(kind: .other("fan"), unit: .celsius) == "")
    }
}

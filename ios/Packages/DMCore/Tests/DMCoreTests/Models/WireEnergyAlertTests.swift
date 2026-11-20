import Foundation
import Testing
@testable import DMCore

/// Energy totals, the saved price, and alerts as a real hub sends them.
@Suite struct WireEnergyAlertTests {
    private func summary(_ id: String, in response: EnergyResponse) throws -> UsageSummary {
        try #require(response.devices.first { $0.id == id })
    }

    // MARK: Energy

    @Test func usageWithoutASavedPriceHasNoCost() throws {
        let e = try ModelFixture.decode(EnergyResponse.self, "energy-7d-no-price.json")
        #expect(e.settings == nil)
        #expect(e.bounds.count == 8)
        #expect(e.bounds == e.bounds.sorted())
        #expect(e.devices.map(\.id) == [ModelFixture.workstation, ModelFixture.dgx, ModelFixture.macbook, ModelFixture.nas, ModelFixture.lab, ModelFixture.htpc])
        for d in e.devices {
            #expect(d.cost == nil && d.costBuckets == nil)
            #expect(d.buckets.count == e.bounds.count - 1)
            // `wh` is the rounded sum of the buckets.
            #expect(abs(d.buckets.reduce(0, +) - d.wh) <= 1)
            #expect(d.firstData != nil && d.firstDataDate != nil)
            #expect(d.stats.power != nil && d.stats.cpu != nil && d.stats.mem != nil)
        }

        let dgx = try summary(ModelFixture.dgx, in: e)
        #expect(dgx.wh == 131_122)
        #expect(dgx.minutes == 2820)          // 50 hours minus the three it was off
        #expect(dgx.estimatedMinutes == 0)
        #expect(dgx.stats.gpu?.peak == 100)
        #expect(dgx.stats.power?.peak == 2990)
        #expect(dgx.bytes.rx > dgx.bytes.tx && dgx.bytes.dr > dgx.bytes.dw)

        // Minutes recorded before the hub tracked power are estimated from load.
        let mac = try summary(ModelFixture.macbook, in: e)
        #expect(mac.minutes == 3000)
        #expect(mac.estimatedMinutes == 1801)
        #expect(mac.stats.gpuTemp == nil)
        #expect(mac.stats.cpuTemp != nil)

        let nas = try summary(ModelFixture.nas, in: e)
        #expect(nas.estimatedMinutes == 2999)
        #expect(nas.stats.gpu == nil && nas.stats.cpuTemp == nil && nas.stats.gpuTemp == nil)
        #expect(nas.stats.mem?.avg == 23)

        // A device first seen minutes ago.
        let lab = try summary(ModelFixture.lab, in: e)
        #expect(lab.minutes == 1)
        #expect(lab.wh == 4)
        #expect(lab.bytes == UsageSummary.Bytes(rx: 0, tx: 0, dr: 0, dw: 0))
        #expect((lab.firstData ?? 0) > (nas.firstData ?? 0))
    }

    @Test func usageWithAFlatRate() throws {
        let e = try ModelFixture.decode(EnergyResponse.self, "energy-7d-flat.json")
        let settings = try #require(e.settings)
        #expect(settings == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        #expect(!settings.isTimeOfUse)
        for d in e.devices {
            let cost = try #require(d.cost)
            let buckets = try #require(d.costBuckets)
            #expect(buckets.count == 7)
            #expect(abs(buckets.reduce(0, +) - cost) < 0.001)
            // A flat rate prices every watt-hour the same.
            #expect(abs(cost - d.wh / 1000 * 0.316) < 0.001)
        }
        #expect(try summary(ModelFixture.dgx, in: e).cost == 41.4346)
    }

    @Test func hourlyUsageWithTimeOfUseRates() throws {
        let e = try ModelFixture.decode(EnergyResponse.self, "energy-24h-tou.json")
        #expect(e.bounds.count == 25)
        #expect(zip(e.bounds, e.bounds.dropFirst()).allSatisfy { $1 - $0 == 3_600_000 })
        let settings = try #require(e.settings)
        #expect(settings.region == "custom" && settings.rate == 0.25 && settings.currency == "EUR")
        #expect(settings.isTimeOfUse)
        // Sorted by start, hours in quarter steps, rates rounded to four decimals.
        #expect(settings.tou == [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)])
        for d in e.devices {
            #expect(d.buckets.count == 24 && d.costBuckets?.count == 24)
            #expect(abs((d.costBuckets ?? []).reduce(0, +) - (d.cost ?? -1)) < 0.001)
        }
        // Dearer than the base rate would be, cheaper than the peak rate.
        let dgx = try summary(ModelFixture.dgx, in: e)
        #expect((dgx.cost ?? 0) > dgx.wh / 1000 * 0.1235 && (dgx.cost ?? 0) < dgx.wh / 1000 * 0.42)
        #expect(try HubJSON.decode(EnergyResponse.self, from: try HubJSON.encode(e)) == e)
    }

    @Test func savedPriceIsNullUntilSomeoneSavesOne() throws {
        let stages = try ModelFixture.decode([String: EnergySettings?].self, "energy-settings.json")
        #expect(stages.keys.sorted() == ["beforeSaving", "get", "putFlat", "putTou"])
        #expect(stages["beforeSaving"] == .some(nil))
        #expect(stages["putFlat"] == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        let tou = EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)])
        #expect(stages["putTou"] == tou)
        #expect(stages["get"] == tou)
        // The body of GET /api/energy/settings on a hub without a price is the bare word `null`.
        #expect(try HubJSON.decode(EnergySettings?.self, from: Data("null".utf8)) == nil)
        #expect(try HubJSON.decode(EnergySettings?.self, from: try HubJSON.encode(tou)) == tou)
    }

    // MARK: Alerts

    @Test func defaultAlertSettings() throws {
        let a = try ModelFixture.decode(AlertsResponse.self, "alerts-default.json")
        #expect(a.settings.rules.map(\.type) == [.offline, .cpuTemp, .gpuTemp, .disk])
        #expect(a.settings.rules.map(\.threshold) == [nil, 90, 85, 90])
        #expect(a.settings.rules.map(\.minutes) == [10, 2, 2, 0])
        #expect(a.settings.rules.allSatisfy { $0.enabled && $0.appliesToAllDevices && $0.isAcceptable })
        #expect(a.settings.rules.allSatisfy { $0.id.count == 12 && $0.id.allSatisfy(\.isHexDigit) })
        #expect(a.settings.channels == AlertChannels(desktop: true, ntfy: .init(enabled: false, server: "https://ntfy.sh", topic: "", email: ""), webhook: .init(enabled: false, url: "", keepUrl: false)))
        #expect(a.settings.channels == AlertChannels())
        #expect(a.settings.notifyResolved)
        #expect(a.settings.tempUnit == .celsius)
        #expect(a.priceSet)
        // The full disk on the lab PC tripped the default disk rule on its first report.
        #expect(a.active.map(\.type) == [.disk])
        #expect(a.events.map(\.type) == [.disk])
        #expect(a.events.first?.deviceName == "LAB-PC-03")   // logged before the rename
        #expect(a.active.first?.deviceName == "Lab PC")
    }

    @Test func alertsAfterFiringAndResolving() throws {
        let a = try ModelFixture.decode(AlertsResponse.self, "alerts.json")
        let settings = a.settings
        #expect(settings.rules.map(\.type) == [.offline, .offline, .cpuTemp, .gpuTemp, .disk, .cpu, .power, .dailyCost, .mem])
        #expect(settings.rules.map(\.device) == [ModelFixture.htpc, ModelFixture.nas, "*", "*", "*", ModelFixture.workstation, "*", "*", "*"])
        #expect(settings.rules.map(\.threshold) == [nil, nil, 90, 85, 90, 90, 1000, 0.01, 97.5])
        #expect(settings.rules.map(\.minutes) == [1, 1, 2, 2, 0, 0, 0, 0, 5])
        #expect(settings.rules.map(\.enabled) == [true, true, true, false, true, true, true, true, true])
        #expect(settings.rules.dropFirst().first?.id == "b0b0b0b0b0b1")   // ids chosen by the client are kept
        #expect(settings.rules.map(\.id).suffix(4) == ["c0ffee123456", "feedfacecafe", "deadbeef0001", "abcdef012345"])
        #expect(settings.rules.allSatisfy { $0.isAcceptable })
        #expect(settings.channels.desktop)
        #expect(settings.channels.ntfy == .init(enabled: true, server: "https://ntfy.sh", topic: "dm-fixture-topic", email: "alerts@example.com"))
        // The webhook URL never leaves the hub: only whether one is stored.
        #expect(settings.channels.webhook == .init(enabled: true, url: "", keepUrl: true))
        #expect(settings.channels.webhook.hasUrl)
        #expect(!settings.notifyResolved)
        #expect(settings.tempUnit == .fahrenheit)
        #expect(a.priceSet)

        #expect(a.active.map(\.type) == [.dailyCost, .offline, .power, .disk])
        #expect(a.active.map(\.since) == a.active.map(\.since).sorted(by: >))
        let cost = try #require(a.active.first)
        #expect(cost.device == "*" && cost.deviceName == "All devices")
        #expect(cost.threshold == 0.01 && (cost.value ?? 0) > 0.01)
        #expect(cost.id == "deadbeef0001|*")
        #expect(cost.title.hasPrefix("All devices: electricity today is \u{20AC}"))
        let offline = a.active[1]
        #expect(offline.device == ModelFixture.htpc && offline.deviceName == "htpc")
        #expect(offline.value == nil && offline.threshold == nil)
        #expect(offline.title == "htpc is offline")
        #expect(offline.message.hasPrefix("No reports since "))
        #expect(offline.sinceDate == Date(timeIntervalSince1970: offline.since / 1000))
        let power = a.active[2]
        #expect(power.ruleId == "feedfacecafe" && power.device == ModelFixture.dgx && power.threshold == 1000)
        #expect(power.message == "Above 1.00 kW.")
        let disk = a.active[3]
        #expect(disk.deviceName == "Lab PC" && disk.threshold == 90)
        #expect(disk.title == "Lab PC: disk C: is 95% full")
        #expect(disk.message == "Over your 90% limit \u{B7} 12.3 GB free.")

        // The log, newest first.
        #expect(a.events.count == 10)
        #expect(a.events.map(\.t) == a.events.map(\.t).sorted(by: >))
        #expect(Set(a.events.map(\.id)).count == a.events.count)
        #expect(a.events.allSatisfy { !$0.test && $0.ruleId != nil && $0.device != nil && !$0.title.isEmpty && !$0.message.isEmpty })
        #expect(a.events.map(\.type) == [.offline, .dailyCost, .offline, .offline, .offline, .offline, .cpu, .power, .cpu, .disk])
        #expect(a.events.map(\.state) == [.resolved, .firing, .firing, .resolved, .firing, .firing, .resolved, .firing, .firing, .firing])
        let cpuFired = a.events[8], cpuCleared = a.events[6]
        #expect(cpuFired.ruleId == "c0ffee123456" && cpuFired.device == ModelFixture.workstation)
        #expect(cpuFired.value == 97.4 && cpuFired.isFiring)
        #expect(cpuFired.title == "DESKTOP-7QK2M1P: CPU load 97%" && cpuFired.message == "Above 90%.")
        #expect(cpuCleared.value == 33.4 && !cpuCleared.isFiring)
        #expect(cpuCleared.title == "DESKTOP-7QK2M1P: CPU load back to normal" && cpuCleared.message == "Now 33% (limit 90%).")
        #expect(cpuCleared.date > cpuFired.date)
        #expect(a.events[0].value == nil && a.events[0].title == "nas is back online")
        #expect(try HubJSON.decode(AlertsResponse.self, from: try HubJSON.encode(a)) == a)
    }

    @Test func clearingTheLogKeepsWhatIsFiring() throws {
        let a = try ModelFixture.decode(AlertsResponse.self, "alerts-after-clear.json")
        #expect(a.events.isEmpty)
        #expect(a.active.map(\.type) == [.dailyCost, .offline, .power, .disk])
        #expect(a.settings.rules.count == 9)
    }

    @Test func savingAlertSettingsAnswersWithSettingsAndActive() throws {
        let update = try ModelFixture.decode(AlertsUpdate.self, "alerts-put.json")
        #expect(update.settings.rules.count == 9)
        #expect(update.settings.channels.webhook == .init(enabled: true, url: "", keepUrl: true))
        #expect(update.settings.notifyResolved && update.settings.tempUnit == .celsius)
        #expect(update.active.map(\.type) == [.disk])
        // The same body read as the GET shape simply has no log.
        let asResponse = try ModelFixture.decode(AlertsResponse.self, "alerts-put.json")
        #expect(asResponse.settings == update.settings && asResponse.active == update.active)
        #expect(asResponse.events.isEmpty && !asResponse.priceSet)
    }

    @Test func testAlertReportsDeliveryPerChannel() throws {
        // A hub with every channel off (or a fixture hub) answers an empty object.
        let none = try ModelFixture.decode(AlertTestResult.self, "alerts-test.json")
        #expect(none == AlertTestResult())
        let failed = try ModelFixture.decode(AlertTestResult.self, "alerts-test-delivery.json")
        #expect(failed.ntfy == .init(ok: false, error: "Blocked alert destination"))
        #expect(failed.webhook == .init(ok: false, error: "ERR_INVALID_URL"))
        let delivered = try HubJSON.decode(AlertTestResult.self, from: Data(#"{"ntfy":{"ok":true}}"#.utf8))
        #expect(delivered == AlertTestResult(ntfy: .init(ok: true)))
    }

    @Test func ruleKindsMirrorTheHubsTable() {
        // TYPES in alerts.js.
        let expected: [(AlertRule.Kind, String, String, ClosedRange<Double>?)] = [
            (.offline, "offline", "Offline", nil),
            (.cpuTemp, "cpuTemp", "CPU temperature", 20...150),
            (.gpuTemp, "gpuTemp", "GPU temperature", 20...150),
            (.cpu, "cpu", "CPU load", 1...100),
            (.gpu, "gpu", "GPU load", 1...100),
            (.mem, "mem", "Memory use", 1...100),
            (.disk, "disk", "Disk space used", 1...100),
            (.power, "power", "Power draw", 1...100_000),
            (.dailyCost, "dailyCost", "Electricity cost today", 0.01...10_000_000),
        ]
        #expect(AlertRule.Kind.allCases == expected.map(\.0))
        for (kind, raw, label, range) in expected {
            #expect(kind.rawValue == raw)
            #expect(AlertRule.Kind(rawValue: raw) == kind)
            #expect(kind.label == label)
            #expect(kind.thresholdRange == range)
            #expect(kind.minutesRange == (kind == .offline ? 1...1440 : 0...1440))
        }
        #expect(AlertRule.Kind(rawValue: "humidity") == .other("humidity"))
        #expect(AlertRule.Kind.other("humidity").thresholdRange == nil)
    }

    @Test func newRuleIdsHaveTheFormTheHubKeeps() {
        let ids = (0..<50).map { _ in AlertRule.newID() }
        #expect(ids.allSatisfy { $0.count == 12 && $0.allSatisfy { "0123456789abcdef".contains($0) } })
        #expect(Set(ids).count == ids.count)
        #expect(AlertRule(type: .cpu, threshold: 90).id != AlertRule(type: .cpu, threshold: 90).id)
    }
}

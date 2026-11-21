import Foundation
import Testing
@testable import DMCore

/// The live stream: every kind of frame a real hub sent during the capture.
@Suite struct WireEventTests {
    let events: [HubEvent]

    init() throws {
        events = try ModelFixture.events()
    }

    @Test func everyEventTypeTheHubEmitsIsCovered() {
        // Every broadcast({ type: … }) in server.js and alerts.js.
        #expect(Set(events.map(\.type)) == ["snapshot", "report", "device", "removed", "update", "energySettings", "order", "status", "alert", "alerts", "actionResult"])
        #expect(events.count == 33)
        for event in events {
            if case .unknown(let type) = event { Issue.record("Unrecognised event \(type)") }
        }
    }

    @Test func snapshotComesFirstAndCarriesSamples() throws {
        guard case .snapshot(let devices) = try #require(events.first) else {
            Issue.record("The first frame is not a snapshot")
            return
        }
        #expect(devices.map(\.id) == [ModelFixture.workstation, ModelFixture.dgx, ModelFixture.macbook, ModelFixture.nas, ModelFixture.lab, ModelFixture.htpc, ModelFixture.removed])
        #expect(devices.map(\.history.count) == [8, 8, 8, 8, 8, 1, 1])
        #expect(devices.allSatisfy { $0.online && $0.latest != nil && !$0.renamed })
        #expect(devices.map(\.order) == [0, 1, 2, 3, 4, 5, 6])
        // A platform the hub does not know is "unknown"; the rest of that report is nulls.
        let stray = try ModelFixture.device(ModelFixture.removed, in: devices)
        #expect(stray.platform == "unknown" && stray.os == nil)
        #expect(stray.latest?.cpu == Report.CPU(usage: 1))
        #expect(stray.latest?.memory == Report.Memory())
        #expect(events.dropFirst().allSatisfy { $0.type != "snapshot" })
    }

    @Test func reportCarriesTheDeviceWithoutHistoryAndOneSample() throws {
        var seen: [String] = []
        for case .report(let id, let device, let sample) in events {
            seen.append(id)
            #expect(device.id == id)
            #expect(device.online)
            #expect(device.history.isEmpty)
            #expect(device.latest?.receivedAt == sample.t)
            #expect(device.lastSeen == sample.t)
            #expect(sample.cpu == device.latest?.cpu.usage)
            #expect(sample.power == device.latest?.powerEst?.watts)
            #expect(sample.n == nil && sample.cpuMax == nil)
        }
        #expect(seen == [ModelFixture.workstation, ModelFixture.dgx, ModelFixture.macbook, ModelFixture.lab, ModelFixture.nas])

        let reports = events.compactMap { event -> (Device, HistoryPoint)? in
            if case .report(_, let device, let sample) = event { return (device, sample) }
            return nil
        }
        // Memory is a percentage worked out by the hub; the GPU columns follow the biggest card.
        let (workstation, sample) = try #require(reports.first)
        let memory = try #require(workstation.latest?.memory)
        #expect(sample.mem == (memory.used ?? 0) / (memory.total ?? 1) * 100)
        #expect(sample.gpu == workstation.latest?.gpus.first?.usage)
        #expect(sample.gpuTemp == workstation.latest?.gpus.first?.temp)
        #expect(sample.gpuPower == workstation.latest?.gpus.first?.power)
        #expect(sample.rx == workstation.latest?.net?.rx && sample.dw == workstation.latest?.diskIO?.write)
        let nasSample = try #require(reports.last).1
        #expect(nasSample.gpu == nil && nasSample.rx == nil && nasSample.dr == nil && nasSample.cpuTemp == nil)
    }

    @Test func renameReorderRemove() throws {
        let renamed = try #require(events.compactMap { event -> Device? in
            if case .device(let device) = event { return device }
            return nil
        }.first)
        #expect(renamed.id == ModelFixture.lab && renamed.name == "Lab PC" && renamed.renamed)
        #expect(!renamed.history.isEmpty)   // unlike a report, it carries the samples

        let order = try #require(events.compactMap { event -> [String: Int]? in
            if case .order(let order) = event { return order }
            return nil
        }.first)
        #expect(order == [
            ModelFixture.dgx: 0, ModelFixture.workstation: 1, ModelFixture.macbook: 2, ModelFixture.lab: 3,
            ModelFixture.nas: 4, ModelFixture.htpc: 5, ModelFixture.removed: 6,
        ])

        #expect(events.contains(.removed(ModelFixture.removed)))
    }

    @Test func statusIsAMapOfWhoIsOnline() throws {
        let statuses = events.compactMap { event -> [String: Bool]? in
            if case .status(let online) = event { return online }
            return nil
        }
        #expect(statuses.count == 7)
        #expect(statuses[0].count == 7 && statuses[0].values.allSatisfy { $0 })
        // After the removal the device is gone from the map; later the HTPC drops offline.
        #expect(statuses[1][ModelFixture.removed] == nil && statuses[1].count == 6)
        #expect(statuses[2][ModelFixture.htpc] == false && statuses[2][ModelFixture.nas] == true)
        #expect(statuses[3][ModelFixture.nas] == false)
        #expect(statuses[5].values.allSatisfy { !$0 })
        #expect(statuses[6][ModelFixture.workstation] == true && statuses[6][ModelFixture.htpc] == false)
    }

    @Test func energySettingsAndUpdate() {
        let settings = events.compactMap { event -> EnergySettings?? in
            if case .energySettings(let settings) = event { return .some(settings) }
            return nil
        }
        #expect(settings == [
            EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"),
            EnergySettings(region: "DE", rate: 0.39, currency: "EUR"),
            EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)]),
        ])
        #expect(events.contains(.update(platform: "windows", version: "1.2.33")))
    }

    @Test func actionResult() throws {
        #expect(events.contains(.actionResult(id: ModelFixture.lab, name: "Lab PC", result: Report.ActionResult(id: "0123456789ab", ok: true, message: "Restarting in 5 seconds."))))
        // server.js, the wake branch of POST /api/devices/<id>/action: the hub's own result has no command id.
        let wake = try HubEvent.decode(#"{"type":"actionResult","id":"old-htpc","name":"htpc","result":{"ok":true,"message":"Wake-up signal sent."}}"#)
        #expect(wake == .actionResult(id: "old-htpc", name: "htpc", result: Report.ActionResult(ok: true, message: "Wake-up signal sent.")))
        let refused = try HubEvent.decode(#"{"type":"actionResult","id":"x","name":"X","result":{"id":"0123456789ab","ok":false,"message":null}}"#)
        #expect(refused == .actionResult(id: "x", name: "X", result: Report.ActionResult(id: "0123456789ab", ok: false)))
    }

    @Test func alertsSettingsSaved() throws {
        let saved = events.compactMap { event -> (AlertSettings, [ActiveAlert])? in
            if case .alerts(let settings, let active) = event { return (settings, active) }
            return nil
        }
        #expect(saved.count == 2)
        // The event carries what the PUT answered.
        let answered = try ModelFixture.decode(AlertsUpdate.self, "alerts-put.json")
        #expect(saved[0].0 == answered.settings && saved[0].1 == answered.active)
        #expect(saved[0].0.notifyResolved && saved[0].0.tempUnit == .celsius)
        #expect(!saved[1].0.notifyResolved && saved[1].0.tempUnit == .fahrenheit)
        #expect(saved[1].0.channels.webhook == .init(enabled: true, url: "", keepUrl: true))
        #expect(saved[1].1.map(\.type) == [.power, .disk])
    }

    @Test func alertsFireResolveAndTest() throws {
        let alerts = events.compactMap { event -> (AlertEvent, Bool, [ActiveAlert])? in
            if case .alert(let alert, let notify, let active) = event { return (alert, notify, active) }
            return nil
        }
        #expect(alerts.map { $0.0.test ? "test" : "\($0.0.type?.rawValue ?? "?")/\($0.0.state.rawValue)" } == [
            "cpu/firing", "power/firing", "test", "cpu/resolved", "offline/firing", "offline/firing",
            "offline/resolved", "offline/firing", "dailyCost/firing", "offline/resolved",
        ])
        // Resolved alerts are announced until "notify when resolved" is switched off.
        #expect(alerts.map(\.1) == [true, true, true, true, true, true, false, true, true, false])
        #expect(alerts.map(\.2.count) == [2, 3, 3, 2, 3, 4, 3, 4, 5, 4])

        let fired = alerts[0].0
        #expect(fired.ruleId == "c0ffee123456" && fired.device == ModelFixture.workstation && fired.deviceName == "DESKTOP-7QK2M1P")
        #expect(fired.value == 97.4 && fired.title == "DESKTOP-7QK2M1P: CPU load 97%")
        #expect(alerts[0].2.contains { $0.ruleId == fired.ruleId && $0.device == fired.device && $0.since == fired.t })

        // A test alert belongs to no rule or device.
        let test = alerts[2].0
        #expect(test.test && test.isFiring)
        #expect(test.ruleId == nil && test.type == nil && test.device == nil && test.deviceName == nil && test.value == nil)
        #expect(test.title == "Device Monitor test alert" && test.message == "Alerts from your hub will arrive like this.")

        let offline = alerts[4].0
        #expect(offline.type == .offline && offline.device == ModelFixture.htpc && offline.value == nil)
        let back = alerts[6].0
        #expect(back.device == ModelFixture.nas && back.state == .resolved && back.title == "nas is back online")
        #expect(!alerts[6].2.contains { $0.device == ModelFixture.nas })

        let cost = alerts[8].0
        #expect(cost.type == .dailyCost && cost.device == "*" && cost.deviceName == "All devices")
        #expect((cost.value ?? 0) > 0.01)
        #expect(alerts[8].2.contains { $0.type == .dailyCost && $0.device == "*" && $0.since == cost.t })
    }

    @Test func unknownTypesAreKeptApartNotFailed() throws {
        #expect(try HubEvent.decode(#"{"type":"processes","id":"x","list":[1,2,3]}"#) == .unknown("processes"))
        #expect(try HubEvent.decode(Data(#"{"type":"","extra":{}}"#.utf8)) == .unknown(""))
        #expect(HubEvent.unknown("processes").type == "processes")
    }

    @Test func malformedFramesThrowInsteadOfCrashing() {
        for bad in [
            "", "not json", "[]", "42", "null", "{}", #"{"type":7}"#, #"{"type":null}"#,
            #"{"type":"report"}"#, #"{"type":"report","id":"x","device":{"name":"no id"},"sample":{"t":1}}"#,
            #"{"type":"report","id":"x","device":{"id":"x"},"sample":{}}"#,
            #"{"type":"device","device":"x"}"#, #"{"type":"removed"}"#, #"{"type":"update","platform":"mac"}"#,
            #"{"type":"alert","event":{"title":"no id"}}"#, #"{"type":"alerts","active":[]}"#,
            #"{"type":"actionResult","id":"x"}"#,
        ] {
            #expect(throws: (any Error).self, "\(bad)") { try HubEvent.decode(bad) }
        }
    }

    @Test func sloppyButUsableFramesDecode() throws {
        // Missing collections are empty, bad entries are dropped, nothing else is lost.
        #expect(try HubEvent.decode(#"{"type":"snapshot"}"#) == .snapshot([]))
        #expect(try HubEvent.decode(#"{"type":"snapshot","devices":[{"id":"a"},{"name":"no id"},null,{"id":"b","online":true}]}"#)
            == .snapshot([Device(id: "a"), Device(id: "b", online: true)]))
        #expect(try HubEvent.decode(#"{"type":"status"}"#) == .status([:]))
        #expect(try HubEvent.decode(#"{"type":"status","online":{"a":true,"b":"yes","c":false,"d":null}}"#) == .status(["a": true, "c": false]))
        #expect(try HubEvent.decode(#"{"type":"order","order":{"a":0,"b":2.0,"c":null,"d":"1"}}"#) == .order(["a": 0, "b": 2]))
        #expect(try HubEvent.decode(#"{"type":"energySettings","settings":null}"#) == .energySettings(nil))
        #expect(try HubEvent.decode(#"{"type":"energySettings"}"#) == .energySettings(nil))
        #expect(try HubEvent.decode(#"{"type":"energySettings","settings":{"region":"US"}}"#) == .energySettings(nil))
        #expect(try HubEvent.decode(#"{"type":"alert","event":{"id":"abc","t":5}}"#)
            == .alert(event: AlertEvent(id: "abc", t: 5), notify: false, active: []))
        #expect(try HubEvent.decode(#"{"type":"update","platform":"mac","version":"1.2.33","notes":"new field"}"#) == .update(platform: "mac", version: "1.2.33"))
    }

    @Test func eventsSurviveARoundTrip() throws {
        for event in events {
            let data = try HubJSON.encode(event)
            #expect(try HubEvent.decode(data) == event, "\(event.type)")
        }
        #expect(try HubEvent.decode(try HubJSON.encode(HubEvent.energySettings(nil))) == .energySettings(nil))
        #expect(try HubEvent.decode(try HubJSON.encode(HubEvent.unknown("later"))) == .unknown("later"))
    }
}

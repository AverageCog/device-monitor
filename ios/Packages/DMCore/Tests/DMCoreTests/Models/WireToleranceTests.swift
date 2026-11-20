import Foundation
import Testing
@testable import DMCore

/// A newer or sloppier hub must never break the app: unknown keys are ignored, missing things are
/// absent, and one bad element costs only itself.
@Suite struct WireToleranceTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try HubJSON.decode(type, from: Data(json.utf8))
    }

    @Test func aDeviceNeedsOnlyAnId() throws {
        let d = try decode(Device.self, #"{"id":"box"}"#)
        #expect(d == Device(id: "box"))
        #expect(d.name == nil && d.order == nil && d.hw == nil && d.latest == nil)
        #expect(d.macs.isEmpty && d.history.isEmpty && !d.online && !d.renamed)
        #expect(d.displayName == "box")
        #expect(throws: DecodingError.self) { try decode(Device.self, #"{"name":"no id"}"#) }
        #expect(throws: DecodingError.self) { try decode(Device.self, #"{"id":17}"#) }
    }

    @Test func unknownKeysAreIgnoredEverywhere() throws {
        let d = try decode(Device.self, #"""
        {"id":"box","name":"Box","tags":["new"],"location":{"room":"den"},"online":true,
         "latest":{"id":"box","battery":{"percent":80},"cpu":{"usage":5,"efficiencyCores":4},"gpus":[{"name":"G","hotspot":90}],
                   "powerEst":{"watts":50,"cpu":10,"gpu":0,"rest":25,"losses":5,"cpuMeasured":false,"gpuMeasured":false,"gpuEstimated":false,"battery":true}},
         "history":[{"t":1,"cpu":5,"fan":1200}]}
        """#)
        #expect(d.name == "Box" && d.online)
        #expect(d.latest?.cpu.usage == 5)
        #expect(d.latest?.gpus == [Report.GPU(name: "G")])
        #expect(d.latest?.powerEst == PowerEstimate(watts: 50, cpu: 10, gpu: 0, rest: 25, losses: 5))
        #expect(d.history == [HistoryPoint(t: 1, cpu: 5)])
    }

    @Test func wrongTypesReadAsAbsent() throws {
        let d = try decode(Device.self, #"""
        {"id":"box","name":5,"hostname":["h"],"order":"1","online":"yes","renamed":1,"lastSeen":"soon","firstSeen":null,"macs":"aa:bb",
         "hw":"desktop","history":{"t":1},
         "latest":{"uptime":"3 days","features":"procs","actions":[1,"sleep",null],"power":7,"net":[],"diskIO":"fast","ai":"none",
                   "cpu":{"name":{},"usage":"high","cores":[1,"x",null,2.5,true],"threads":8.0,"temp":false},
                   "memory":[],"gpus":[{"name":"ok"},"junk",7,null,{"usage":3,"memTotal":"lots"}],
                   "disks":{"name":"C:"},"temps":[{"name":"t","value":"hot"}],"fans":null,
                   "actionResult":"done","powerEst":{"cpu":10}}}
        """#)
        #expect(d.name == nil && d.hostname == nil && d.order == nil && d.lastSeen == nil && d.firstSeen == nil && d.hw == nil)
        #expect(!d.online && !d.renamed && d.macs.isEmpty && d.history.isEmpty)
        let report = try #require(d.latest)
        #expect(report.uptime == nil && report.features.isEmpty && report.actions == ["sleep"])
        #expect(report.power == nil && report.net == nil && report.diskIO == nil && report.ai == nil && report.actionResult == nil)
        #expect(report.cpu.name == nil && report.cpu.usage == nil && report.cpu.temp == nil)
        // Cores keep their positions: what cannot be read is nil, not skipped.
        #expect(report.cpu.cores == [1, nil, nil, 2.5, nil])
        #expect(report.cpu.threads == 8)
        #expect(report.memory == Report.Memory())
        // Whole elements that are not objects are dropped.
        #expect(report.gpus == [Report.GPU(name: "ok"), Report.GPU(usage: 3)])
        #expect(report.disks.isEmpty && report.fans.isEmpty)
        #expect(report.temps == [Report.Temp(name: "t", value: nil)])
        // An estimate without a total is no estimate.
        #expect(report.powerEst == nil)
    }

    @Test func numbersMayBeWholeOrFractional() throws {
        let info = try decode(HubInfo.self, #"{"app":"device-monitor","port":7777.0,"canShare":true}"#)
        #expect(info.port == 7777)
        let d = try decode(Device.self, #"{"id":"a","order":3.0,"lastSeen":1795213953000,"firstSeen":1.795213e12,"hw":{"threads":15.6}}"#)
        #expect(d.order == 3 && d.lastSeen == 1_795_213_953_000 && d.firstSeen == 1_795_213_000_000)
        #expect(d.hw?.threads == 16)
        let point = try decode(HistoryPoint.self, #"{"t":1795213953000.0,"cpu":50,"gpu":50.5,"n":30.0}"#)
        #expect(point == HistoryPoint(t: 1_795_213_953_000, cpu: 50, gpu: 50.5, n: 30))
        let settings = try decode(EnergySettings.self, #"{"region":"JP","rate":31,"currency":"JPY","tou":[{"from":0,"to":6,"rate":20},{"from":6.25,"to":24.0,"rate":35.5}]}"#)
        #expect(settings == EnergySettings(region: "JP", rate: 31, currency: "JPY", tou: [TouPeriod(from: 0, to: 6, rate: 20), TouPeriod(from: 6.25, to: 24, rate: 35.5)]))
        // Numbers too large for an integer are refused rather than trapped on.
        #expect(try decode(Device.self, #"{"id":"a","order":1e300}"#).order == nil)
        #expect(try decode(HubInfo.self, #"{"port":-0.4}"#).port == 0)
    }

    @Test func topLevelListsDropWhatDoesNotDecode() throws {
        let data = Data(#"[{"id":"a"},{"name":"no id"},42,null,"x",[],{"id":"b","online":true}]"#.utf8)
        #expect(try HubJSON.decodeList(Device.self, from: data) == [Device(id: "a"), Device(id: "b", online: true)])
        #expect(try HubJSON.decodeList(Device.self, from: Data("[]".utf8)).isEmpty)
        // Not a list at all is an error: an error body must not look like "no devices".
        #expect(throws: DecodingError.self) { try HubJSON.decodeList(Device.self, from: Data(#"{"error":"Open a fresh dashboard invitation."}"#.utf8)) }
        // The strict decoder, by contrast, gives up on the first bad element.
        #expect(throws: DecodingError.self) { try HubJSON.decode([Device].self, from: data) }
    }

    @Test func historyDropsPointsWithoutATimeAndDefaultsTheResolution() throws {
        let h = try decode(HistoryResponse.self, #"{"from":10,"to":20,"points":[{"t":11,"cpu":1},{"cpu":2},{"t":"12"},7,{"t":13,"cpu":null,"cpuMax":null,"power":"x"}]}"#)
        #expect(h.from == 10 && h.to == 20)
        #expect(h.resolution == 60_000)   // `r.resolution || 60e3` in loadHistory
        #expect(h.points == [HistoryPoint(t: 11, cpu: 1), HistoryPoint(t: 13)])
        #expect(try decode(HistoryResponse.self, #"{"resolution":0}"#) == HistoryResponse(from: 0, to: 0, resolution: 60_000, points: []))
        #expect(try decode(HistoryResponse.self, #"{"from":1,"to":2,"resolution":2000,"points":null}"#) == HistoryResponse(from: 1, to: 2, resolution: 2000))
    }

    @Test func energyBucketsStayAligned() throws {
        let e = try decode(EnergyResponse.self, #"""
        {"bounds":[0,3600000,7200000,10800000],"settings":{"region":"US","rate":"cheap"},
         "devices":[{"id":"a","wh":"12","buckets":[1.5,null,"x",2],"cost":null,"costBuckets":null,"minutes":61.0,"stats":{"power":{"avg":10,"peak":null},"cpu":{"peak":3},"gpu":"n/a","humidity":{"avg":40}},"bytes":{"rx":5}},
                    {"wh":1},
                    {"id":"b","costBuckets":[0.1,null,0.3]}]}
        """#)
        #expect(e.bounds == [0, 3_600_000, 7_200_000, 10_800_000])
        #expect(e.settings == nil)   // a price the app cannot read is no price
        #expect(e.devices.map(\.id) == ["a", "b"])
        let a = e.devices[0]
        #expect(a.wh == 0)
        // A bucket that cannot be read counts as zero; the ones after it keep their hour.
        #expect(a.buckets == [1.5, 0, 0, 2])
        #expect(a.cost == nil && a.costBuckets == nil)
        #expect(a.minutes == 61 && a.estimatedMinutes == 0)
        #expect(a.stats == UsageSummary.Stats(power: .init(avg: 10, peak: nil)))
        #expect(a.bytes == UsageSummary.Bytes(rx: 5))
        #expect(a.firstData == nil && a.firstDataDate == nil)
        #expect(e.devices[1] == UsageSummary(id: "b", costBuckets: [0.1, 0, 0.3]))
    }

    @Test func alertSettingsFillInDefaultsAndKeepUnknownRuleKinds() throws {
        let s = try decode(AlertSettings.self, #"""
        {"rules":[{"id":"aaaaaaaaaaaa","type":"humidity","device":"*","threshold":60,"minutes":3.0,"enabled":false,"window":"1h"},
                  {"type":"cpu","threshold":80},
                  {"id":"bbbbbbbbbbbb","device":"*"},
                  "junk"],
         "channels":{"ntfy":{"topic":"t"},"pager":{"enabled":true}},
         "tempUnit":"K","quietHours":[22,7]}
        """#)
        #expect(s.rules.count == 2)
        #expect(s.rules[0] == AlertRule(id: "aaaaaaaaaaaa", type: .other("humidity"), device: "*", threshold: 60, minutes: 3, enabled: false))
        #expect(s.rules[0].type.rawValue == "humidity" && s.rules[0].type.label == "humidity" && s.rules[0].isAcceptable)
        // A rule without an id gets one the hub will keep; without a device it covers all.
        #expect(s.rules[1].type == .cpu && s.rules[1].threshold == 80 && s.rules[1].minutes == 0 && s.rules[1].enabled && s.rules[1].appliesToAllDevices)
        #expect(s.rules[1].id.count == 12 && s.rules[1].id.allSatisfy(\.isHexDigit))
        #expect(s.channels == AlertChannels(desktop: true, ntfy: .init(enabled: false, server: "https://ntfy.sh", topic: "t", email: ""), webhook: .init()))
        #expect(s.notifyResolved)
        #expect(s.tempUnit == .celsius)

        // The unknown kind goes back to the hub exactly as it came.
        let rule = try #require(JSONSerialization.jsonObject(with: try HubJSON.encode(s.rules[0])) as? NSDictionary)
        #expect(rule == ["id": "aaaaaaaaaaaa", "type": "humidity", "device": "*", "threshold": 60, "minutes": 3, "enabled": false] as NSDictionary)

        #expect(try decode(AlertSettings.self, "{}") == AlertSettings())
        #expect(try decode(AlertsResponse.self, #"{"settings":{}}"#) == AlertsResponse())
        #expect(throws: DecodingError.self) { try decode(AlertsResponse.self, #"{"active":[]}"#) }
    }

    @Test func alertLogDropsEntriesWithoutIdOrTime() throws {
        let a = try decode(AlertsResponse.self, #"""
        {"settings":{"rules":[]},
         "active":[{"ruleId":"r","type":"cpu","device":"d"},{"type":"cpu","device":"d"},{"ruleId":"r","type":"snow","device":"*","since":5,"value":"deep"}],
         "events":[{"id":"e1","t":1,"state":"acknowledged","type":"snow"},{"t":2},{"id":"e3"},{"id":"e4","t":4,"state":"resolved","value":"x","test":"no"}],
         "priceSet":"yes"}
        """#)
        // An alert built from its three required fields is the one that decodes from them.
        #expect(a.active == [ActiveAlert(ruleId: "r", type: .cpu, device: "d"), ActiveAlert(ruleId: "r", type: .other("snow"), device: "*", since: 5)])
        #expect(a.active[0].since == 0 && a.active[0].sinceDate == Date(timeIntervalSince1970: 0))
        #expect(a.active.map(\.id) == ["r|d", "r|*"])
        #expect(a.events == [
            AlertEvent(id: "e1", t: 1, type: .other("snow"), state: .other("acknowledged")),
            AlertEvent(id: "e4", t: 4, state: .resolved),
        ])
        #expect(!a.events[0].isFiring && a.events[0].state.rawValue == "acknowledged")
        #expect(!a.priceSet)
    }

    @Test func temperatureUnitIsCelsiusUnlessF() throws {
        #expect(try decode([TemperatureUnit].self, #"["C","F","K","f",""]"#) == [.celsius, .fahrenheit, .celsius, .celsius, .celsius])
        #expect(try decode(AlertSettings.self, #"{"tempUnit":7}"#).tempUnit == .celsius)
        #expect(String(decoding: try HubJSON.encode([TemperatureUnit.celsius, .fahrenheit]), as: UTF8.self) == #"["C","F"]"#)
        #expect(TemperatureUnit.celsius.symbol == "\u{B0}C" && TemperatureUnit.fahrenheit.symbol == "\u{B0}F")
        #expect(TemperatureUnit.allCases.map(\.rawValue) == ["C", "F"])
    }

    @Test func smallAnswersTolerateMissingFields() throws {
        #expect(try decode(RemoteStatus.self, "{}") == RemoteStatus())
        #expect(try decode(HubInfo.self, "{}") == HubInfo(app: nil))
        #expect(try decode(Wire.OK.self, "{}") == Wire.OK(ok: false))
        #expect(try decode(AlertTestResult.self, #"{"ntfy":"sent","webhook":{"error":"HTTP 500"},"sms":{"ok":true}}"#) == AlertTestResult(ntfy: nil, webhook: .init(ok: false, error: "HTTP 500")))
        #expect(try decode(UpdateManifest.self, #"{"version":"2.0.0","size":"big","channel":"beta"}"#) == UpdateManifest(version: "2.0.0"))
        #expect(try decode(InviteResponse.self, #"{"code":"c","origin":"https://hub.test","expires":"soon"}"#) == InviteResponse(code: "c", origin: "https://hub.test"))
        #expect(try decode(MobileClient.self, #"{"id":"m","created":"yesterday"}"#) == MobileClient(id: "m"))
        #expect(try decode(Report.self, "{}") == Report())
        #expect(try decode(Report.self, #"{"ai":[{"app":"Ollama","models":[{"name":"m"},"x",{"size":5}]},5]}"#).ai == [Report.AIApp(app: "Ollama", models: [Report.AIModel(name: "m"), Report.AIModel(size: 5)])])
    }
}

import Foundation
import Testing
@testable import DMCore

/// Nothing the hub sends is lost: every key and value of each captured payload must still be there
/// after it went through the Swift model and back to JSON.
///
/// This is what catches a field the models forgot. It compares one way only: the models may add
/// defaults the hub left out (`"renamed": false`), but never drop or change what the hub sent.
@Suite struct WireCoverageTests {
    /// Where `sent` and `kept` disagree, as paths into the JSON. A null the hub sent may be absent
    /// after the round trip: both mean "no value".
    private func losses(_ sent: Any, _ kept: Any?, at path: String = "$", ignoring: Set<String> = []) -> [String] {
        if ignoring.contains(path.replacingOccurrences(of: #"\[\d+\]"#, with: "[]", options: .regularExpression)) { return [] }
        switch sent {
        case is NSNull:
            return kept == nil || kept is NSNull ? [] : ["\(path): null became \(kept ?? "nil")"]
        case let object as [String: Any]:
            guard let other = kept as? [String: Any] else { return ["\(path): object became \(kept ?? "nothing")"] }
            return object.keys.sorted().flatMap { losses(object[$0] as Any, other[$0], at: "\(path).\($0)", ignoring: ignoring) }
        case let array as [Any]:
            guard let other = kept as? [Any] else { return ["\(path): array became \(kept ?? "nothing")"] }
            guard other.count == array.count else { return ["\(path): \(array.count) elements became \(other.count)"] }
            return zip(array, other).enumerated().flatMap { losses($1.0, $1.1, at: "\(path)[\($0)]", ignoring: ignoring) }
        default:
            guard let value = sent as? NSObject, let other = kept as? NSObject, value == other else {
                return ["\(path): \(sent) became \(kept ?? "nothing")"]
            }
            return []
        }
    }

    private func roundTrip<T: Codable>(_ type: T.Type, _ sent: Any) throws -> Any {
        let value = try HubJSON.decode(type, from: try ModelFixture.reencode(sent))
        return try JSONSerialization.jsonObject(with: try HubJSON.encode(value), options: [.fragmentsAllowed])
    }

    private func object(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: try ModelFixture.data(name), options: [.fragmentsAllowed])
    }

    private func expectNoLoss<T: Codable>(
        _ type: T.Type, _ sent: Any, _ label: String, ignoring: Set<String> = [], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let lost = losses(sent, try roundTrip(type, sent), ignoring: ignoring)
        #expect(lost.isEmpty, "\(label) loses \(lost.count):\n\(lost.prefix(15).joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    // The one place the app's JSON differs from the hub's by design. The hub answers the webhook as
    // `{ enabled, url: "", keepUrl }`; the app sends `{ enabled, keepUrl: true }` to keep the stored
    // URL and `{ enabled, url }` otherwise (WireRequestTests covers that encoding).
    private let webhook: Set<String> = ["$.settings.channels.webhook.url", "$.settings.channels.webhook.keepUrl"]

    @Test func devicesAndReports() throws {
        try expectNoLoss([Device].self, try object("devices.json"), "devices.json")
        try expectNoLoss([Device].self, try object("devices-after-restart.json"), "devices-after-restart.json")
        try expectNoLoss(Device.self, try object("device-patch.json"), "device-patch.json")
    }

    @Test func history() throws {
        for name in ["history-raw.json", "history-10m.json", "history-24h.json", "history-6h-no-gpu.json"] {
            try expectNoLoss(HistoryResponse.self, try object(name), name)
        }
    }

    @Test func energy() throws {
        for name in ["energy-7d-no-price.json", "energy-7d-flat.json", "energy-24h-tou.json"] {
            try expectNoLoss(EnergyResponse.self, try object(name), name)
        }
        try expectNoLoss([String: EnergySettings?].self, try object("energy-settings.json"), "energy-settings.json")
    }

    @Test func alerts() throws {
        for name in ["alerts-default.json", "alerts.json", "alerts-after-clear.json"] {
            try expectNoLoss(AlertsResponse.self, try object(name), name, ignoring: webhook)
        }
        try expectNoLoss(AlertsUpdate.self, try object("alerts-put.json"), "alerts-put.json", ignoring: webhook)
        try expectNoLoss(AlertTestResult.self, try object("alerts-test.json"), "alerts-test.json")
        // `note` is the capture script's own remark, not part of the hub's answer.
        try expectNoLoss(AlertTestResult.self, try object("alerts-test-delivery.json"), "alerts-test-delivery.json", ignoring: ["$.note"])
    }

    @Test func hubAnswers() throws {
        try expectNoLoss([String: HubInfo].self, try object("info.json"), "info.json")
        try expectNoLoss(RemoteStatus.self, try object("remote.json"), "remote.json")
        try expectNoLoss(InviteResponse.self, try object("invite-browser.json"), "invite-browser.json")
        let update = try #require(try object("update.json") as? [String: Any])
        try expectNoLoss(UpdateManifest.self, update["published"] as Any, "update.json published")
        try expectNoLoss(Wire.Failure.self, update["notPublished"] as Any, "update.json notPublished")
    }

    @Test func streamEvents() throws {
        for (index, frame) in try ModelFixture.frames().enumerated() {
            let sent = try JSONSerialization.jsonObject(with: Data(frame.utf8))
            let type = (sent as? [String: Any])?["type"] as? String ?? "?"
            try expectNoLoss(HubEvent.self, sent, "frame \(index) (\(type))", ignoring: webhook)
        }
    }

    @Test func theCheckItselfNoticesLosses() {
        let sent: [String: Any] = ["id": "a", "n": 1.5, "list": [["x": 1], ["x": 2]], "none": NSNull(), "deep": ["flag": true]]
        #expect(losses(sent, sent).isEmpty)
        #expect(losses(sent, ["id": "a", "n": 1.5, "list": [["x": 1], ["x": 2]], "deep": ["flag": true], "extra": 5]).isEmpty)
        #expect(losses(sent, ["id": "a", "n": 1.5, "list": [["x": 1], ["x": 2]]]) == ["$.deep: object became nothing"])
        #expect(losses(sent, ["id": "b", "n": 1.5, "list": [["x": 1], ["x": 3]], "deep": ["flag": true]]).count == 2)
        #expect(losses(sent, ["id": "a", "n": 1.5, "list": [["x": 1]], "deep": ["flag": true]]) == ["$.list: 2 elements became 1"])
        #expect(losses(sent, ["id": "a", "n": 1.5, "list": [["x": 1], ["x": 9]], "deep": ["flag": true]], ignoring: ["$.list[].x"]).isEmpty)
    }
}

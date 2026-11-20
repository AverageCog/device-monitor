import Foundation
@testable import DMCore

/// Loads the payloads captured from a real hub (Fixtures/models) and names the devices in them.
enum ModelFixture {
    // The fleet the capture script reported for.
    static let workstation = "a3f1c9d2-7b64-4e0a-9c1d-2f5e8b7a6c40"   // Windows desktop, one GPU
    static let dgx = "4c2f9a7e1b3d4f6a8c0e2d4b6f8a1c3e"                // Linux, five GPUs, AI models
    static let macbook = "5B8E2A11-93C4-5D7F-A012-6E4C9D3B7F21"        // macOS laptop
    static let nas = "nas-01"                                          // reports almost nothing
    static let lab = "f0e1d2c3-b4a5-4697-8879-6a5b4c3d2e1f"            // renamed to "Lab PC"
    static let htpc = "old-htpc"                                       // reported once, then went offline
    static let removed = "retired-box"

    static func data(_ name: String) throws -> Data {
        try Fixture.data("models/" + name)
    }

    static func decode<T: Decodable>(_ type: T.Type = T.self, _ name: String) throws -> T {
        try HubJSON.decode(type, from: try data(name))
    }

    /// The payloads of the captured stream frames.
    static func frames() throws -> [String] {
        try decode([String].self, "sse-frames.json")
    }

    static func events() throws -> [HubEvent] {
        try frames().map { try HubEvent.decode($0) }
    }

    /// A request the capture script sent, with the status the hub answered.
    struct Recorded {
        let status: Int
        let body: Any
        let response: Any
    }

    static func request(_ name: String) throws -> Recorded {
        let all = try JSONSerialization.jsonObject(with: try data("requests.json")) as? [[String: Any]] ?? []
        guard let entry = all.first(where: { $0["name"] as? String == name }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No recorded request named \(name)"])
        }
        return Recorded(status: entry["status"] as? Int ?? 0, body: entry["body"] ?? NSNull(), response: entry["response"] ?? NSNull())
    }

    /// The JSON a value encodes to, as Foundation objects, so two documents compare by content
    /// rather than by key order or number spelling.
    static func json<T: Encodable>(_ value: T) throws -> NSObject {
        try JSONSerialization.jsonObject(with: try HubJSON.encode(value), options: [.fragmentsAllowed]) as? NSObject ?? NSNull()
    }

    static func reencode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}

extension ModelFixture {
    static func device(_ id: String, in devices: [Device]) throws -> Device {
        guard let found = devices.first(where: { $0.id == id }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No device \(id) in the fixture"])
        }
        return found
    }
}

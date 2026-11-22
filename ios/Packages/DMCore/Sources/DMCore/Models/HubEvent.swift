import Foundation

/// One message of the hub's live stream (`GET /api/stream`): the JSON after `data: ` in a frame.
///
/// The cases follow every `broadcast(…)` in server.js and alerts.js, and `connect()` in
/// public/index.html shows what a client does with each.
public enum HubEvent: Sendable, Equatable {
    /// First message of every connection: all devices, each with its last ten minutes of samples.
    case snapshot([Device])
    /// A device reported. `device` has no `history`; `sample` is the point to append to it.
    case report(id: String, device: Device, sample: HistoryPoint)
    /// A device was renamed.
    case device(Device)
    /// A device was removed from the hub.
    case removed(String)
    /// A newer desktop app was published for "windows" or "mac".
    case update(platform: String, version: String)
    /// The shared electricity price changed.
    case energySettings(EnergySettings?)
    /// Devices were reordered: position by device id.
    case order([String: Int])
    /// Sent every three seconds: who is online, by device id. Doubles as the heartbeat.
    case status([String: Bool])
    /// An alert fired or cleared, or a test alert was sent. `notify` is the hub's verdict on
    /// whether apps should show a notification; `active` is everything firing now.
    case alert(event: AlertEvent, notify: Bool, active: [ActiveAlert])
    /// Alert settings were saved.
    case alerts(settings: AlertSettings, active: [ActiveAlert])
    /// A power action finished on a device, or the hub sent a wake-up signal. `name` is the
    /// device's display name.
    case actionResult(id: String, name: String?, result: Report.ActionResult)
    /// A type this app does not know. Ignore it: newer hubs may say more.
    case unknown(String)

    /// Decodes the payload of one stream frame. Throws when the payload is not JSON, has no `type`,
    /// or lacks what its type needs; a caller should drop that frame and carry on.
    public static func decode(_ data: Data) throws -> HubEvent {
        try HubJSON.decoder.decode(HubEvent.self, from: data)
    }

    public static func decode(_ text: String) throws -> HubEvent {
        try decode(Data(text.utf8))
    }

    /// The wire name of the event.
    public var type: String {
        switch self {
        case .snapshot: "snapshot"
        case .report: "report"
        case .device: "device"
        case .removed: "removed"
        case .update: "update"
        case .energySettings: "energySettings"
        case .order: "order"
        case .status: "status"
        case .alert: "alert"
        case .alerts: "alerts"
        case .actionResult: "actionResult"
        case .unknown(let type): type
        }
    }
}

extension HubEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, devices, id, device, sample, platform, version, settings, order, online, event, notify, active, name, result
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        let type: String = try c.require(.type)
        switch type {
        case "snapshot":
            self = .snapshot(c.list(.devices))
        case "report":
            self = .report(
                id: try c.require(.id),
                device: try c.require(.device),
                sample: try c.require(.sample)
            )
        case "device":
            self = .device(try c.require(.device))
        case "removed":
            self = .removed(try c.require(.id))
        case "update":
            self = .update(
                platform: try c.require(.platform),
                version: try c.require(.version)
            )
        case "energySettings":
            self = .energySettings(c.optional(.settings))
        case "order":
            self = .order(c.dictionary(.order, of: WireInt.self).mapValues(\.value))
        case "status":
            self = .status(c.dictionary(.online))
        case "alert":
            self = .alert(
                event: try c.require(.event),
                notify: c.flag(.notify) ?? false,
                active: c.list(.active)
            )
        case "alerts":
            self = .alerts(settings: try c.require(.settings), active: c.list(.active))
        case "actionResult":
            self = .actionResult(
                id: try c.require(.id),
                name: c.text(.name),
                result: try c.require(.result)
            )
        default:
            self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .snapshot(let devices):
            try c.encode(devices, forKey: .devices)
        case .report(let id, let device, let sample):
            try c.encode(id, forKey: .id)
            try c.encode(device, forKey: .device)
            try c.encode(sample, forKey: .sample)
        case .device(let device):
            try c.encode(device, forKey: .device)
        case .removed(let id):
            try c.encode(id, forKey: .id)
        case .update(let platform, let version):
            try c.encode(platform, forKey: .platform)
            try c.encode(version, forKey: .version)
        case .energySettings(let settings):
            try c.encode(settings, forKey: .settings)
        case .order(let order):
            try c.encode(order, forKey: .order)
        case .status(let online):
            try c.encode(online, forKey: .online)
        case .alert(let event, let notify, let active):
            try c.encode(event, forKey: .event)
            try c.encode(notify, forKey: .notify)
            try c.encode(active, forKey: .active)
        case .alerts(let settings, let active):
            try c.encode(settings, forKey: .settings)
            try c.encode(active, forKey: .active)
        case .actionResult(let id, let name, let result):
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encode(result, forKey: .result)
        case .unknown:
            break
        }
    }
}

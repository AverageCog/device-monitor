import Foundation

/// Request bodies the hub accepts, and its small generic answers. Encode with `HubJSON.encoder`.
///
/// `EnergySettings` (`PUT /api/energy/settings`) and `AlertSettings` (`PUT /api/alerts`) are their
/// own request bodies.
public enum Wire {
    /// `PATCH /api/devices/<id>`. The hub strips control characters and keeps 60 characters; an
    /// empty name changes nothing. It answers with the device.
    public struct Rename: Codable, Sendable, Hashable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    /// `PUT /api/order`: every device id in display order, the offline ones included.
    public struct Order: Codable, Sendable, Hashable {
        public var ids: [String]

        public init(ids: [String]) {
            self.ids = ids
        }
    }

    /// `POST /api/invites`. A paired app may only ask for `browser` invitations; `mobile` and the
    /// kinds that enrol a computer are for the hub's own operator.
    public struct Invite: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable {
            case browser, desktop, agent, mobile
        }

        public var kind: Kind
        /// The hub origin the invitation will be redeemed at (`HubInfo.origin`).
        public var origin: String
        /// An existing device to re-enrol (desktop and agent invitations only); left out otherwise.
        public var id: String?

        public init(kind: Kind, origin: String, id: String? = nil) {
            self.kind = kind
            self.origin = origin
            self.id = id
        }
    }

    /// `POST /api/devices/<id>/action`.
    public struct DeviceAction: Codable, Sendable, Hashable {
        /// Wake-on-LAN, sent by the hub itself to the device's last known network cards.
        public static let wake = DeviceAction(action: "wake")

        /// "wake", or a power action the device allows: "sleep", "restart", "shutdown".
        public var action: String

        public init(action: String) {
            self.action = action
        }
    }

    /// `POST /api/mobile/pair` (the invitation code goes in the Authorization header).
    public struct MobilePair: Codable, Sendable, Hashable {
        /// A label for this phone in the hub's list; the hub keeps 60 characters.
        public var name: String?

        public init(name: String? = nil) {
            self.name = name
        }
    }

    /// `{ "ok": true }`, the answer to a reorder, a removal, clearing the alert log or revoking an
    /// enrollment. A queued power action adds the command's `id`.
    public struct OK: Codable, Sendable, Hashable {
        public var ok: Bool
        public var id: String?

        public init(ok: Bool = true, id: String? = nil) {
            self.ok = ok
            self.id = id
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            ok = c.flag(.ok) ?? false
            id = c.text(.id)
        }
    }

    /// `{ "error": "…" }`, the body of every JSON error answer. The text is written for people.
    public struct Failure: Codable, Sendable, Hashable {
        public var error: String

        public init(error: String) {
            self.error = error
        }
    }
}

import Foundation

/// `GET /api/info`: which hub this is and what the caller may do on it.
///
/// Without a valid credential the hub answers only `{ app, locked: true }`.
public struct HubInfo: Codable, Sendable, Hashable {
    /// What every Device Monitor hub answers in `app`.
    public static let appName = "device-monitor"

    public var app: String?
    public var locked: Bool
    public var hostname: String?
    /// The hub's local HTTP port.
    public var port: Int?
    /// May create invitations for desktops and agents (the hub's own operator only).
    public var canEnroll: Bool
    /// May create browser links. True for paired apps, false for a browser session.
    public var canShare: Bool
    /// The hub's public HTTPS origin, when it has one.
    public var origin: String?
    /// The loopback origin, shown only to callers on the hub PC itself.
    public var localOrigin: String?

    public init(
        app: String? = HubInfo.appName, locked: Bool = false, hostname: String? = nil, port: Int? = nil,
        canEnroll: Bool = false, canShare: Bool = false, origin: String? = nil, localOrigin: String? = nil
    ) {
        self.app = app
        self.locked = locked
        self.hostname = hostname
        self.port = port
        self.canEnroll = canEnroll
        self.canShare = canShare
        self.origin = origin
        self.localOrigin = localOrigin
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        app = c.text(.app)
        locked = c.flag(.locked) ?? false
        hostname = c.text(.hostname)
        port = c.integer(.port)
        canEnroll = c.flag(.canEnroll) ?? false
        canShare = c.flag(.canShare) ?? false
        origin = c.text(.origin)
        localOrigin = c.text(.localOrigin)
    }

    public var isDeviceMonitor: Bool { app == HubInfo.appName }
}

/// `GET /api/remote`: the hub's Tailscale state (`readStatus` in tailscale.js) plus what the caller
/// may change. A hub without Tailscale answers little more than `installed: false`.
public struct RemoteStatus: Codable, Sendable, Hashable {
    public var installed: Bool
    public var running: Bool
    /// Tailscale's backend state ("Running", "NeedsLogin", "Stopped", "NotRunning").
    public var state: String?
    public var ip: String?
    public var dnsName: String?
    /// The tailnet HTTPS address that forwards to the hub, once `tailscale serve` is on.
    public var httpsUrl: String?
    /// Every address the hub answers on over Tailscale.
    public var urls: [String]
    public var tailnet: String?
    public var port: Int?
    /// Only the hub PC itself may switch tailnet HTTPS on.
    public var canConfigure: Bool
    /// The hub's `process.platform` ("win32", "darwin", "linux").
    public var platform: String?

    public init(
        installed: Bool = false, running: Bool = false, state: String? = nil, ip: String? = nil,
        dnsName: String? = nil, httpsUrl: String? = nil, urls: [String] = [], tailnet: String? = nil,
        port: Int? = nil, canConfigure: Bool = false, platform: String? = nil
    ) {
        self.installed = installed
        self.running = running
        self.state = state
        self.ip = ip
        self.dnsName = dnsName
        self.httpsUrl = httpsUrl
        self.urls = urls
        self.tailnet = tailnet
        self.port = port
        self.canConfigure = canConfigure
        self.platform = platform
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        installed = c.flag(.installed) ?? false
        running = c.flag(.running) ?? false
        state = c.text(.state)
        ip = c.text(.ip)
        dnsName = c.text(.dnsName)
        httpsUrl = c.text(.httpsUrl)
        urls = c.list(.urls)
        tailnet = c.text(.tailnet)
        port = c.integer(.port)
        canConfigure = c.flag(.canConfigure) ?? false
        platform = c.text(.platform)
    }
}

/// `GET /api/update/<windows|mac>`: the signed manifest of the newest desktop installer
/// (written by build/release.js). The iOS app only reads `version`, to show "v1.2.30 → 1.2.33".
public struct UpdateManifest: Codable, Sendable, Hashable {
    /// "windows" or "mac".
    public var platform: String?
    public var version: String
    public var file: String?
    public var size: Int?
    public var sha256: String?
    /// ISO-8601 time of the release.
    public var released: String?
    /// Ed25519 signature (base64) over platform, version, file, size and hash.
    public var signature: String?

    public init(
        platform: String? = nil, version: String, file: String? = nil, size: Int? = nil,
        sha256: String? = nil, released: String? = nil, signature: String? = nil
    ) {
        self.platform = platform
        self.version = version
        self.file = file
        self.size = size
        self.sha256 = sha256
        self.released = released
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        platform = c.text(.platform)
        version = try c.require(.version)
        file = c.text(.file)
        size = c.integer(.size)
        sha256 = c.text(.sha256)
        released = c.text(.released)
        signature = c.text(.signature)
    }
}

/// `POST /api/invites`: a single-use invitation, valid for ten minutes.
///
/// `code` is a secret: it goes into the link the user shares and nowhere else.
public struct InviteResponse: Codable, Sendable, Hashable {
    public var code: String
    /// The hub origin the invitation is bound to.
    public var origin: String
    public var expires: Double?

    public init(code: String, origin: String, expires: Double? = nil) {
        self.code = code
        self.origin = origin
        self.expires = expires
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        code = try c.require(.code)
        origin = try c.require(.origin)
        expires = c.number(.expires)
    }

    public var expiresDate: Date? { expires.map(Date.init(hubTime:)) }
}

/// One entry of `GET /api/mobile`: a phone or tablet enrolled on the hub.
public struct MobileClient: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var created: Double?
    /// Last authenticated request since the hub started, or nil.
    public var lastSeen: Double?

    public init(id: String, name: String? = nil, created: Double? = nil, lastSeen: Double? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.lastSeen = lastSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = try c.require(.id)
        name = c.text(.name)
        created = c.number(.created)
        lastSeen = c.number(.lastSeen)
    }

    public var createdDate: Date? { created.map(Date.init(hubTime:)) }
    public var lastSeenDate: Date? { lastSeen.map(Date.init(hubTime:)) }
}

/// The temperature unit of the dashboard's display setting and of alert notifications.
public enum TemperatureUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case celsius = "C"
    case fahrenheit = "F"

    /// Anything but "F" is Celsius, as on the hub (`b.tempUnit === 'F' ? 'F' : 'C'`).
    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw == TemperatureUnit.fahrenheit.rawValue ? .fahrenheit : .celsius
    }

    public var symbol: String { "\u{B0}" + rawValue }
}

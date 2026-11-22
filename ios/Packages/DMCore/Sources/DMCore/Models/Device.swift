import Foundation

/// A device as the hub describes it (`deviceView` in server.js): its registry entry, whether it is
/// online, its latest report and, in snapshots, the last ten minutes of samples.
public struct Device: Codable, Sendable, Equatable, Identifiable {
    /// What the hub remembers about the hardware for power estimates while the device is off.
    public struct Hardware: Codable, Sendable, Hashable {
        /// "laptop", "desktop" or nil when the agent could not tell.
        public var formFactor: String?
        public var threads: Int?

        public init(formFactor: String? = nil, threads: Int? = nil) {
            self.formFactor = formFactor
            self.threads = threads
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            formFactor = c.text(.formFactor)
            threads = c.integer(.threads)
        }
    }

    public var id: String
    public var name: String?
    public var hostname: String?
    /// "windows", "linux", "macos" or "unknown".
    public var platform: String?
    public var os: String?
    public var firstSeen: Double?
    public var lastSeen: Double?
    public var order: Int?
    /// True once someone renamed the device on a dashboard; the hub then stops following its hostname.
    public var renamed: Bool
    public var hw: Hardware?
    /// Network card addresses for Wake-on-LAN; empty until the device has reported one.
    public var macs: [String]
    public var online: Bool
    /// nil right after a hub restart, until the device reports again.
    public var latest: Report?
    /// Raw samples of the last ten minutes. Only snapshots, `/api/devices` and `device` events carry
    /// them; the device inside a `report` event has none.
    public var history: [HistoryPoint]

    public init(
        id: String, name: String? = nil, hostname: String? = nil, platform: String? = nil, os: String? = nil,
        firstSeen: Double? = nil, lastSeen: Double? = nil, order: Int? = nil, renamed: Bool = false,
        hw: Hardware? = nil, macs: [String] = [], online: Bool = false, latest: Report? = nil,
        history: [HistoryPoint] = []
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.platform = platform
        self.os = os
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.order = order
        self.renamed = renamed
        self.hw = hw
        self.macs = macs
        self.online = online
        self.latest = latest
        self.history = history
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = try c.require(.id)
        name = c.text(.name)
        hostname = c.text(.hostname)
        platform = c.text(.platform)
        os = c.text(.os)
        firstSeen = c.number(.firstSeen)
        lastSeen = c.number(.lastSeen)
        order = c.integer(.order)
        renamed = c.flag(.renamed) ?? false
        hw = c.optional(.hw)
        macs = c.list(.macs)
        online = c.flag(.online) ?? false
        latest = c.optional(.latest)
        history = c.list(.history)
    }

    /// The title the dashboard shows: `d.name || d.hostname || id` (updateCard in public/index.html).
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let hostname, !hostname.isEmpty { return hostname }
        return id
    }

    public var firstSeenDate: Date? { firstSeen.map(Date.init(hubTime:)) }
    public var lastSeenDate: Date? { lastSeen.map(Date.init(hubTime:)) }
}

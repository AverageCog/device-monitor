import Foundation

/// A device's card as the dashboard fills it in (updateCard in public/index.html): title, status
/// line, the three gauges with the text under each, and the stats grid.
///
/// Everything is computed from the device as the hub sent it. `latestVersions` is keyed the way the
/// hub names platforms in update events and `/api/update/<platform>` ("windows", "mac"); `now` is
/// only needed for "last seen 3m ago".
public struct DeviceCardModel: Sendable, Equatable, Identifiable {
    public let id: String
    /// `d.name || d.hostname || id`.
    public let name: String
    /// What the dashboard shows when hovering the name; empty when the device reported none.
    public let hostname: String
    /// "Windows 11 Pro · up 3d 2h · v1.2.32 → 1.2.33", "linux · online",
    /// "macOS 15.5 · offline · last seen 3m ago".
    public let subtitle: String
    /// The dashboard dims the card of an offline device (opacity 0.55) and greys its status dot.
    public let isOnline: Bool
    public let cpu: DeviceGauge
    public let gpu: DeviceGauge
    public let memory: DeviceGauge
    /// In the order shown, two to a row: CPU, then GPU, VRAM, the system drive, Network and
    /// Disk I/O for whichever of them the device has.
    public let stats: [DeviceStat]

    /// CPU, GPU, Memory, left to right.
    public var gauges: [DeviceGauge] { [cpu, gpu, memory] }

    public init(device d: Device, unit: TemperatureUnit, latestVersions: [String: String] = [:], now: Double = Date().hubTime) {
        let reading = DeviceReading(device: d)
        let L = reading.report
        id = d.id
        name = d.displayName
        hostname = d.hostname ?? ""
        isOnline = d.online

        // const status = d.online ? (L.uptime ? 'up ' + fmtUptime(L.uptime) : 'online') : 'offline · last seen ' + (d.lastSeen ? ago(d.lastSeen) : 'never');
        let status: String
        if d.online {
            status = DashJS.number(L.uptime).map { "up " + Format.fmtUptime($0) } ?? "online"
        } else {
            status = "offline \u{B7} " + DeviceCardModel.lastSeenText(d.lastSeen, now: now)
        }
        // refs.sub.textContent = [d.os || d.platform, status, versionLabel(d)].filter(Boolean).join(' · ');
        subtitle = [DeviceCardModel.systemText(d), status, DeviceVersion.label(for: d, latestVersions: latestVersions)]
            .compactMap(DashJS.text).joined(separator: " \u{B7} ")

        // const cpu = L.cpu || {}, mem = L.memory || {}, gpus = L.gpus || [], g = gpus[0] || {};
        let cpuInfo = L.cpu, mem = L.memory, gpus = L.gpus, g = gpus.first ?? Report.GPU()
        // setGauge(refs.cpu, cpu.usage); setGauge(refs.gpu, gpus.length ? g.usage : null);
        // setGauge(refs.mem, mem.total ? mem.used / mem.total * 100 : null);
        cpu = DeviceGauge(
            kind: .cpu, value: cpuInfo.usage,
            caption: d.online ? DeviceGaugeCaption(celsius: cpuInfo.temp, source: cpuInfo.tempSource, unit: unit) : .offline
        )
        gpu = DeviceGauge(
            kind: .gpu, value: gpus.isEmpty ? nil : g.usage,
            caption: gpus.isEmpty ? .noGPU : d.online ? DeviceGaugeCaption(celsius: g.temp, source: nil, unit: unit) : .offline
        )
        let total = DashJS.number(mem.total)
        memory = DeviceGauge(
            kind: .memory, value: total.map { (mem.used ?? 0) / $0 * 100 },
            caption: .text(total == nil ? "" : Format.memPair(mem.used, mem.total))
        )

        var stats = [DeviceStat]()
        // stats.push(stat('CPU', esc(shortCpu(cpu.name)) + (cpu.clockMHz ? ` · ${(cpu.clockMHz / 1000).toFixed(2)} GHz` : '')));
        let clock = DashJS.number(cpuInfo.clockMHz).map { " \u{B7} " + JS.toFixed($0 / 1000, 2) + " GHz" } ?? ""
        stats.append(DeviceStat(id: "cpu", key: "CPU", value: Format.shortCpu(cpuInfo.name) + clock))
        // if (gpus.length) stats.push(stat('GPU', esc(shortGpu(g.name)) + (g.power != null ? ` · ${Math.round(g.power)} W` : '')));
        if !gpus.isEmpty {
            let power = g.power.map { " \u{B7} " + JS.string(JS.round($0)) + " W" } ?? ""
            stats.append(DeviceStat(id: "gpu", key: "GPU", value: Format.shortGpu(g.name) + power))
        }
        // if (g.memTotal) stats.push(stat('VRAM', `${fmtBytes(g.memUsed)} / ${fmtBytes(g.memTotal, 0)}`, g.memUsed / g.memTotal * 100, 'var(--gpu)'));
        if let memTotal = DashJS.number(g.memTotal) {
            stats.append(DeviceStat(
                id: "vram", key: "VRAM", value: DeviceCardModel.vramText(g),
                ratio: (g.memUsed ?? 0) / memTotal * 100, tint: .gpu
            ))
        }
        // const sys = disks.find(x => x.name === 'C:' || x.name === '/') || disks[0];
        // if (sys) stats.push(stat('Disk ' + esc(sys.name), `${fmtBytes(sys.used, 0)} / ${fmtBytes(sys.total, 0)}`, sys.used / sys.total * 100));
        if let sys = L.disks.first(where: { $0.name == "C:" || $0.name == "/" }) ?? L.disks.first {
            stats.append(DeviceStat(
                id: "disk", key: "Disk " + (sys.name ?? ""),
                value: Format.fmtBytes(sys.used, 0) + " / " + Format.fmtBytes(sys.total, 0),
                ratio: (sys.used ?? 0) / (sys.total ?? 0) * 100
            ))
        }
        // if (L.net) stats.push(stat('Network', `↓ ${fmtRate(L.net.rx)} &nbsp;↑ ${fmtRate(L.net.tx)}`));
        if let net = L.net {
            stats.append(DeviceStat(id: "network", key: "Network", value: "\u{2193} " + Format.fmtRate(net.rx) + " \u{A0}\u{2191} " + Format.fmtRate(net.tx)))
        }
        // if (L.diskIO) stats.push(stat('Disk I/O', `R ${fmtRate(L.diskIO.read)} &nbsp;W ${fmtRate(L.diskIO.write)}`));
        if let io = L.diskIO {
            stats.append(DeviceStat(id: "diskIO", key: "Disk I/O", value: "R " + Format.fmtRate(io.read) + " \u{A0}W " + Format.fmtRate(io.write)))
        }
        self.stats = stats
    }

    /// `d.os || d.platform`.
    static func systemText(_ d: Device) -> String? {
        DashJS.text(d.os) ?? DashJS.text(d.platform)
    }

    /// `'last seen ' + (d.lastSeen ? ago(d.lastSeen) : 'never')`.
    static func lastSeenText(_ lastSeen: Double?, now: Double) -> String {
        "last seen " + (DashJS.number(lastSeen).map { Format.ago($0, now: now) } ?? "never")
    }

    /// `${fmtBytes(g.memUsed)} / ${fmtBytes(g.memTotal, 0)}`, on the card and in the details.
    static func vramText(_ g: Report.GPU) -> String {
        Format.fmtBytes(g.memUsed) + " / " + Format.fmtBytes(g.memTotal, 0)
    }
}

/// The report a card reads its numbers from: the latest one while the device is online, a zeroed
/// copy of it once it is offline, an empty one before the first report.
///
/// `const L = d.online ? d.latest || {} : zeroed(d.latest || {});`
public struct DeviceReading: Sendable, Equatable {
    public let report: Report
    /// `L.offline`.
    public let isOffline: Bool

    public init(device: Device) {
        self.init(report: device.latest, isOnline: device.online)
    }

    public init(report: Report?, isOnline: Bool) {
        let latest = report ?? Report()
        self.report = isOnline ? latest : DeviceReading.zeroed(latest)
        isOffline = !isOnline
    }

    /// An offline device shows zeros rather than its last reading; only what the hardware is (model
    /// names, memory and drive sizes) is kept (function zeroed).
    public static func zeroed(_ L: Report) -> Report {
        var out = L
        out.uptime = nil
        out.temps = []
        out.fans = []
        out.cpu.usage = 0
        out.cpu.temp = nil
        out.cpu.clockMHz = nil
        out.ai = nil
        out.memory.used = 0
        out.gpus = L.gpus.map { g in
            var g = g
            g.usage = 0
            g.temp = nil
            g.memUsed = 0
            g.power = g.power != nil ? 0 : nil
            g.clockMHz = nil
            g.fan = nil
            return g
        }
        if L.net != nil { out.net = Report.Net(rx: 0, tx: 0) }
        if L.diskIO != nil { out.diskIO = Report.DiskIO(read: 0, write: 0) }
        return out
    }
}

/// One of the three gauges on a card (gaugeSvg / setGauge).
public struct DeviceGauge: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case cpu, gpu, memory
    }

    public let kind: Kind
    /// "CPU", "GPU" or "Memory"; the dashboard shows it in capitals under the arc.
    public let label: String
    public let tint: MetricTint
    /// What the gauge was set to, in percent. nil when there is nothing to show: no reading, no
    /// GPU, memory size unknown.
    public let value: Double?
    /// The number in the middle: "24%", or an en dash for no value.
    public let valueText: String
    /// How much of the arc is filled, 0–1.
    public let fraction: Double
    /// The line under the gauge.
    public let caption: DeviceGaugeCaption

    public var id: Kind { kind }

    init(kind: Kind, value: Double?, caption: DeviceGaugeCaption) {
        self.kind = kind
        switch kind {
        case .cpu:
            label = "CPU"
            tint = .cpu
        case .gpu:
            label = "GPU"
            tint = .gpu
        case .memory:
            label = "Memory"
            tint = .mem
        }
        self.value = value
        valueText = Format.fmtPct(value)
        // const v = pct == null ? 0 : Math.max(0, Math.min(100, pct));
        let clamped = value.map { max(0, min(100, $0)) } ?? 0
        fraction = clamped.isNaN ? 0 : clamped / 100
        self.caption = caption
    }
}

/// The line under a gauge.
public enum DeviceGaugeCaption: Sendable, Equatable {
    /// A pill with a coloured dot and the temperature.
    case temperature(DeviceTemperaturePill)
    /// The device is online but has no temperature for this part.
    case noSensor
    case noGPU
    case offline
    /// Plain text: used and total memory ("27.1 / 64 GB"), or nothing when the size is unknown.
    case text(String)

    /// function tempPill(c, src): the pill, or "no sensor" without a reading.
    init(celsius: Double?, source: String?, unit: TemperatureUnit) {
        if let pill = DeviceTemperaturePill(celsius: celsius, source: source, unit: unit) {
            self = .temperature(pill)
        } else {
            self = .noSensor
        }
    }

    /// What the caption says. For a temperature that is the reading alone ("59°C").
    public var text: String {
        switch self {
        case .temperature(let pill): pill.text
        case .noSensor: "no sensor"
        case .noGPU: "no GPU"
        case .offline: "offline"
        case .text(let text): text
        }
    }

    /// Whether the dashboard writes it small and muted (its `hint` style) rather than as a value.
    public var isHint: Bool {
        switch self {
        case .noSensor, .noGPU, .offline: true
        case .temperature, .text: false
        }
    }
}

/// A temperature under a gauge (function tempPill).
public struct DeviceTemperaturePill: Sendable, Equatable {
    /// The reading in the chosen unit: "59°C", "138°F".
    public let text: String
    /// Decides the dot's colour: normal is the palette's good, warm its warning, hot its critical.
    public let status: Format.TempStatus
    /// "Warm" or "Hot", written small after the reading. nil while normal: the dashboard then
    /// shows the dot and the reading only.
    public let statusText: String?
    /// "ACPI sensor" when the reading comes from the less precise ACPI thermal zone.
    public let note: String?
    /// What the dashboard shows on hover: "Normal", "Warm · ACPI sensor".
    public let tooltip: String

    public init?(celsius: Double?, source: String?, unit: TemperatureUnit) {
        guard let status = Format.tempStatus(celsius) else { return nil }
        text = Format.fmtTemp(celsius, unit)
        self.status = status
        statusText = status == .normal ? nil : status.label
        note = source == "acpi" ? "ACPI sensor" : nil
        tooltip = status.label + (note.map { " \u{B7} " + $0 } ?? "")
    }
}

/// The app version a device runs, set against the newest one the hub has published.
public enum DeviceVersion {
    /// The name the hub's update events and `/api/update/<platform>` use for a device's platform.
    ///
    /// `const platformKey = p => (p === 'windows' ? 'windows' : p === 'macos' ? 'mac' : null);`
    public static func platformKey(_ platform: String?) -> String? {
        switch platform {
        case "windows": "windows"
        case "macos": "mac"
        default: nil
        }
    }

    /// "v1.2.32", or "v1.2.32 → 1.2.33" when the hub has a newer version for that platform; nil for
    /// a device that does not run the desktop app (function versionLabel).
    public static func label(for device: Device, latestVersions: [String: String]) -> String? {
        guard let v = DashJS.text(device.latest?.appVersion) else { return nil }
        let want = platformKey(device.platform).flatMap { DashJS.text(latestVersions[$0]) }
        if let want, want != v { return "v\(v) \u{2192} \(want)" }
        return "v\(v)"
    }
}

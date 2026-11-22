import Foundation

/// One machine of the demo fleet: what it is and how busy it tends to be. Modelled on the devices
/// of build/screenshots.js and build/test/mobile-hub.js.
struct DemoMachine: Sendable {
    struct CPU: Sendable {
        var name: String
        var threads: Int
        /// Typical load in percent, and how far it swings around that.
        var base: Double
        var swing: Double
        var clock: Double
        /// Temperature when idle.
        var temp: Double
    }

    struct GPU: Sendable {
        var name: String
        var base: Double
        var swing: Double
        var memory: Double
        /// Power limit in watts; nil for a GPU that reports no power.
        var power: Double?
        /// Temperature under typical load; nil for a GPU that reports none.
        var temp: Double?
    }

    var id: String
    var name: String
    var platform: String
    var os: String
    var formFactor: String
    var uptime: Double
    var appVersion: String?
    var mac: String?
    var cpu: CPU
    var memory: Double
    var memoryUse: Double
    /// A measured CPU power reading in watts at typical load, for machines that have a sensor.
    var cpuPower: Double?
    var gpus: [GPU] = []
    var disks: [Report.Disk] = []
    var fans: [Report.Fan] = []
    var temps: [Report.Temp] = []
    var ai: [Report.AIApp]?
    /// How much more network traffic than a desktop.
    var networkScale: Double = 1
    /// Stopped reporting this long before the demo began, and has been off since.
    var offFor: Double?
    /// Was off between these two moments before the demo began (ms before, earlier first).
    var outage: (from: Double, to: Double)?
    /// Had its lid closed before seven in the morning, except in the hour before the demo began.
    var sleepsAtNight = false

    static let currentAppVersion = "1.2.33"

    static let gaming = "gaming", spark = "spark", macbook = "mbp", server = "server", studio = "studio", livingRoom = "htpc"

    private static let GB = 1e9, TB = 1e12

    static let fleet: [DemoMachine] = [
        DemoMachine(
            id: gaming, name: "Gaming PC", platform: "windows", os: "Windows 11 Pro", formFactor: "desktop", uptime: 5.2 * 3600,
            appVersion: currentAppVersion, mac: "a8:a1:59:3c:10:01",
            cpu: CPU(name: "AMD Ryzen 9 9950X3D", threads: 32, base: 22, swing: 18, clock: 5250, temp: 52), memory: 64 * GB, memoryUse: 0.48,
            gpus: [GPU(name: "NVIDIA GeForce RTX 5090", base: 70, swing: 25, memory: 32 * GB, power: 575, temp: 66)],
            disks: [.init(name: "C:", label: "Windows", total: 2 * TB, used: 1.1 * TB), .init(name: "D:", label: "Games", total: 4 * TB, used: 3.1 * TB)],
            fans: [.init(name: "CPU fan", rpm: 1240), .init(name: "Rear", rpm: 980), .init(name: "Front 1", rpm: 1110), .init(name: "Front 2", rpm: 1105)],
            temps: [.init(name: "CPU Package", value: 61), .init(name: "Motherboard", value: 38), .init(name: "NVMe 1", value: 44), .init(name: "NVMe 2", value: 41)],
            ai: []),
        DemoMachine(
            id: spark, name: "DGX Spark", platform: "linux", os: "Ubuntu 24.04 LTS", formFactor: "desktop", uptime: 12 * 86400,
            cpu: CPU(name: "NVIDIA Grace (Cortex-X925)", threads: 20, base: 18, swing: 10, clock: 3900, temp: 58), memory: 128 * GB, memoryUse: 0.86,
            cpuPower: 38,
            gpus: [GPU(name: "NVIDIA GB10", base: 88, swing: 10, memory: 0, power: 140, temp: 71)],
            disks: [.init(name: "/", total: 4 * TB, used: 2.3 * TB)],
            ai: [
                .init(app: "ComfyUI", mem: 62e9, models: [
                    .init(name: "flux2_dev_fp8.safetensors", size: 23.8e9, kind: "unet"), .init(name: "qwen3_vl_8b.safetensors", size: 16.4e9, kind: "clip"),
                    .init(name: "flux2_vae.safetensors", size: 0.34e9, kind: "vae"),
                ]),
                .init(app: "Ollama", mem: 21e9, models: [.init(name: "qwen3:32b", size: 20.1e9)]),
            ],
            outage: (from: 30 * 3600e3, to: 26 * 3600e3)),
        DemoMachine(
            id: macbook, name: "MacBook Pro", platform: "macos", os: "macOS 26.1", formFactor: "laptop", uptime: 3 * 86400,
            appVersion: currentAppVersion,
            cpu: CPU(name: "Apple M4 Max", threads: 16, base: 14, swing: 10, clock: 4500, temp: 49), memory: 48 * GB, memoryUse: 0.62,
            gpus: [GPU(name: "Apple M4 Max GPU", base: 12, swing: 8, memory: 0, power: nil, temp: nil)],
            disks: [.init(name: "/", label: "Macintosh HD", total: 2 * TB, used: 0.9 * TB)],
            sleepsAtNight: true),
        DemoMachine(
            id: server, name: "Home Server", platform: "linux", os: "Debian 13", formFactor: "desktop", uptime: 41 * 86400,
            mac: "3c:ec:ef:7a:22:04",
            cpu: CPU(name: "Intel Core i5-13500", threads: 20, base: 9, swing: 5, clock: 2500, temp: 41), memory: 32 * GB, memoryUse: 0.41,
            disks: [
                .init(name: "/", total: 0.5 * TB, used: 0.12 * TB), .init(name: "/mnt/media", label: "Media", total: 16 * TB, used: 11.8 * TB),
                .init(name: "/mnt/backup", label: "Backup", total: 8 * TB, used: 7.6 * TB),
            ],
            networkScale: 5),
        DemoMachine(
            id: studio, name: "Studio PC", platform: "windows", os: "Windows 11 Home", formFactor: "desktop", uptime: 26 * 3600,
            appVersion: "1.2.30", mac: "04:42:1a:9e:5b:05",
            cpu: CPU(name: "Intel Core i9-14900K", threads: 32, base: 31, swing: 22, clock: 5600, temp: 57), memory: 96 * GB, memoryUse: 0.55,
            gpus: [
                GPU(name: "NVIDIA GeForce RTX 4090", base: 55, swing: 35, memory: 24 * GB, power: 450, temp: 63),
                GPU(name: "NVIDIA GeForce RTX 4070 Ti SUPER", base: 20, swing: 15, memory: 16 * GB, power: 285, temp: 54),
            ],
            disks: [.init(name: "C:", label: "System", total: 1 * TB, used: 0.61 * TB), .init(name: "E:", label: "Projects", total: 8 * TB, used: 5.2 * TB)],
            fans: [.init(name: "CPU pump", rpm: 2650), .init(name: "Top 1", rpm: 890), .init(name: "Top 2", rpm: 905), .init(name: "GPU 2", rpm: 1420)],
            temps: [.init(name: "CPU Package", value: 64), .init(name: "VRM", value: 52), .init(name: "NVMe", value: 47)]),
        // Off for three days, with a network card address on record: the one to try Wake on.
        DemoMachine(
            id: livingRoom, name: "Living Room PC", platform: "windows", os: "Windows 11 Home", formFactor: "desktop", uptime: 2 * 3600,
            appVersion: "1.2.30", mac: "70:85:c2:6b:f0:07",
            cpu: CPU(name: "AMD Ryzen 5 5600G", threads: 12, base: 8, swing: 6, clock: 3900, temp: 44), memory: 16 * GB, memoryUse: 0.37,
            disks: [.init(name: "C:", label: "Windows", total: 1 * TB, used: 0.42 * TB)],
            offFor: 3 * 86400e3),
    ]
}

/// What a machine was doing at one moment.
struct DemoReading: Sendable {
    var cpu: Double
    /// Percent of memory in use.
    var memory: Double
    var cpuTemp: Double
    var gpuUsage: [Double]
    var gpuTemp: [Double?]
    var gpuPower: [Double?]
    var measuredCPUPower: Double?
    var power: PowerEstimate
}

/// The demo's synthetic measurements. Everything is a pure function of the seed, the machine and
/// the time, so a chart shows the same curve however often and in whatever pieces it is asked
/// for, and energy totals agree with the history they summarise.
struct DemoModel: Sendable {
    static let rawInterval: Double = 2000
    static let minute: Double = 60e3
    /// The hub keeps raw samples for an hour (`RAW_MS` in history.js).
    static let rawWindow: Double = 60 * 60e3

    let seed: UInt64
    /// When the demo began: before it, machines were on or off by habit; after it, by what
    /// actually happened.
    let start: Double
    let historySpan: Double
    let timeZone: TimeZone

    // MARK: Noise

    /// A repeatable number in 0..<1 for a machine, a channel and a time slot.
    func noise(_ machine: Int, _ channel: Int, _ slot: Double) -> Double {
        var x = seed &+ 0x9E37_79B9_7F4A_7C15
        for part in [UInt64(truncatingIfNeeded: machine), UInt64(truncatingIfNeeded: channel), UInt64(truncatingIfNeeded: Int64(slot))] {
            x = (x ^ part) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
        }
        return Double(x >> 11) / 9_007_199_254_740_992
    }

    static func clamp(_ value: Double) -> Double { max(0, min(100, value)) }

    /// What a reading stands for. A stored minute is thirty raw samples summed up, so its noise
    /// is drawn as theirs would come out: an average strays √30 times less than one sample, and
    /// a peak is the highest of thirty. Otherwise a chart whose last hour is built from raw
    /// samples (as `query` does for buckets under a minute) changes character an hour ago.
    enum Draw: Sendable {
        /// One two-second sample.
        case sample
        /// The average of a minute of samples.
        case average
        /// The highest of a minute of samples.
        case peak

        var grain: Double { self == .sample ? DemoModel.rawInterval : DemoModel.minute }
        /// Keeps the three kinds' noise apart.
        var family: Int {
            switch self {
            case .sample: 0
            case .average: 100
            case .peak: 200
            }
        }

        /// Where in its range (0..<1) a reading falls, for a uniform draw `u`.
        func level(_ u: Double) -> Double {
            let samples = DemoModel.minute / DemoModel.rawInterval
            return switch self {
            case .sample: u
            case .average: 0.5 + (u - 0.5) / samples.squareRoot()
            // The highest of n uniform draws is distributed as u^(1/n).
            case .peak: pow(u, 1 / samples)
            }
        }
    }

    /// `wave` in build/screenshots.js: a smooth, slightly noisy load curve.
    private func wave(_ t: Double, base: Double, swing: Double, phase: Double, level: Double) -> Double {
        Self.clamp(base + swing * (0.6 * sin(t / 2.1e6 + phase) + 0.4 * sin(t / 5.3e5 + phase * 3)) + (level - 0.5) * swing * 0.3)
    }

    // MARK: Readings

    /// `sample(d, t, i)` in build/test/mobile-hub.js, with every GPU: one raw sample, or what a
    /// minute of them averages or peaks at.
    func reading(_ machine: DemoMachine, index: Int, at t: Double, draw: Draw) -> DemoReading {
        let slot = (t / draw.grain).rounded(.down), family = draw.family
        let cpu = wave(t, base: machine.cpu.base, swing: machine.cpu.swing, phase: Double(index), level: draw.level(noise(index, family, slot)))
        var usage: [Double] = [], temps: [Double?] = [], powers: [Double?] = []
        for (n, gpu) in machine.gpus.enumerated() {
            let phase = Double(n == 0 ? index + 1 : index + n + 2)
            let load = wave(t, base: gpu.base, swing: gpu.swing, phase: phase, level: draw.level(noise(index, family + 1 + n, slot)))
            usage.append(load)
            temps.append(gpu.temp.map { $0 - 20 + load * 0.25 })
            powers.append(gpu.power.map { $0 * (0.12 + 0.85 * load / 100) })
        }
        let measured = machine.cpuPower.map { $0 * (0.6 + cpu / 100) }
        let estimate = Self.powerEstimate(
            formFactor: machine.formFactor, threads: machine.cpu.threads, cpuUsage: cpu, measuredCPU: measured,
            gpus: zip(machine.gpus, zip(usage, powers)).map { (power: $1.1, memoryTotal: $0.memory, usage: $1.0) })
        return DemoReading(
            cpu: cpu, memory: machine.memoryUse * 100 + sin(t / 3e6 + Double(index)) * 3, cpuTemp: machine.cpu.temp + cpu * 0.25,
            gpuUsage: usage, gpuTemp: temps, gpuPower: powers, measuredCPUPower: measured, power: estimate)
    }

    /// `estimate` in power.js.
    static func powerEstimate(
        formFactor: String, threads: Int, cpuUsage: Double, measuredCPU: Double?, gpus: [(power: Double?, memoryTotal: Double, usage: Double)]
    ) -> PowerEstimate {
        let laptop = formFactor == "laptop", threads = Double(max(1, min(512, threads)))
        let idle: Double = laptop ? 3 : 12, most = laptop ? min(45, 8 + threads * 2) : min(250, 30 + threads * 5)
        let rest: Double = laptop ? 6 : 25, efficiency = laptop ? 0.88 : 0.9
        let cpu = measuredCPU ?? idle + (most - idle) * clamp(cpuUsage) / 100
        var gpu = 0.0, measured = false, estimated = false
        for card in gpus {
            if let power = card.power {
                gpu += power
                measured = true
            } else if card.memoryTotal >= 2 * 1_073_741_824 {
                // Small adapters are integrated graphics, already part of the CPU package.
                gpu += 10 + 1.5 * card.usage
                estimated = true
            }
        }
        let components = cpu + gpu + rest, watts = components / efficiency
        let tenth = { (v: Double) in (v * 10).rounded() / 10 }
        return PowerEstimate(
            watts: tenth(watts), cpu: tenth(cpu), gpu: tenth(gpu), rest: rest, losses: tenth(watts - components),
            cpuMeasured: measuredCPU != nil, gpuMeasured: measured, gpuEstimated: estimated)
    }

    /// Network and disk rates, which have no peaks of their own (MAX_FIELDS in history.js).
    private func traffic(_ machine: DemoMachine, index: Int, at t: Double, draw: Draw) -> (rx: Double, tx: Double, read: Double, write: Double) {
        let scale = machine.networkScale, slot = (t / draw.grain).rounded(.down)
        let level = { (channel: Int) in draw.level(noise(index, draw.family + channel, slot)) }
        return (rx: 1e5 + level(20) * 8e5 * scale, tx: 4e4 + level(21) * 2e5 * scale, read: level(22) * 3e6, write: level(23) * 2e6)
    }

    /// The history sample of a report: the fields `handleReport` in server.js keeps.
    func rawPoint(_ machine: DemoMachine, index: Int, at t: Double) -> HistoryPoint {
        let r = reading(machine, index: index, at: t, draw: .sample)
        let io = traffic(machine, index: index, at: t, draw: .sample)
        return HistoryPoint(
            t: t, cpu: r.cpu, gpu: r.gpuUsage.first, mem: r.memory, cpuTemp: r.cpuTemp, gpuTemp: r.gpuTemp.first ?? nil,
            gpuPower: r.gpuPower.first ?? nil, power: r.power.watts, rx: io.rx, tx: io.tx, dr: io.read, dw: io.write)
    }

    /// A stored one-minute average with its peaks, as `aggregate` in history.js writes them.
    func minutePoint(_ machine: DemoMachine, index: Int, at t: Double) -> HistoryPoint {
        let r = reading(machine, index: index, at: t, draw: .average), top = reading(machine, index: index, at: t, draw: .peak)
        let io = traffic(machine, index: index, at: t, draw: .average)
        let gpu = r.gpuUsage.first, gpuTemp = r.gpuTemp.first ?? nil
        // Drawn apart, a peak could come out under its average, which no thirty samples can do.
        let peak = { (average: Double, highest: Double?) in Self.cents(max(average, highest ?? average)) }
        return HistoryPoint(
            t: t, cpu: Self.cents(r.cpu), gpu: gpu.map(Self.cents), mem: Self.cents(r.memory), cpuTemp: Self.cents(r.cpuTemp),
            gpuTemp: gpuTemp.map(Self.cents), gpuPower: (r.gpuPower.first ?? nil).map(Self.cents), power: r.power.watts,
            rx: Self.cents(io.rx), tx: Self.cents(io.tx), dr: Self.cents(io.read), dw: Self.cents(io.write),
            cpuMax: peak(r.cpu, top.cpu), gpuMax: gpu.map { peak($0, top.gpuUsage.first) }, cpuTempMax: peak(r.cpuTemp, top.cpuTemp),
            gpuTempMax: gpuTemp.map { peak($0, top.gpuTemp.first ?? nil) }, powerMax: peak(r.power.watts, top.power.watts), n: 30)
    }

    /// `+x.toFixed(2)`
    static func cents(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// The report a machine's agent would send at `t`, as the hub hands it on
    /// (`report(d, i)` in build/test/mobile-hub.js, then `handleReport` in server.js).
    func report(_ machine: DemoMachine, index: Int, name: String, at t: Double, diskOverride: [String: Double] = [:]) -> Report {
        let r = reading(machine, index: index, at: t, draw: .sample)
        let slot = (t / Self.rawInterval).rounded(.down)
        let io = traffic(machine, index: index, at: t, draw: .sample)
        let cores = (0..<machine.cpu.threads).map { core -> Double? in Self.clamp(r.cpu + (noise(index, 1000 + core, slot) - 0.5) * 30) }
        let gpus = machine.gpus.enumerated().map { n, gpu in
            Report.GPU(
                name: gpu.name, vendor: gpu.name.contains("Apple") ? "apple" : "nvidia", usage: r.gpuUsage[n], temp: r.gpuTemp[n],
                memUsed: gpu.memory * (0.3 + 0.6 * r.gpuUsage[n] / 100), memTotal: gpu.memory, power: r.gpuPower[n], powerLimit: gpu.power,
                fan: r.gpuTemp[n].map { _ in 30 + r.gpuUsage[n] * 0.4 }, clockMHz: gpu.power.map { _ in 2400 + r.gpuUsage[n] * 3 })
        }
        let disks = machine.disks.map { disk in
            var disk = disk
            if let fraction = diskOverride[disk.name ?? ""], let total = disk.total { disk.used = total * fraction }
            return disk
        }
        return Report(
            id: machine.id, hostname: name, platform: machine.platform, os: machine.os, uptime: machine.uptime + max(0, t - start) / 1000,
            formFactor: machine.formFactor, power: r.measuredCPUPower.map { Report.MeasuredPower(cpu: $0) }, features: ["procs", "actions"],
            actions: machine.platform == "macos" ? [] : ["sleep", "restart", "shutdown"], macs: machine.mac.map { [$0] } ?? [],
            appVersion: machine.appVersion,
            cpu: Report.CPU(name: machine.cpu.name, usage: r.cpu, cores: cores, threads: machine.cpu.threads, clockMHz: machine.cpu.clock, temp: r.cpuTemp),
            memory: Report.Memory(total: machine.memory, used: machine.memory * r.memory / 100), gpus: gpus, disks: disks,
            net: Report.Net(rx: io.rx, tx: io.tx), diskIO: Report.DiskIO(read: io.read, write: io.write),
            temps: machine.temps.enumerated().map { n, sensor in
                Report.Temp(name: sensor.name, parent: "Motherboard", value: (sensor.value ?? 0) + noise(index, 2000 + n, slot) * 2)
            },
            fans: machine.fans.enumerated().map { n, fan in Report.Fan(name: fan.name, rpm: (fan.rpm ?? 0) + noise(index, 3000 + n, slot) * 30) },
            ai: machine.ai, receivedAt: t, powerEst: r.power)
    }

    // MARK: History

    /// Whether the machine was on at `t` before the demo began.
    func wasOn(_ machine: DemoMachine, at t: Double) -> Bool {
        guard t >= start - historySpan else { return false }
        if let off = machine.offFor, t >= start - off { return false }
        if let outage = machine.outage, t > start - outage.from, t < start - outage.to { return false }
        // It reports from the moment the demo begins, so if that is before seven it was opened
        // an hour earlier: an online device with nothing behind it would show an empty card.
        if machine.sleepsAtNight, t < start - Self.rawWindow {
            let local = t / 1000 + Double(timeZone.secondsFromGMT(for: Date(hubTime: t)))
            if local.truncatingRemainder(dividingBy: 86400) < 7 * 3600 { return false }
        }
        return true
    }

    /// `aggregate(points, width, start)` in history.js: averages over buckets `width` wide, with
    /// the peak within each bucket.
    static func aggregate(_ points: [HistoryPoint], width: Double, start: Double) -> [HistoryPoint] {
        let metrics = HistoryPoint.Metric.allCases
        // MAX_FIELDS: the series whose peak within a bucket is kept.
        let keepsPeak = metrics.map { [HistoryPoint.Metric.cpu, .gpu, .cpuTemp, .gpuTemp, .power].contains($0) }
        let position = Dictionary(uniqueKeysWithValues: metrics.enumerated().map { ($1, $0) })
        var out: [HistoryPoint] = []
        var bucket: Double?
        var sums = [Double](repeating: 0, count: metrics.count), counts = [Int](repeating: 0, count: metrics.count)
        var peaks = [Double?](repeating: nil, count: metrics.count)
        func flush() {
            guard let t = bucket else { return }
            let average = { (metric: HistoryPoint.Metric) -> Double? in
                let i = position[metric] ?? 0
                return counts[i] == 0 ? nil : cents(sums[i] / Double(counts[i]))
            }
            let peak = { (metric: HistoryPoint.Metric) -> Double? in peaks[position[metric] ?? 0] }
            out.append(HistoryPoint(
                t: t, cpu: average(.cpu), gpu: average(.gpu), mem: average(.mem), cpuTemp: average(.cpuTemp), gpuTemp: average(.gpuTemp),
                gpuPower: average(.gpuPower), power: average(.power), rx: average(.rx), tx: average(.tx), dr: average(.dr), dw: average(.dw),
                cpuMax: peak(.cpu), gpuMax: peak(.gpu), cpuTempMax: peak(.cpuTemp), gpuTempMax: peak(.gpuTemp), powerMax: peak(.power)))
        }
        for point in points {
            let b = start + ((point.t - start) / width).rounded(.down) * width
            if bucket != b {
                flush()
                bucket = b
                for i in metrics.indices {
                    sums[i] = 0
                    counts[i] = 0
                    peaks[i] = nil
                }
            }
            for (i, metric) in metrics.enumerated() {
                let value = point.value(metric)
                if let value {
                    sums[i] += value
                    counts[i] += 1
                }
                // The stored peak when the point has one, else the value itself.
                if keepsPeak[i], let top = point.peak(metric) ?? value, top > peaks[i] ?? -.infinity { peaks[i] = top }
            }
        }
        flush()
        return out
    }
}

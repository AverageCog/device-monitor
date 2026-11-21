import Foundation

/// A device's latest report after the hub normalised it (`normalizeReport` in security.js), plus the
/// two fields the hub adds: when it arrived and the power estimate.
///
/// The hub rebuilds every report from known fields, so strings are strings and numbers are finite,
/// but any reading the hardware does not offer is null.
public struct Report: Codable, Sendable, Equatable {
    public struct CPU: Codable, Sendable, Hashable {
        public var name: String?
        /// Percent, 0–100.
        public var usage: Double?
        /// Per-core load in percent; a core the agent could not read is nil.
        public var cores: [Double?]
        public var threads: Int?
        public var clockMHz: Double?
        /// Degrees Celsius.
        public var temp: Double?
        /// "acpi" when the temperature comes from the less precise ACPI thermal zone.
        public var tempSource: String?

        public init(
            name: String? = nil, usage: Double? = nil, cores: [Double?] = [], threads: Int? = nil,
            clockMHz: Double? = nil, temp: Double? = nil, tempSource: String? = nil
        ) {
            self.name = name
            self.usage = usage
            self.cores = cores
            self.threads = threads
            self.clockMHz = clockMHz
            self.temp = temp
            self.tempSource = tempSource
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            usage = c.number(.usage)
            cores = c.optionalNumbers(.cores) ?? []
            threads = c.integer(.threads)
            clockMHz = c.number(.clockMHz)
            temp = c.number(.temp)
            tempSource = c.text(.tempSource)
        }
    }

    public struct Memory: Codable, Sendable, Hashable {
        /// Bytes.
        public var total: Double?
        public var used: Double?

        public init(total: Double? = nil, used: Double? = nil) {
            self.total = total
            self.used = used
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            total = c.number(.total)
            used = c.number(.used)
        }
    }

    public struct GPU: Codable, Sendable, Hashable {
        public var name: String?
        public var vendor: String?
        public var usage: Double?
        public var temp: Double?
        /// Bytes.
        public var memUsed: Double?
        public var memTotal: Double?
        /// Watts, when the card measures it.
        public var power: Double?
        public var powerLimit: Double?
        /// Percent.
        public var fan: Double?
        public var clockMHz: Double?

        public init(
            name: String? = nil, vendor: String? = nil, usage: Double? = nil, temp: Double? = nil,
            memUsed: Double? = nil, memTotal: Double? = nil, power: Double? = nil, powerLimit: Double? = nil,
            fan: Double? = nil, clockMHz: Double? = nil
        ) {
            self.name = name
            self.vendor = vendor
            self.usage = usage
            self.temp = temp
            self.memUsed = memUsed
            self.memTotal = memTotal
            self.power = power
            self.powerLimit = powerLimit
            self.fan = fan
            self.clockMHz = clockMHz
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            vendor = c.text(.vendor)
            usage = c.number(.usage)
            temp = c.number(.temp)
            memUsed = c.number(.memUsed)
            memTotal = c.number(.memTotal)
            power = c.number(.power)
            powerLimit = c.number(.powerLimit)
            fan = c.number(.fan)
            clockMHz = c.number(.clockMHz)
        }
    }

    public struct Disk: Codable, Sendable, Hashable {
        /// Drive letter or mount point ("C:", "/").
        public var name: String?
        public var label: String?
        /// Bytes.
        public var total: Double?
        public var used: Double?

        public init(name: String? = nil, label: String? = nil, total: Double? = nil, used: Double? = nil) {
            self.name = name
            self.label = label
            self.total = total
            self.used = used
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            label = c.text(.label)
            total = c.number(.total)
            used = c.number(.used)
        }
    }

    /// Network throughput in bytes per second.
    public struct Net: Codable, Sendable, Hashable {
        public var rx: Double?
        public var tx: Double?

        public init(rx: Double? = nil, tx: Double? = nil) {
            self.rx = rx
            self.tx = tx
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            rx = c.number(.rx)
            tx = c.number(.tx)
        }
    }

    /// Disk throughput in bytes per second.
    public struct DiskIO: Codable, Sendable, Hashable {
        public var read: Double?
        public var write: Double?

        public init(read: Double? = nil, write: Double? = nil) {
            self.read = read
            self.write = write
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            read = c.number(.read)
            write = c.number(.write)
        }
    }

    public struct Temp: Codable, Sendable, Hashable {
        public var name: String?
        /// The hardware the sensor belongs to.
        public var parent: String?
        /// Degrees Celsius.
        public var value: Double?

        public init(name: String? = nil, parent: String? = nil, value: Double? = nil) {
            self.name = name
            self.parent = parent
            self.value = value
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            parent = c.text(.parent)
            value = c.number(.value)
        }
    }

    public struct Fan: Codable, Sendable, Hashable {
        public var name: String?
        public var rpm: Double?

        public init(name: String? = nil, rpm: Double? = nil) {
            self.name = name
            self.rpm = rpm
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            rpm = c.number(.rpm)
        }
    }

    /// An app holding AI models in memory (Ollama, LM Studio, ComfyUI, vLLM, llama.cpp…).
    public struct AIApp: Codable, Sendable, Hashable {
        public var app: String?
        /// GPU memory the app holds, in bytes.
        public var mem: Double?
        public var models: [AIModel]

        public init(app: String? = nil, mem: Double? = nil, models: [AIModel] = []) {
            self.app = app
            self.mem = mem
            self.models = models
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            app = c.text(.app)
            mem = c.number(.mem)
            models = c.list(.models)
        }
    }

    public struct AIModel: Codable, Sendable, Hashable {
        public var name: String?
        /// Bytes.
        public var size: Double?
        /// What the app uses it as ("unet", "clip", "vae"), when it says.
        public var kind: String?

        public init(name: String? = nil, size: Double? = nil, kind: String? = nil) {
            self.name = name
            self.size = size
            self.kind = kind
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            name = c.text(.name)
            size = c.number(.size)
            kind = c.text(.kind)
        }
    }

    /// Power the hardware measures itself, in watts.
    public struct MeasuredPower: Codable, Sendable, Hashable {
        public var cpu: Double?

        public init(cpu: Double? = nil) {
            self.cpu = cpu
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            cpu = c.number(.cpu)
        }
    }

    /// How a power action or a wake-up went. A device's own result carries the command id; the
    /// hub's "Wake-up signal sent." does not.
    public struct ActionResult: Codable, Sendable, Hashable {
        public var id: String?
        public var ok: Bool
        public var message: String?

        public init(id: String? = nil, ok: Bool, message: String? = nil) {
            self.id = id
            self.ok = ok
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            id = c.text(.id)
            ok = c.flag(.ok) ?? false
            message = c.text(.message)
        }
    }

    public var id: String?
    public var hostname: String?
    public var platform: String?
    public var os: String?
    /// Seconds since boot.
    public var uptime: Double?
    /// "laptop", "desktop" or nil.
    public var formFactor: String?
    public var power: MeasuredPower?
    /// What the agent can do when asked: "procs", "actions".
    public var features: [String]
    /// Power actions the device's owner allowed: "sleep", "restart", "shutdown".
    public var actions: [String]
    public var macs: [String]
    public var actionResult: ActionResult?
    /// Version of the desktop app reporting for this device, when there is one.
    public var appVersion: String?
    public var cpu: CPU
    public var memory: Memory
    /// Biggest card first, so the main gauge shows the workhorse rather than a display adapter.
    public var gpus: [GPU]
    public var disks: [Disk]
    public var net: Net?
    public var diskIO: DiskIO?
    public var temps: [Temp]
    public var fans: [Fan]
    /// nil: the agent does not look for AI apps. Empty: it looked and nothing is loaded.
    public var ai: [AIApp]?
    /// When the hub received the report (ms since 1970).
    public var receivedAt: Double?
    public var powerEst: PowerEstimate?

    public init(
        id: String? = nil, hostname: String? = nil, platform: String? = nil, os: String? = nil,
        uptime: Double? = nil, formFactor: String? = nil, power: MeasuredPower? = nil,
        features: [String] = [], actions: [String] = [], macs: [String] = [],
        actionResult: ActionResult? = nil, appVersion: String? = nil, cpu: CPU = CPU(),
        memory: Memory = Memory(), gpus: [GPU] = [], disks: [Disk] = [], net: Net? = nil,
        diskIO: DiskIO? = nil, temps: [Temp] = [], fans: [Fan] = [], ai: [AIApp]? = nil,
        receivedAt: Double? = nil, powerEst: PowerEstimate? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.platform = platform
        self.os = os
        self.uptime = uptime
        self.formFactor = formFactor
        self.power = power
        self.features = features
        self.actions = actions
        self.macs = macs
        self.actionResult = actionResult
        self.appVersion = appVersion
        self.cpu = cpu
        self.memory = memory
        self.gpus = gpus
        self.disks = disks
        self.net = net
        self.diskIO = diskIO
        self.temps = temps
        self.fans = fans
        self.ai = ai
        self.receivedAt = receivedAt
        self.powerEst = powerEst
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = c.text(.id)
        hostname = c.text(.hostname)
        platform = c.text(.platform)
        os = c.text(.os)
        uptime = c.number(.uptime)
        formFactor = c.text(.formFactor)
        power = c.optional(.power)
        features = c.list(.features)
        actions = c.list(.actions)
        macs = c.list(.macs)
        actionResult = c.optional(.actionResult)
        appVersion = c.text(.appVersion)
        cpu = c.optional(.cpu) ?? CPU()
        memory = c.optional(.memory) ?? Memory()
        gpus = c.list(.gpus)
        disks = c.list(.disks)
        net = c.optional(.net)
        diskIO = c.optional(.diskIO)
        temps = c.list(.temps)
        fans = c.list(.fans)
        ai = c.listIfPresent(.ai)
        receivedAt = c.number(.receivedAt)
        powerEst = c.optional(.powerEst)
    }

    public var receivedDate: Date? { receivedAt.map(Date.init(hubTime:)) }
}

/// The hub's estimate of what a device draws at the wall (`estimate` in power.js), in watts.
public struct PowerEstimate: Codable, Sendable, Hashable {
    public var watts: Double
    public var cpu: Double
    public var gpu: Double
    /// Fixed allowance for the motherboard, memory, drives and fans.
    public var rest: Double
    /// Power-supply or charger losses.
    public var losses: Double
    public var cpuMeasured: Bool
    public var gpuMeasured: Bool
    public var gpuEstimated: Bool

    public init(
        watts: Double, cpu: Double = 0, gpu: Double = 0, rest: Double = 0, losses: Double = 0,
        cpuMeasured: Bool = false, gpuMeasured: Bool = false, gpuEstimated: Bool = false
    ) {
        self.watts = watts
        self.cpu = cpu
        self.gpu = gpu
        self.rest = rest
        self.losses = losses
        self.cpuMeasured = cpuMeasured
        self.gpuMeasured = gpuMeasured
        self.gpuEstimated = gpuEstimated
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        // Without a total there is no estimate: the device then shows none rather than 0 W.
        watts = try c.require(.watts)
        cpu = c.number(.cpu) ?? 0
        gpu = c.number(.gpu) ?? 0
        rest = c.number(.rest) ?? 0
        losses = c.number(.losses) ?? 0
        cpuMeasured = c.flag(.cpuMeasured) ?? false
        gpuMeasured = c.flag(.gpuMeasured) ?? false
        gpuEstimated = c.flag(.gpuEstimated) ?? false
    }
}

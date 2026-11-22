import Foundation

/// The electricity price saved on the hub (`validEnergySettings` in server.js). It is shared by
/// every dashboard; the hub answers `null` until someone saves one.
///
/// Also the body of `PUT /api/energy/settings`: a flat rate leaves `tou` out.
public struct EnergySettings: Codable, Sendable, Hashable {
    /// A price region ("US", "US-CA", "DE") or "custom".
    public var region: String
    /// Price per kWh in `currency`. With time-of-use periods, the price of every other hour.
    public var rate: Double
    /// ISO 4217 code, three capital letters.
    public var currency: String
    /// Time-of-use periods, in the hub's local time; empty for a flat rate.
    public var tou: [TouPeriod]

    public init(region: String, rate: Double, currency: String, tou: [TouPeriod] = []) {
        self.region = region
        self.rate = rate
        self.currency = currency
        self.tou = tou
    }

    private enum CodingKeys: String, CodingKey {
        case region, rate, currency, tou
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        region = try c.require(.region)
        rate = try c.require(.rate)
        currency = try c.require(.currency)
        tou = c.list(.tou)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(region, forKey: .region)
        try c.encode(rate, forKey: .rate)
        try c.encode(currency, forKey: .currency)
        if !tou.isEmpty { try c.encode(tou, forKey: .tou) }
    }

    public var isTimeOfUse: Bool { !tou.isEmpty }
}

/// A time-of-use period: local hours 0–24 in quarter-hour steps, `from < to`.
public struct TouPeriod: Codable, Sendable, Hashable {
    public var from: Double
    public var to: Double
    public var rate: Double

    public init(from: Double, to: Double, rate: Double) {
        self.from = from
        self.to = to
        self.rate = rate
    }
}

/// `GET /api/energy?bounds=…`: energy, cost and usage per device over the buckets the caller chose.
public struct EnergyResponse: Codable, Sendable, Equatable {
    /// Bucket edges (ms since 1970), as requested: one more than there are buckets.
    public var bounds: [Double]
    public var settings: EnergySettings?
    public var devices: [UsageSummary]

    public init(bounds: [Double] = [], settings: EnergySettings? = nil, devices: [UsageSummary] = []) {
        self.bounds = bounds
        self.settings = settings
        self.devices = devices
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        bounds = c.alignedNumbers(.bounds) ?? []
        settings = c.optional(.settings)
        devices = c.list(.devices)
    }
}

/// One device's totals (`usageSummary` in server.js).
public struct UsageSummary: Codable, Sendable, Equatable, Identifiable {
    public struct Stat: Codable, Sendable, Hashable {
        public var avg: Double
        /// nil when the stored history kept no peaks for this series.
        public var peak: Double?

        public init(avg: Double, peak: Double? = nil) {
            self.avg = avg
            self.peak = peak
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            avg = try c.require(.avg)
            peak = c.number(.peak)
        }
    }

    /// Averages and peaks over the whole range; a series the device never reported is nil.
    public struct Stats: Codable, Sendable, Hashable {
        /// Watts.
        public var power: Stat?
        /// Percent.
        public var cpu: Stat?
        public var gpu: Stat?
        public var mem: Stat?
        /// Degrees Celsius.
        public var cpuTemp: Stat?
        public var gpuTemp: Stat?

        public init(
            power: Stat? = nil, cpu: Stat? = nil, gpu: Stat? = nil, mem: Stat? = nil,
            cpuTemp: Stat? = nil, gpuTemp: Stat? = nil
        ) {
            self.power = power
            self.cpu = cpu
            self.gpu = gpu
            self.mem = mem
            self.cpuTemp = cpuTemp
            self.gpuTemp = gpuTemp
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            power = c.optional(.power)
            cpu = c.optional(.cpu)
            gpu = c.optional(.gpu)
            mem = c.optional(.mem)
            cpuTemp = c.optional(.cpuTemp)
            gpuTemp = c.optional(.gpuTemp)
        }
    }

    /// Bytes moved over the whole range: network down / up, disk read / written.
    public struct Bytes: Codable, Sendable, Hashable {
        public var rx: Double
        public var tx: Double
        public var dr: Double
        public var dw: Double

        public init(rx: Double = 0, tx: Double = 0, dr: Double = 0, dw: Double = 0) {
            self.rx = rx
            self.tx = tx
            self.dr = dr
            self.dw = dw
        }

        public init(from decoder: Decoder) throws {
            let c = try WireFields(decoder, CodingKeys.self)
            rx = c.number(.rx) ?? 0
            tx = c.number(.tx) ?? 0
            dr = c.number(.dr) ?? 0
            dw = c.number(.dw) ?? 0
        }
    }

    public var id: String
    /// Watt-hours over the whole range.
    public var wh: Double
    /// Watt-hours per bucket.
    public var buckets: [Double]
    /// Cost in the saved currency; nil while no price is saved (the dashboard then applies its
    /// guessed flat rate to `wh`).
    public var cost: Double?
    public var costBuckets: [Double]?
    /// Minutes with data, i.e. time online.
    public var minutes: Int
    /// Of those, minutes whose power the hub had to estimate from load.
    public var estimatedMinutes: Int
    public var stats: Stats
    public var bytes: Bytes
    /// Time of the first data point in range, or nil when there is none.
    public var firstData: Double?

    public init(
        id: String, wh: Double = 0, buckets: [Double] = [], cost: Double? = nil, costBuckets: [Double]? = nil,
        minutes: Int = 0, estimatedMinutes: Int = 0, stats: Stats = Stats(), bytes: Bytes = Bytes(),
        firstData: Double? = nil
    ) {
        self.id = id
        self.wh = wh
        self.buckets = buckets
        self.cost = cost
        self.costBuckets = costBuckets
        self.minutes = minutes
        self.estimatedMinutes = estimatedMinutes
        self.stats = stats
        self.bytes = bytes
        self.firstData = firstData
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        id = try c.require(.id)
        wh = c.number(.wh) ?? 0
        buckets = c.alignedNumbers(.buckets) ?? []
        cost = c.number(.cost)
        costBuckets = c.alignedNumbers(.costBuckets)
        minutes = c.integer(.minutes) ?? 0
        estimatedMinutes = c.integer(.estimatedMinutes) ?? 0
        stats = c.optional(.stats) ?? Stats()
        bytes = c.optional(.bytes) ?? Bytes()
        firstData = c.number(.firstData)
    }

    public var firstDataDate: Date? { firstData.map(Date.init(hubTime:)) }
}

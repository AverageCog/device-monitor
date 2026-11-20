import Foundation

/// One point of a device's history (history.js): a raw sample from a report, a one-minute average,
/// or a wider bucket. Raw samples carry only the averages; aggregated points add the peak within
/// the bucket as `<field>Max`. Any value is nil when there was nothing to measure.
public struct HistoryPoint: Codable, Sendable, Hashable {
    /// The series a point carries (`FIELDS` in history.js).
    public enum Metric: String, Sendable, CaseIterable, Codable {
        case cpu, gpu, mem, cpuTemp, gpuTemp, gpuPower, power, rx, tx, dr, dw
    }

    /// Bucket start (ms since 1970), or the moment of a raw sample.
    public var t: Double
    /// Percent.
    public var cpu: Double?
    public var gpu: Double?
    public var mem: Double?
    /// Degrees Celsius.
    public var cpuTemp: Double?
    public var gpuTemp: Double?
    /// Watts.
    public var gpuPower: Double?
    public var power: Double?
    /// Bytes per second: network down / up, disk read / write.
    public var rx: Double?
    public var tx: Double?
    public var dr: Double?
    public var dw: Double?
    public var cpuMax: Double?
    public var gpuMax: Double?
    public var cpuTempMax: Double?
    public var gpuTempMax: Double?
    public var powerMax: Double?
    /// Samples behind a stored one-minute point.
    public var n: Int?

    public init(
        t: Double, cpu: Double? = nil, gpu: Double? = nil, mem: Double? = nil, cpuTemp: Double? = nil,
        gpuTemp: Double? = nil, gpuPower: Double? = nil, power: Double? = nil, rx: Double? = nil,
        tx: Double? = nil, dr: Double? = nil, dw: Double? = nil, cpuMax: Double? = nil, gpuMax: Double? = nil,
        cpuTempMax: Double? = nil, gpuTempMax: Double? = nil, powerMax: Double? = nil, n: Int? = nil
    ) {
        self.t = t
        self.cpu = cpu
        self.gpu = gpu
        self.mem = mem
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.gpuPower = gpuPower
        self.power = power
        self.rx = rx
        self.tx = tx
        self.dr = dr
        self.dw = dw
        self.cpuMax = cpuMax
        self.gpuMax = gpuMax
        self.cpuTempMax = cpuTempMax
        self.gpuTempMax = gpuTempMax
        self.powerMax = powerMax
        self.n = n
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        t = try c.require(.t)
        cpu = c.number(.cpu)
        gpu = c.number(.gpu)
        mem = c.number(.mem)
        cpuTemp = c.number(.cpuTemp)
        gpuTemp = c.number(.gpuTemp)
        gpuPower = c.number(.gpuPower)
        power = c.number(.power)
        rx = c.number(.rx)
        tx = c.number(.tx)
        dr = c.number(.dr)
        dw = c.number(.dw)
        cpuMax = c.number(.cpuMax)
        gpuMax = c.number(.gpuMax)
        cpuTempMax = c.number(.cpuTempMax)
        gpuTempMax = c.number(.gpuTempMax)
        powerMax = c.number(.powerMax)
        n = c.integer(.n)
    }

    public var date: Date { Date(hubTime: t) }

    /// `p[key]` in the dashboard's chart code.
    public func value(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpu
        case .gpu: gpu
        case .mem: mem
        case .cpuTemp: cpuTemp
        case .gpuTemp: gpuTemp
        case .gpuPower: gpuPower
        case .power: power
        case .rx: rx
        case .tx: tx
        case .dr: dr
        case .dw: dw
        }
    }

    /// `p[key + 'Max']`: the peak within the bucket, for the series that keep one.
    public func peak(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpuMax
        case .gpu: gpuMax
        case .cpuTemp: cpuTempMax
        case .gpuTemp: gpuTempMax
        case .power: powerMax
        case .mem, .gpuPower, .rx, .tx, .dr, .dw: nil
        }
    }
}

/// `GET /api/history/<id>`.
public struct HistoryResponse: Codable, Sendable, Equatable {
    public var from: Double
    public var to: Double
    /// Width of one point in milliseconds: 2000 for raw samples, 60000 for minute averages, more
    /// for wider buckets. The dashboard falls back to a minute when it is missing.
    public var resolution: Double
    public var points: [HistoryPoint]

    public init(from: Double, to: Double, resolution: Double = 60_000, points: [HistoryPoint] = []) {
        self.from = from
        self.to = to
        self.resolution = resolution
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        let c = try WireFields(decoder, CodingKeys.self)
        from = c.number(.from) ?? 0
        to = c.number(.to) ?? 0
        // loadHistory in public/index.html: `hv.resolution = r.resolution || 60e3`.
        let reported = c.number(.resolution) ?? 0
        resolution = reported > 0 ? reported : 60_000
        points = c.list(.points)
    }

    public var fromDate: Date { Date(hubTime: from) }
    public var toDate: Date { Date(hubTime: to) }
}

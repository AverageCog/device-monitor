import Foundation

/// Which colour of the dashboard's palette something is drawn in. The models name the role; the
/// app's theme owns the colour.
public enum MetricTint: String, Sendable, Hashable, CaseIterable {
    /// `--cpu`: CPU series, and the first series of a two-series chart (download, disk read).
    case cpu
    /// `--gpu`: GPU series, VRAM, and the second series of a two-series chart (upload, disk write).
    case gpu
    /// `--mem`: memory.
    case mem
    /// `--text-secondary`: a bar that belongs to no series (drive usage).
    case secondary

    /// The custom property the dashboard's style sheet keeps this colour in.
    public var cssVariable: String {
        switch self {
        case .cpu: "--cpu"
        case .gpu: "--gpu"
        case .mem: "--mem"
        case .secondary: "--text-secondary"
        }
    }
}

/// One cell of a stats grid (function stat in public/index.html): a caption, a value and, for
/// amounts that fill up, a bar.
public struct DeviceStat: Sendable, Equatable, Identifiable {
    /// Stable within its list: "cpu", "gpu", "vram", "disk", "network", "diskIO" on a card,
    /// "drive-0", "drive-1"… in the details.
    public let id: String
    /// The caption as the dashboard writes it ("CPU", "Disk C:"); its style sheet shows it in capitals.
    public let key: String
    public let value: String
    /// How full the bar is, 0–100. nil when the stat has no bar.
    ///
    /// The dashboard writes the ratio straight into a CSS width, so more than 100 % fills the bar,
    /// and a ratio that is no number at all (a drive whose size is unknown or zero) leaves the
    /// width unset, which also draws the bar full. Both are 100 here.
    public let percent: Double?
    /// Colour of the bar.
    public let tint: MetricTint

    public init(id: String, key: String, value: String, percent: Double? = nil, tint: MetricTint = .secondary) {
        self.id = id
        self.key = key
        self.value = value
        self.percent = percent
        self.tint = tint
    }

    /// A stat with the bar the dashboard would draw for `ratio` (`pct` of function stat).
    init(id: String, key: String, value: String, ratio: Double, tint: MetricTint = .secondary) {
        self.init(id: id, key: key, value: value, percent: ratio.isFinite ? min(100, max(0, ratio)) : 100, tint: tint)
    }
}

/// JavaScript's idea of "is there something here", for the values the dashboard tests that way.
enum DashJS {
    /// `if (x)` for a number: not null, not 0, not NaN.
    static func number(_ x: Double?) -> Double? {
        guard let x, JS.isTruthy(x) else { return nil }
        return x
    }

    /// `if (s)` for a string: not null and not empty.
    static func text(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

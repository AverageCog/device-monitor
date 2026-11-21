import Foundation

/// A device's colour on the Advanced screen: one of eight, handed out in dashboard order and
/// reused from the ninth device on (`DEVICE_COLORS` in public/index.html).
public struct AdvancedSeriesColor: Sendable, Hashable {
    /// Position in the cycle, 0–7. The app's `Theme.deviceSeriesColor(at:)` takes this.
    public let index: Int

    /// The dashboard's name for it: a CSS variable ("--cpu") or a literal ("#4fb3bf").
    public var token: String { Self.tokens[index].token }
    /// The colour itself, 0xRRGGBB.
    public var hex: UInt32 { Self.tokens[index].hex }

    private static let tokens: [(token: String, hex: UInt32)] = [
        ("--cpu", 0x3987E5), ("--gpu", 0xD95926), ("--mem", 0x199E70), ("--accent", 0x9085E9),
        ("--warning", 0xFAB219), ("--serious", 0xEC835A), ("#4fb3bf", 0x4FB3BF), ("#c97fd0", 0xC97FD0),
    ]

    /// The whole cycle, in order.
    public static let cycle: [AdvancedSeriesColor] = tokens.indices.map(AdvancedSeriesColor.init(index:))

    /// The colour of the device at `position` in dashboard order.
    public static func color(at position: Int) -> AdvancedSeriesColor {
        cycle[((position % cycle.count) + cycle.count) % cycle.count]
    }
}

/// The "Energy per hour" / "Energy per day" chart: stacked bars, one per bucket, a segment per
/// device (function drawAdvChart).
public struct AdvancedChart: Sendable, Equatable {
    /// The canvas margins the dashboard draws with, and the opacity of the bars that are not
    /// under the pointer.
    public enum Layout {
        public static let left = 58.0
        public static let right = 10.0
        public static let top = 8.0
        public static let bottom = 22.0
        public static let dimmedOpacity = 0.45
        public static let maxBarWidth = 48.0
        public static let minBarWidth = 2.0
    }

    /// One device's part of a bar.
    public struct Segment: Sendable, Hashable {
        public let deviceID: String
        public let name: String
        public let color: AdvancedSeriesColor
        public let kWh: Double
        /// `kWh` as a share of the axis maximum: the segment's height in units of the plot height.
        public let fraction: Double
    }

    public struct TooltipRow: Sendable, Hashable, Identifiable {
        public let deviceID: String
        public let name: String
        public let color: AdvancedSeriesColor
        /// "32.0 kWh"
        public let energy: String
        /// "$10.13"
        public let cost: String

        public var id: String { deviceID }
    }

    /// What the dashboard shows when a bar is hovered.
    public struct Tooltip: Sendable, Hashable {
        /// "Wednesday, Nov 18", "Fri 2:00 PM–3:00 PM (so far)"
        public let title: String
        /// The devices that used energy in the bucket, in dashboard order.
        public let rows: [TooltipRow]
        /// "Total" row.
        public let totalEnergy: String
        public let totalCost: String

        public static let totalLabel = "Total"
    }

    public struct Bucket: Sendable, Equatable, Identifiable {
        public let index: Int
        /// The bucket's edges, ms since 1970.
        public let start: Double
        public let end: Double
        /// Under the bar: "2 PM", "Fri 20", "Nov 20".
        public let label: String
        /// "Fri 2:00 PM–3:00 PM", "Friday, Nov 20"
        public let longLabel: String
        /// Bottom to top, in dashboard order; devices that used nothing are left out.
        public let segments: [Segment]
        public let totalKWh: Double
        /// The bucket has not ended yet.
        public let isSoFar: Bool
        public let tooltip: Tooltip

        public var id: Int { index }

        /// One sentence for VoiceOver: "Friday, Nov 20 (so far): 37.3 kWh, $11.77".
        public var spokenSummary: String {
            "\(tooltip.title): \(tooltip.totalEnergy), \(tooltip.totalCost)"
        }
    }

    /// A horizontal grid line.
    public struct Tick: Sendable, Hashable {
        public let kWh: Double
        /// Height in units of the plot height: 0, 0.25, 0.5, 0.75, 1.
        public let fraction: Double
        /// "50 kWh" on every second line, nil on the others.
        public let label: String?
        /// The bottom line is drawn in the axis colour, the rest in the grid colour.
        public let isBaseline: Bool
    }

    public let buckets: [Bucket]
    /// The top of the y axis in kWh.
    public let yMax: Double
    /// Five lines, bottom to top.
    public let ticks: [Tick]

    // MARK: Geometry, as the dashboard lays the canvas out

    /// A bucket gets an x label when its index is a multiple of this (`every` in drawAdvChart).
    /// `canvasWidth` is the whole canvas, y-axis gutter included.
    public func labelStride(canvasWidth: Double) -> Int {
        let n = Double(buckets.count)
        let stride = (n / max(2, ((canvasWidth - Layout.left) / 70).rounded(.down))).rounded(.up)
        return stride.isFinite ? max(1, Int(stride)) : 1
    }

    public func showsLabel(at index: Int, canvasWidth: Double) -> Bool {
        index % labelStride(canvasWidth: canvasWidth) == 0
    }

    /// The width each bucket has on the canvas.
    public func slotWidth(canvasWidth: Double) -> Double {
        (canvasWidth - Layout.left - Layout.right) / Double(buckets.count)
    }

    /// 70 % of a slot, between 2 and 48 points.
    public func barWidth(canvasWidth: Double) -> Double {
        max(Layout.minBarWidth, min(Layout.maxBarWidth, slotWidth(canvasWidth: canvasWidth) * 0.7))
    }

    public func barCenterX(at index: Int, canvasWidth: Double) -> Double {
        Layout.left + slotWidth(canvasWidth: canvasWidth) * (Double(index) + 0.5)
    }

    /// The bucket under `x` (the dashboard's pointermove handler), nil outside the plot.
    public func bucketIndex(atX x: Double, canvasWidth: Double) -> Int? {
        let n = buckets.count
        let position = ((x - Layout.left) / ((canvasWidth - Layout.left - Layout.right) / Double(n))).rounded(.down)
        guard position >= 0, position < Double(n) else { return nil }
        return Int(position)
    }

    /// Where the dashboard puts a tooltip's left edge: 14 points right of the bar's centre, or
    /// left of it when it would not fit.
    public func tooltipLeft(at index: Int, canvasWidth: Double, tooltipWidth: Double) -> Double {
        let cx = barCenterX(at: index, canvasWidth: canvasWidth)
        return cx + 14 + tooltipWidth > canvasWidth ? cx - tooltipWidth - 14 : cx + 14
    }
}

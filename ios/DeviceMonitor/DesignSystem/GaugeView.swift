import SwiftUI

/// The 270° arc gauge of a device card, ported from `gaugeSvg()` / `setGauge()` in public/index.html.
///
/// Geometry follows the SVG's 100 × 98 view box: radius 40 around (50, 50), stroke 7 with round caps,
/// starting bottom-left and sweeping clockwise; the value sits in the middle and the label in the
/// opening of the arc.
struct GaugeView: View {
    private let value: Double?
    private let label: String
    private let color: Color

    @ScaledMetric(relativeTo: .title3) private var maxDiameter: CGFloat = 88
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - value: Percentage, 0–100. `nil` shows an en dash and an empty arc.
    ///   - label: Shown uppercase under the value, e.g. "CPU".
    ///   - color: Colour of the filled arc.
    init(value: Double?, label: String, color: Color) {
        self.value = value
        self.label = label
        self.color = color
    }

    private var fraction: Double {
        guard let value, value.isFinite else { return 0 }
        return min(100, max(0, value)) / 100
    }

    /// What VoiceOver reads for a gauge showing `value`.
    nonisolated static func spokenValue(for value: Double?) -> String {
        guard let value, value.isFinite else { return "No reading" }
        return Theme.percentText(value)
    }

    var body: some View {
        Color.clear
            .aspectRatio(100.0 / 98.0, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let unit = proxy.size.width / 100
                    let stroke = StrokeStyle(lineWidth: 7 * unit, lineCap: .round)
                    ZStack {
                        GaugeArc(fraction: 1)
                            .stroke(Theme.grid, style: stroke)
                        // Never quite empty, so 0 % still shows the round cap as a dot (as the SVG does).
                        GaugeArc(fraction: max(0.0004, fraction))
                            .stroke(color, style: stroke)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: fraction)
                        Text(Theme.percentText(value))
                            .font(.system(size: 26 * unit, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 64 * unit)
                            .position(x: 50 * unit, y: 45 * unit)
                        Text(label)
                            .font(.system(size: 13 * unit))
                            .tracking(13 * unit * 0.08)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 100 * unit)
                            .position(x: 50 * unit, y: 90.5 * unit)
                    }
                }
            }
            .frame(maxWidth: maxDiameter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(Self.spokenValue(for: value))
    }
}

/// The gauge's arc: `fraction` of the 270° sweep, drawn in the SVG's coordinate system.
nonisolated struct GaugeArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 100
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.minX + 50 * unit, y: rect.minY + 50 * unit),
            radius: 40 * unit,
            startAngle: .degrees(135),
            endAngle: .degrees(135 + 270 * min(1, max(0, fraction))),
            clockwise: false
        )
        return path
    }
}

/// What a device card shows under a gauge (`.gauge-sub`).
nonisolated enum GaugeCaption: Equatable, Sendable {
    /// A temperature pill: the formatted temperature and how hot that is.
    case temperature(String, TempLevel)
    /// A muted note in place of a reading: "no sensor", "no GPU", "offline".
    case hint(String)
    /// Plain secondary text, e.g. "27.6 / 60 GB".
    case text(String)
    /// Nothing, keeping the row's height.
    case none

    /// What VoiceOver reads for the caption, after the gauge's own reading.
    var spokenText: String? {
        switch self {
        case let .temperature(text, level): TempPill.spokenValue(text, level: level)
        case let .hint(text), let .text(text): text
        case .none: nil
        }
    }
}

/// A gauge with its caption underneath: one column of a card's gauge row (`.gauge`).
///
/// VoiceOver gets the column as one element, "CPU, 28%, 59°C, Normal": read on its own, a caption
/// does not say which gauge it belongs to.
struct GaugeColumn: View {
    private let value: Double?
    private let label: String
    private let color: Color
    private let caption: GaugeCaption

    @ScaledMetric(relativeTo: .caption2) private var captionMinHeight: CGFloat = 22

    init(value: Double?, label: String, color: Color, caption: GaugeCaption = .none) {
        self.value = value
        self.label = label
        self.color = color
        self.caption = caption
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            GaugeView(value: value, label: label, color: color)
            Group {
                switch caption {
                case let .temperature(text, level):
                    TempPill(text, level: level)
                case let .hint(text):
                    GaugeHint(text)
                case let .text(text):
                    Text(text)
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                case .none:
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            .frame(minHeight: captionMinHeight)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([GaugeView.spokenValue(for: value), caption.spokenText].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The three gauges of a device card, in equal columns (`.gauges`).
struct GaugeRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            content
        }
    }
}

#Preview("Gauges") {
    VStack(spacing: 24) {
        GaugeRow {
            GaugeColumn(value: 28, label: "CPU", color: Theme.cpu, caption: .temperature("59°C", .normal))
            GaugeColumn(value: 81, label: "GPU", color: Theme.gpu, caption: .temperature("75°C", .warm))
            GaugeColumn(value: 46, label: "Memory", color: Theme.mem, caption: .text("27.6 / 60 GB"))
        }
        GaugeRow {
            GaugeColumn(value: 0, label: "CPU", color: Theme.cpu, caption: .hint("offline"))
            GaugeColumn(value: nil, label: "GPU", color: Theme.gpu, caption: .hint("no GPU"))
            GaugeColumn(value: 100, label: "Memory", color: Theme.mem, caption: .text("30 / 30 GB"))
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.surface1)
    .preferredColorScheme(.dark)
}

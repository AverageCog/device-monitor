import SwiftUI

/// How hot a temperature reading is: the three states of `tempStatus()` in public/index.html.
/// Classifying a reading (below 70 °C, below 85 °C, hotter) is DMCore's job; this is only the look.
nonisolated enum TempLevel: String, Equatable, Sendable, CaseIterable {
    case normal, warm, hot

    var color: Color {
        switch self {
        case .normal: Theme.good
        case .warm: Theme.warning
        case .hot: Theme.critical
        }
    }

    /// "Normal", "Warm" or "Hot".
    var name: String {
        switch self {
        case .normal: "Normal"
        case .warm: "Warm"
        case .hot: "Hot"
        }
    }

    /// The word shown inside the pill. A normal reading shows none.
    var word: String? { self == .normal ? nil : name }
}

/// A temperature reading as a pill: status dot, the formatted temperature and, when it is not
/// normal, the quiet word "Warm" or "Hot" (`tempPill()` in public/index.html).
struct TempPill: View {
    private let text: String
    private let level: TempLevel
    private let note: String?

    @ScaledMetric(relativeTo: .caption2) private var dotSize: CGFloat = 7

    /// - Parameters:
    ///   - text: The formatted temperature, e.g. "75°C".
    ///   - level: Picks the dot colour and the word.
    ///   - note: Extra context for VoiceOver, e.g. "ACPI sensor" (the dashboard's tooltip).
    init(_ text: String, level: TempLevel, note: String? = nil) {
        self.text = text
        self.level = level
        self.note = note
    }

    /// "75°C, Warm": what VoiceOver reads for a pill. The level is spoken even when it is normal,
    /// because the dot's colour is the only place the pill shows it.
    nonisolated static func spokenValue(_ text: String, level: TempLevel, note: String? = nil) -> String {
        [text, level.name, note].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(level.color)
                .frame(width: dotSize, height: dotSize)
            Text(text)
                .dmFont(.caption)
                .foregroundStyle(Theme.textPrimary)
            if let word = level.word {
                Text(word)
                    .dmFont(.micro)
                    .foregroundStyle(Theme.textMutedOnSurface2)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.surface2, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature")
        .accessibilityValue(Self.spokenValue(text, level: level, note: note))
    }
}

/// The muted note shown where a reading is missing: "no sensor", "no GPU", "offline" (`.hint`).
struct GaugeHint: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .dmFont(.caption)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
    }
}

/// The online / offline dot in front of a device name (`.dot`): green with a soft ring, or muted.
struct StatusDot: View {
    private let isOnline: Bool
    private let size: CGFloat

    init(isOnline: Bool, size: CGFloat = 8) {
        self.isOnline = isOnline
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(isOnline ? Theme.good : Theme.textMuted)
            .frame(width: size, height: size)
            .background {
                if isOnline {
                    // box-shadow: 0 0 0 3px — a ring that does not take part in layout.
                    Circle().fill(Theme.good.opacity(0.18)).padding(-3)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

#Preview("Pills and dots") {
    VStack(spacing: 14) {
        HStack(spacing: 12) {
            TempPill("59°C", level: .normal)
            TempPill("75°C", level: .warm)
            TempPill("91°C", level: .hot)
        }
        HStack(spacing: 16) {
            GaugeHint("no sensor")
            GaugeHint("no GPU")
            GaugeHint("offline")
        }
        HStack(spacing: 20) {
            StatusDot(isOnline: true)
            StatusDot(isOnline: false)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.surface1)
    .preferredColorScheme(.dark)
}

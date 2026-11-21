import SwiftUI

/// The text styles of the dashboard, sized for a phone. Each one scales with Dynamic Type.
///
/// Sizes are the CSS sizes plus roughly 9 %: a card that is 336 px wide in a narrow browser is
/// about 370 pt wide on an iPhone, and nothing drops below 10 pt.
nonisolated enum DMTextStyle: Sendable, CaseIterable {
    /// Title of a page section such as the selected device in History (`.hv-head h2`).
    case screenTitle
    /// Title of an empty state (`.empty h2`).
    case emptyTitle
    /// Device name on a card (`.name`).
    case cardTitle
    /// Title of a chart panel (`.hv-chart h3`) and of an app row in a list (`.ai-app`).
    case panelTitle
    /// Title of a settings row (`.set-k`).
    case rowTitle
    /// Running text, buttons.
    case body
    case bodyStrong
    /// Key–value rows, row descriptions (`.kv`, `.set-v`).
    case callout
    /// Value of a stat cell (`.stat .v`), segmented control and chip labels.
    case statValue
    /// Card sub line, hints, legends, tile sub lines, tooltips.
    case caption
    case captionStrong
    /// The quiet word in a pill and other tiny annotations (`.pill small`).
    case micro
    /// Key of a stat cell and of a tile: uppercase, letter-spaced (`.stat .k`, `.tile .k`).
    case statKey
    /// In-card section heading: uppercase, letter-spaced, semibold (`.section h4`).
    case sectionLabel
    /// Page-level section heading (`.adv-h`).
    case sectionHeader
    /// The big number of a tile (`.tile .v`).
    case tileValue
    /// Chart axis labels.
    case axis
    /// Addresses, invitations and commands (`.set-v.mono`, `.cmd code`).
    case mono

    var size: CGFloat {
        switch self {
        case .screenTitle: 20
        case .emptyTitle: 21
        case .cardTitle: 16
        case .panelTitle: 14
        case .rowTitle: 15
        case .body, .bodyStrong: 15
        case .callout: 14
        case .statValue: 13
        case .caption, .captionStrong: 12
        case .micro: 11
        case .statKey: 11
        case .sectionLabel: 12
        case .sectionHeader: 13
        case .tileValue: 22
        case .axis: 10
        case .mono: 13
        }
    }

    var weight: Font.Weight {
        switch self {
        case .screenTitle, .emptyTitle, .cardTitle, .panelTitle, .rowTitle, .bodyStrong, .captionStrong,
             .sectionLabel, .sectionHeader, .tileValue:
            .semibold
        default:
            .regular
        }
    }

    /// Letter spacing as a fraction of the font size (CSS `letter-spacing` in em).
    var tracking: CGFloat {
        switch self {
        case .statKey, .sectionLabel, .sectionHeader: 0.06
        default: 0
        }
    }

    var isUppercase: Bool {
        switch self {
        case .statKey, .sectionLabel, .sectionHeader: true
        default: false
        }
    }

    /// The Dynamic Type style this one grows with.
    var relativeTo: Font.TextStyle {
        switch self {
        case .screenTitle, .emptyTitle, .tileValue: .title3
        case .cardTitle, .panelTitle, .rowTitle: .headline
        case .body, .bodyStrong: .body
        case .callout, .statValue, .mono: .callout
        case .caption, .captionStrong, .sectionHeader: .footnote
        case .micro, .statKey, .sectionLabel, .axis: .caption2
        }
    }

    /// The styles the dashboard sets in tabular digits (`font-variant-numeric: tabular-nums`): values
    /// in right-aligned columns and big numbers that update in place, which must not shift.
    var usesTabularDigits: Bool {
        switch self {
        case .callout, .tileValue, .axis: true
        default: false
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .mono:
            .system(size: size, weight: weight, design: .monospaced)
        default:
            usesTabularDigits ? .system(size: size, weight: weight).monospacedDigit() : .system(size: size, weight: weight)
        }
    }
}

private struct DMFontModifier: ViewModifier {
    let style: DMTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: DMTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(style.font(size: size))
            .tracking(size * style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a dashboard text style: font, digit style, letter spacing and case. Colour is separate.
    func dmFont(_ style: DMTextStyle) -> some View {
        modifier(DMFontModifier(style: style))
    }
}

#Preview("Text styles") {
    ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(DMTextStyle.allCases.enumerated()), id: \.offset) { _, style in
                Text("\(String(describing: style)) 0123456789")
                    .dmFont(style)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Theme.page)
}

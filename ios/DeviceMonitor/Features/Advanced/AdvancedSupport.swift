import DMCore
import SwiftUI
import UIKit

/// The few words of this screen that `AdvancedModel` does not have, because the dashboard does
/// not: it keeps quiet when its totals cannot be loaded, and it has no rows that open.
nonisolated enum AdvancedStrings {
    /// `title="Time range"` of #advRange.
    static let timeRange = "Time range"
    /// Nothing was loaded for this range.
    static let loadFailed = "Totals are not available."
    /// An earlier answer is still on show.
    static let refreshFailed = "These totals may be out of date."
    /// The wording of the unreachable screen's button.
    static let retry = "Try again"
    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
}

/// The parts of the page that can be scrolled to.
nonisolated enum AdvancedSection: String, Hashable, Sendable {
    case top, electricity, chart, power, usage, note
}

/// Why the totals on show are missing or old.
nonisolated struct AdvancedLoadFailure: Equatable, Sendable {
    /// The hub's or the transport's own words.
    let reason: String
    /// Totals from an earlier answer are still on show.
    let hasTotals: Bool

    var message: String {
        let lead = hasTotals ? AdvancedStrings.refreshFailed : AdvancedStrings.loadFailed
        return reason.isEmpty ? lead : "\(lead) \(reason)"
    }
}

nonisolated extension AdvancedModel.Tile.Kind {
    /// The last part of the tile's accessibility identifier.
    var identifier: String {
        switch self {
        case .drawingNow: "drawing-now"
        case .energyUsed: "energy-used"
        case .cost: "cost"
        case .perMonth: "per-month"
        }
    }
}

nonisolated extension AdvancedSeriesColor {
    var color: Color { Theme.deviceSeriesColor(at: index) }
}

// MARK: - Measuring text

/// Widths of table texts, measured before layout so that a table's columns can be sized as a
/// whole: every row gets the same widths, and whether the table fits at all is known up front.
enum AdvancedTextMeasure {
    /// The width of `text` on one line in a design-system style at `size` points (the style's
    /// size at the current text size).
    static func width(of text: String, style: DMTextStyle, size: CGFloat, weight: Font.Weight? = nil) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let weight = uiWeight(weight ?? style.weight)
        let font = style.usesTabularDigits
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if style.tracking != 0 { attributes[.kern] = size * style.tracking }
        let shown = style.isUppercase ? text.uppercased() : text
        // A point to spare: SwiftUI and TextKit round a line's width differently.
        return ((shown as NSString).size(withAttributes: attributes).width).rounded(.up) + 1
    }

    /// The narrowest column `text` fits in on two lines without a word being cut.
    static func twoLineWidth(of text: String, style: DMTextStyle, size: CGFloat, weight: Font.Weight? = nil) -> CGFloat {
        let words = text.split(separator: " ")
        var best = width(of: text, style: style, size: size, weight: weight)
        guard words.count > 1 else { return best }
        for cut in 1..<words.count {
            let first = width(of: words[..<cut].joined(separator: " "), style: style, size: size, weight: weight)
            let second = width(of: words[cut...].joined(separator: " "), style: style, size: size, weight: weight)
            best = min(best, max(first, second))
        }
        return best
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .semibold: .semibold
        case .bold: .bold
        case .medium: .medium
        default: .regular
        }
    }
}

// MARK: - Table columns

/// One column of a table, by the widths it can do with.
nonisolated struct AdvancedTableColumn: Sendable, Equatable {
    /// Everything on one line.
    var natural: CGFloat
    /// What it can come down to at no cost to its figures: a heading or a phrase on two lines.
    var wrapped: CGFloat
    /// The least it can do with, something being lost: a name cut short, a shorter bar.
    var minimum: CGFloat

    init(natural: CGFloat, wrapped: CGFloat? = nil, minimum: CGFloat? = nil) {
        self.natural = natural
        self.wrapped = min(wrapped ?? natural, natural)
        self.minimum = min(minimum ?? self.wrapped, self.wrapped)
    }
}

nonisolated enum AdvancedTableFit {
    /// Column widths that fill `available` exactly, or nil when the table does not fit even with
    /// every column at its minimum (the caller then shows cards instead).
    ///
    /// Spare room is shared in proportion, as a `width: 100%` table does in a browser. A shortage
    /// is first taken from the columns that can wrap, and only then from those that lose something.
    static func widths(of columns: [AdvancedTableColumn], in available: CGFloat, spacing: CGFloat) -> [CGFloat]? {
        let room = available - spacing * CGFloat(max(0, columns.count - 1))
        let natural = columns.reduce(0) { $0 + $1.natural }
        let wrapped = columns.reduce(0) { $0 + $1.wrapped }
        let minimum = columns.reduce(0) { $0 + $1.minimum }
        guard natural > 0, room >= minimum else { return nil }
        if room >= natural {
            let growth = room / natural
            return columns.map { $0.natural * growth }
        }
        if room >= wrapped {
            let share = natural > wrapped ? (natural - room) / (natural - wrapped) : 0
            return columns.map { $0.natural - ($0.natural - $0.wrapped) * share }
        }
        let share = wrapped > minimum ? (wrapped - room) / (wrapped - minimum) : 0
        return columns.map { $0.wrapped - ($0.wrapped - $0.minimum) * share }
    }
}

/// Shared measures of the two tables.
nonisolated enum AdvancedTableMetrics {
    /// Between columns. Tighter than the dashboard's 28: an iPad held upright is 700 points wide.
    static let columnSpacing: CGFloat = 12
    /// `padding: 9px 14px` of a cell.
    static let rowPadding: CGFloat = 14
    static let cellPadding: CGFloat = 10
    /// The square before a device's name (`td:first-child i`).
    static let swatch: CGFloat = 9
    static let swatchSpacing: CGFloat = 8
    /// The margin at the end of a table whose rows open: it holds their disclosure chevron.
    static let disclosurePadding: CGFloat = 22
    /// Width of the share bar (`.share`), and the least it may shrink to in a tight table.
    static let shareBar: CGFloat = 60
    static let shareBarMinimum: CGFloat = 36
    /// A device name is cut short beyond this (at the default text size) before a table gives up.
    static let nameMinimum: CGFloat = 84
    /// Gap between cards, and between the cells inside one.
    static let cardSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let metricSpacing: CGFloat = 12
    /// The narrowest card that still reads well; more than one column of cards from twice this.
    static let cardMinWidth: CGFloat = 330

    /// How many cards fit side by side.
    static func cardColumns(in width: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((width + cardSpacing) / (cardMinWidth * scale + cardSpacing)))
    }

    /// How many label-over-value cells of at least `cellWidth` fit side by side in a card.
    static func metricColumns(in cardWidth: CGFloat, cellWidth: CGFloat, atMost limit: Int) -> Int {
        let inner = cardWidth - 2 * cardPadding
        return min(limit, max(1, Int((inner + metricSpacing) / (cellWidth + metricSpacing))))
    }
}

/// One row of a table: cells of the given widths, left to right.
struct AdvancedTableRow<Cell: View>: View {
    let widths: [CGFloat]
    /// Columns whose content starts at the leading edge; the rest are right-aligned, as figures are.
    var leading: Set<Int> = [0]
    var alignment: VerticalAlignment = .firstTextBaseline
    var trailingPadding: CGFloat = AdvancedTableMetrics.rowPadding
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        HStack(alignment: alignment, spacing: AdvancedTableMetrics.columnSpacing) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                cell(index)
                    .frame(width: max(0, width), alignment: leading.contains(index) ? .leading : .trailing)
            }
        }
        .padding(.leading, AdvancedTableMetrics.rowPadding)
        .padding(.trailing, trailingPadding)
    }
}

nonisolated enum AdvancedDisclosure: Sendable {
    /// The row does not open.
    case unavailable
    case collapsed
    case expanded
}

/// The small chevron of a row that opens.
struct AdvancedChevron: View {
    let state: AdvancedDisclosure

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .rotationEffect(.degrees(state == .expanded ? 180 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state)
            .opacity(state == .unavailable ? 0 : 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Pieces of a row

/// The coloured square that ties a device's row to its bars in the chart.
struct AdvancedSwatch: View {
    let color: AdvancedSeriesColor

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.color)
            .frame(width: AdvancedTableMetrics.swatch, height: AdvancedTableMetrics.swatch)
            .accessibilityHidden(true)
    }
}

/// A device's name behind its colour (`td:first-child`).
struct AdvancedDeviceName: View {
    let name: String
    let color: AdvancedSeriesColor
    var style: DMTextStyle = .callout

    var body: some View {
        HStack(spacing: AdvancedTableMetrics.swatchSpacing) {
            AdvancedSwatch(color: color)
            Text(name)
                .dmFont(style)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A figure under its column's heading: how a card shows what a table shows in a cell.
struct AdvancedMetric<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .dmFont(.statKey)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            value
                .dmFont(.callout)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // The figures of a row of cells share a baseline even when one heading takes two lines.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

extension AdvancedMetric where Value == Text {
    init(_ label: String, _ value: String, isMuted: Bool = false) {
        self.init(label: label) {
            Text(value).foregroundStyle(isMuted ? Theme.textMuted : Theme.textPrimary)
        }
    }
}

/// Two figures the dashboard writes as "36% / 84%", the second one muted.
struct AdvancedPairText: View {
    let primary: String
    let secondary: String
    /// " / " between average and peak; a space between time online and its share.
    var separator = " / "

    var body: some View {
        Text("\(primary)\(Text(separator + secondary).foregroundStyle(Theme.textMuted))")
    }
}

/// A panel that says why it has nothing to show ("No power data yet.", "Loading…").
struct AdvancedNotice: View {
    let text: String
    var showsProgress = false

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            Text(text)
                .dmFont(.callout)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AdvancedTableMetrics.rowPadding)
        .padding(.vertical, AdvancedTableMetrics.cellPadding + 2)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .accessibilityElement(children: .combine)
    }
}

/// A row that answers a touch: a quiet plate while pressed, as the dashboard's rows have on hover.
struct AdvancedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : .clear)
            .contentShape(Rectangle())
    }
}

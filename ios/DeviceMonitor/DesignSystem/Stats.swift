import SwiftUI

/// A thin progress bar (`.bar`): grid-coloured track, rounded fill.
struct MeterBar: View {
    private let percent: Double
    private let color: Color
    private let height: CGFloat
    private let label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - percent: 0–100; clamped.
    ///   - color: Fill colour. The dashboard's default is the secondary text colour.
    ///   - height: 4 for stat bars, 6 for the share column of the Advanced table.
    ///   - accessibilityLabel: Give one when the bar stands alone. Without it the bar is decorative,
    ///     because the text next to it already states the value.
    init(percent: Double, color: Color = Theme.textSecondary, height: CGFloat = 4, accessibilityLabel: String? = nil) {
        self.percent = percent
        self.color = color
        self.height = height
        self.label = accessibilityLabel
    }

    var body: some View {
        // One clamped value for the fill and for VoiceOver, so both state what the bar shows.
        let shown = Theme.clampedPercent(percent)
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Theme.Radius.bar)
                .fill(color)
                .frame(width: proxy.size.width * shown / 100)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: shown)
        }
        .frame(height: height)
        .background(Theme.grid)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bar))
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityValue(Theme.percentText(shown))
        .accessibilityHidden(label == nil)
    }
}

/// One cell of a card's stats grid (`stat()` in public/index.html): an uppercase key, a single-line
/// value and, for capacities, a thin bar.
struct StatCell: View {
    private let key: String
    private let value: String
    private let percent: Double?
    private let barColor: Color

    /// - Parameters:
    ///   - percent: Shows a bar filled to this percentage when given (0–100; clamped).
    ///   - barColor: The dashboard uses the GPU colour for VRAM and the default for drives.
    init(_ key: String, value: String, percent: Double? = nil, barColor: Color = Theme.textSecondary) {
        self.key = key
        self.value = value
        self.percent = percent
        self.barColor = barColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .dmFont(.statKey)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Text(value)
                .dmFont(.statValue)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let percent {
                MeterBar(percent: percent, color: barColor)
                    .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key)
        .accessibilityValue(percent.map { "\(value), \(Theme.percentText(Theme.clampedPercent($0)))" } ?? value)
    }
}

/// The two-column grid of stat cells (`.stats`). Falls back to one column at accessibility text sizes.
struct StatsGrid<Content: View>: View {
    private let columns: Int
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(columns: Int = 2, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    var body: some View {
        EqualColumnsLayout(
            columns: dynamicTypeSize.isAccessibilitySize ? 1 : columns,
            columnSpacing: Theme.Spacing.l,
            rowSpacing: 9
        ) {
            content
        }
    }
}

/// Lays children out left to right in equal-width columns, each row as tall as its tallest cell.
/// A CSS grid with `repeat(n, 1fr)`; unlike `LazyVGrid` it sizes itself eagerly, which a card needs.
struct EqualColumnsLayout: Layout {
    var columns: Int = 2
    var columnSpacing: CGFloat = Theme.Spacing.l
    var rowSpacing: CGFloat = 9

    private var columnCount: Int { max(1, columns) }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        max(0, (width - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount))
    }

    private func rowHeights(_ subviews: Subviews, columnWidth: CGFloat) -> [CGFloat] {
        var heights: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            if index % columnCount == 0 {
                heights.append(height)
            } else {
                heights[heights.count - 1] = max(heights[heights.count - 1], height)
            }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * CGFloat(columnCount) + CGFloat(columnCount - 1) * columnSpacing
        }
        let heights = rowHeights(subviews, columnWidth: columnWidth(for: width))
        let height = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellWidth = columnWidth(for: bounds.width)
        let heights = rowHeights(subviews, columnWidth: cellWidth)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let row = index / columnCount, column = index % columnCount
            if column == 0, row > 0 { y += heights[row - 1] + rowSpacing }
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + columnSpacing), y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellWidth, height: heights[row])
            )
        }
    }
}

#Preview("Stats") {
    DMCard {
        StatsGrid {
            StatCell("CPU", value: "AMD Ryzen 9 9950X3D · 5.20 GHz")
            StatCell("GPU", value: "GeForce RTX 5090 · 465 W")
            StatCell("VRAM", value: "23.4 GB / 30 GB", percent: 78, barColor: Theme.gpu)
            StatCell("Disk C:", value: "1 TB / 2 TB", percent: 50)
            StatCell("Network", value: "↓ 1.5 MB/s  ↑ 232 KB/s")
            StatCell("Disk I/O", value: "R 2.9 MB/s  W 5.5 MB/s")
        }
        MeterBar(percent: 67, color: Theme.cpu, height: 6, accessibilityLabel: "Share of energy")
            .frame(width: 60)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}

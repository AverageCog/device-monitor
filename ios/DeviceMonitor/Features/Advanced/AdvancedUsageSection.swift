import DMCore
import SwiftUI

/// Usage (`#advUsage`): time online, CPU, GPU and memory load, peak temperatures, and the bytes
/// moved over the network and the drives, per device.
///
/// A real table where all ten columns fit, which takes about the width of an iPad on its side;
/// one card per device, every figure under its column's heading, where they do not.
struct AdvancedUsageSection: View {
    let controller: AdvancedController
    let width: CGFloat

    @Environment(AppRouter.self) private var router
    @ScaledMetric(relativeTo: .callout) private var cellSize: CGFloat = DMTextStyle.callout.size
    @ScaledMetric(relativeTo: .caption2) private var headerSize: CGFloat = DMTextStyle.statKey.size

    private typealias Metrics = AdvancedTableMetrics

    private static func header(_ index: Int) -> String {
        let headers = AdvancedModel.UsageTable.headers
        return headers.indices.contains(index) ? headers[index] : ""
    }

    var body: some View {
        let table = controller.usage
        if let text = table.emptyText {
            // "Loading…" until the first totals arrive; if they cannot be had, say that instead.
            let failed = controller.isLoading && controller.failure != nil
            AdvancedNotice(text: failed ? AdvancedStrings.loadFailed : text, showsProgress: controller.isLoading && !failed)
                .accessibilityIdentifier("advanced-usage-empty")
        } else if let widths = columnWidths(for: table) {
            tableView(table, widths: widths)
        } else {
            cards(table)
        }
    }

    /// "47 h 30%": time online and its share of the range.
    private static func online(_ row: AdvancedModel.UsageRow) -> String {
        "\(row.online) \(row.onlineShare)"
    }

    /// A row as one sentence: every figure after its column's heading.
    private func spoken(_ row: AdvancedModel.UsageRow) -> String {
        let fields = [
            Self.online(row), row.cpu.text, row.gpu.text, row.memory, row.peakTemperatures.text,
            row.downloaded, row.uploaded, row.diskRead, row.diskWritten,
        ]
        return fields.enumerated()
            .map { "\(Self.header($0.offset + 1)) \($0.element)" }
            .joined(separator: ", ")
    }

    private func historyButton(_ row: AdvancedModel.UsageRow) -> some View {
        Button {
            router.openHistory(deviceID: row.deviceID)
        } label: {
            Label(AppTab.history.title, systemImage: AppTab.history.systemImage)
        }
    }

    // MARK: Table

    /// The widths of the ten columns, or nil when they do not all fit in the page.
    private func columnWidths(for table: AdvancedModel.UsageTable) -> [CGFloat]? {
        let rows = table.rows
        func cell(_ text: String, semibold: Bool = false) -> CGFloat {
            AdvancedTextMeasure.width(of: text, style: .callout, size: cellSize, weight: semibold ? .semibold : nil)
        }
        func widest(_ texts: [String]) -> CGFloat { texts.map { cell($0) }.max() ?? 0 }
        func head(_ index: Int) -> CGFloat {
            AdvancedTextMeasure.width(of: Self.header(index), style: .statKey, size: headerSize)
        }
        // A column of figures: as wide as its widest figure, under a heading that may take two lines.
        func column(_ index: Int, figures: CGFloat) -> AdvancedTableColumn {
            let onTwoLines = AdvancedTextMeasure.twoLineWidth(of: Self.header(index), style: .statKey, size: headerSize)
            return AdvancedTableColumn(natural: max(figures, head(index)), wrapped: max(figures, onTwoLines))
        }
        let scale = cellSize / DMTextStyle.callout.size
        let mark = Metrics.swatch + Metrics.swatchSpacing
        let names = mark + (rows.map { cell($0.name, semibold: true) }.max() ?? 0)
        // Like columns get like widths: the two loads, and the four byte counts.
        let load = max(widest(rows.map(\.cpu.text)), widest(rows.map(\.gpu.text)))
        let bytes = max(
            widest(rows.map(\.downloaded)), widest(rows.map(\.uploaded)), widest(rows.map(\.diskRead)), widest(rows.map(\.diskWritten)))
        let columns = [
            // A long name is cut short before the table gives up, and only then.
            AdvancedTableColumn(natural: max(names, head(0)), minimum: max(head(0), min(names, mark + Metrics.nameMinimum * scale))),
            column(1, figures: widest(rows.map { Self.online($0) })),
            column(2, figures: load),
            column(3, figures: load),
            column(4, figures: widest(rows.map(\.memory))),
            column(5, figures: widest(rows.map(\.peakTemperatures.text))),
            column(6, figures: bytes),
            column(7, figures: bytes),
            column(8, figures: bytes),
            column(9, figures: bytes),
        ]
        return AdvancedTableFit.widths(of: columns, in: width - 2 * Metrics.rowPadding, spacing: Metrics.columnSpacing)
    }

    private func tableView(_ table: AdvancedModel.UsageTable, widths: [CGFloat]) -> some View {
        VStack(spacing: 0) {
            AdvancedTableRow(widths: widths, alignment: .lastTextBaseline) { index in
                Text(Self.header(index))
                    .dmFont(.statKey)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(index == 0 ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Metrics.cellPadding)
            // Each row says its headings itself.
            .accessibilityHidden(true)
            ForEach(table.rows) { row in
                Hairline()
                AdvancedTableRow(widths: widths) { index in
                    cell(row, index)
                }
                .padding(.vertical, Metrics.cellPadding)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .contextMenu { historyButton(row) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.name)
                .accessibilityValue(spoken(row))
                .accessibilityAction(named: AppTab.history.title) { router.openHistory(deviceID: row.deviceID) }
                .accessibilityIdentifier("advanced-usage-row-\(row.deviceID)")
            }
        }
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced-usage")
    }

    @ViewBuilder
    private func cell(_ row: AdvancedModel.UsageRow, _ index: Int) -> some View {
        switch index {
        case 0: AdvancedDeviceName(name: row.name, color: row.color)
        default: figure(row, index).dmFont(.callout).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
    }

    /// The figure of column `index`, 1 to 9, for a table cell or a card alike.
    @ViewBuilder
    private func figure(_ row: AdvancedModel.UsageRow, _ index: Int) -> some View {
        switch index {
        case 1: AdvancedPairText(primary: row.online, secondary: row.onlineShare, separator: " ")
        case 2: AdvancedPairText(primary: row.cpu.primary, secondary: row.cpu.secondary)
        case 3: AdvancedPairText(primary: row.gpu.primary, secondary: row.gpu.secondary)
        case 4: Text(row.memory)
        case 5: AdvancedPairText(primary: row.peakTemperatures.primary, secondary: row.peakTemperatures.secondary)
        case 6: Text(row.downloaded)
        case 7: Text(row.uploaded)
        case 8: Text(row.diskRead)
        default: Text(row.diskWritten)
        }
    }

    // MARK: Cards

    private func cards(_ table: AdvancedModel.UsageTable) -> some View {
        let scale = cellSize / DMTextStyle.callout.size
        let columns = Metrics.cardColumns(in: width, scale: scale)
        let cardWidth = (width - CGFloat(columns - 1) * Metrics.cardSpacing) / CGFloat(columns)
        // Two by two, the columns pair up: CPU and GPU, memory and temperatures, down and up, read and written.
        let metricColumns = Metrics.metricColumns(in: cardWidth, cellWidth: 132 * scale, atMost: 2)
        return EqualColumnsLayout(columns: columns, columnSpacing: Metrics.cardSpacing, rowSpacing: Metrics.cardSpacing) {
            ForEach(table.rows) { row in
                card(row, metricColumns: metricColumns)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced-usage")
    }

    private func card(_ row: AdvancedModel.UsageRow, metricColumns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Time online heads the card beside the name while both fit on a line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                    AdvancedDeviceName(name: row.name, color: row.color, style: .rowTitle)
                        .fixedSize()
                    Spacer(minLength: 0)
                    onlineLine(row)
                }
                VStack(alignment: .leading, spacing: 6) {
                    AdvancedDeviceName(name: row.name, color: row.color, style: .rowTitle)
                    onlineLine(row)
                }
            }
            EqualColumnsLayout(columns: metricColumns, columnSpacing: Metrics.metricSpacing, rowSpacing: 9) {
                ForEach(2..<10, id: \.self) { index in
                    AdvancedMetric(label: Self.header(index)) { figure(row, index) }
                }
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .contextMenu { historyButton(row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(spoken(row))
        .accessibilityAction(named: AppTab.history.title) { router.openHistory(deviceID: row.deviceID) }
        .accessibilityIdentifier("advanced-usage-row-\(row.deviceID)")
    }

    /// "ONLINE 144 h 100%" on one line.
    private func onlineLine(_ row: AdvancedModel.UsageRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.header(1))
                .dmFont(.statKey)
                .foregroundStyle(Theme.textMuted)
            figure(row, 1)
                .dmFont(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

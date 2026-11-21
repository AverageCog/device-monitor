import DMCore
import SwiftUI

/// Power per device (`#advPower`): Device, Now, Average, Peak, Energy, Cost, Share and Power
/// reading, with "All devices" underneath.
///
/// A real table where all eight columns fit, which an iPad does either way up; one card per
/// device, every figure under its column's heading, where they do not. Either way a row opens to
/// show how the device's current draw is made up, which the dashboard keeps in a hover title.
struct AdvancedPowerSection: View {
    let controller: AdvancedController
    let width: CGFloat
    let options: AdvancedDebugOptions

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rows the user opened or, of those that start open, closed.
    @State private var toggled: Set<String> = []
    @ScaledMetric(relativeTo: .callout) private var cellSize: CGFloat = DMTextStyle.callout.size
    @ScaledMetric(relativeTo: .caption2) private var headerSize: CGFloat = DMTextStyle.statKey.size
    @ScaledMetric(relativeTo: .callout) private var readingSize: CGFloat = DMTextStyle.statValue.size

    private typealias Metrics = AdvancedTableMetrics

    /// Device and Power reading start at the leading edge (`th:first-child`, `.src`).
    private static let leadingColumns: Set<Int> = [0, 7]

    private static func header(_ index: Int) -> String {
        let headers = AdvancedModel.PowerTable.headers
        return headers.indices.contains(index) ? headers[index] : ""
    }

    var body: some View {
        let table = controller.power
        if let text = table.emptyText {
            AdvancedNotice(text: text)
                .accessibilityIdentifier("advanced-power-empty")
        } else if let widths = columnWidths(for: table) {
            tableView(table, widths: widths)
        } else {
            cards(table)
        }
    }

    // MARK: Opening a row

    private func isOpen(_ row: AdvancedModel.PowerRow) -> Bool {
        !row.breakdown.isEmpty && toggled.contains(row.deviceID) != options.expands(row.deviceID)
    }

    private func toggle(_ row: AdvancedModel.PowerRow) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            toggled.formSymmetricDifference([row.deviceID])
        }
    }

    private func disclosure(_ row: AdvancedModel.PowerRow) -> AdvancedDisclosure {
        row.breakdown.isEmpty ? .unavailable : isOpen(row) ? .expanded : .collapsed
    }

    /// "CPU 40 W · GPU 191 W · rest of system ~25 W · power supply losses ~29 W"
    private func breakdown(_ row: AdvancedModel.PowerRow) -> some View {
        Text(row.breakdown)
            .dmFont(.statValue)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("advanced-power-breakdown-\(row.deviceID)")
    }

    private func historyButton(_ row: AdvancedModel.PowerRow) -> some View {
        Button {
            router.openHistory(deviceID: row.deviceID)
        } label: {
            Label(AppTab.history.title, systemImage: AppTab.history.systemImage)
        }
    }

    // MARK: VoiceOver

    /// A row as one sentence: every figure after its column's heading.
    private func spoken(_ row: AdvancedModel.PowerRow) -> String {
        let fields = [row.now, row.average, row.peak, row.energy, row.cost, row.share, row.source]
        return fields.enumerated()
            .filter { !$0.element.isEmpty }
            .map { "\(Self.header($0.offset + 1)) \($0.element)" }
            .joined(separator: ", ")
    }

    private func spokenTotal(_ table: AdvancedModel.PowerTable) -> String {
        "\(Self.header(1)) \(table.totalNow), \(Self.header(4)) \(table.totalEnergy), \(Self.header(5)) \(table.totalCost)"
    }

    // MARK: Table

    /// The widths of the eight columns, or nil when they do not all fit in the page.
    private func columnWidths(for table: AdvancedModel.PowerTable) -> [CGFloat]? {
        let rows = table.rows
        func cell(_ text: String, semibold: Bool = false) -> CGFloat {
            AdvancedTextMeasure.width(of: text, style: .callout, size: cellSize, weight: semibold ? .semibold : nil)
        }
        func widest(_ texts: [String]) -> CGFloat { texts.map { cell($0) }.max() ?? 0 }
        func head(_ index: Int) -> CGFloat {
            AdvancedTextMeasure.width(of: Self.header(index), style: .statKey, size: headerSize)
        }
        let scale = cellSize / DMTextStyle.callout.size
        let mark = Metrics.swatch + Metrics.swatchSpacing
        let total = cell(table.totalLabel, semibold: true)
        let names = mark + (rows.map { cell($0.name, semibold: true) }.max() ?? 0)
        // One width for the three wattages: "Now" changes every second and must not nudge its neighbours.
        let watts = max(widest(rows.map(\.now)), widest(rows.map(\.average)), widest(rows.map(\.peak)), cell(table.totalNow, semibold: true))
        let energy = max(head(4), widest(rows.map(\.energy)), cell(table.totalEnergy, semibold: true))
        let cost = max(head(5), widest(rows.map(\.cost)), cell(table.totalCost, semibold: true))
        let percent = widest(rows.map(\.share)) + Metrics.swatchSpacing
        let readings = rows.map(\.source)
        let reading = readings.map { AdvancedTextMeasure.width(of: $0, style: .statValue, size: readingSize) }.max() ?? 0
        let readingOnTwoLines = readings.map { AdvancedTextMeasure.twoLineWidth(of: $0, style: .statValue, size: readingSize) }.max() ?? 0
        let columns = [
            // A long name is cut short before the table gives up, and only then.
            AdvancedTableColumn(
                natural: max(names, total, head(0)), minimum: max(total, head(0), min(names, mark + Metrics.nameMinimum * scale))),
            AdvancedTableColumn(natural: max(watts, head(1))),
            AdvancedTableColumn(natural: max(watts, head(2))),
            AdvancedTableColumn(natural: max(watts, head(3))),
            AdvancedTableColumn(natural: energy),
            AdvancedTableColumn(natural: cost),
            // The bar gives way first.
            AdvancedTableColumn(
                natural: max(head(6), percent + Metrics.shareBar), minimum: max(head(6), percent + Metrics.shareBarMinimum)),
            // "GPU measured, CPU estimated" may take two lines.
            AdvancedTableColumn(natural: max(head(7), reading), wrapped: max(head(7), readingOnTwoLines)),
        ]
        let available = width - Metrics.rowPadding - Metrics.disclosurePadding
        return AdvancedTableFit.widths(of: columns, in: available, spacing: Metrics.columnSpacing)
    }

    private func tableView(_ table: AdvancedModel.PowerTable, widths: [CGFloat]) -> some View {
        VStack(spacing: 0) {
            AdvancedTableRow(
                widths: widths, leading: Self.leadingColumns, alignment: .lastTextBaseline, trailingPadding: Metrics.disclosurePadding
            ) { index in
                Text(Self.header(index))
                    .dmFont(.statKey)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .padding(.vertical, Metrics.cellPadding)
            // Each row says its headings itself.
            .accessibilityHidden(true)
            ForEach(table.rows) { row in
                Hairline()
                tableRow(row, widths: widths)
            }
            Rectangle()
                .fill(Theme.axis)
                .frame(height: Theme.Layout.hairline)
                .accessibilityHidden(true)
            AdvancedTableRow(widths: widths, leading: Self.leadingColumns, trailingPadding: Metrics.disclosurePadding) { index in
                totalCell(table, index)
            }
            .padding(.vertical, Metrics.cellPadding + 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(table.totalLabel)
            .accessibilityValue(spokenTotal(table))
            .accessibilityIdentifier("advanced-power-total")
        }
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced-power")
    }

    private func tableRow(_ row: AdvancedModel.PowerRow, widths: [CGFloat]) -> some View {
        let cells = AdvancedTableRow(widths: widths, leading: Self.leadingColumns, trailingPadding: Metrics.disclosurePadding) { index in
            cell(row, index)
        }
        .padding(.vertical, Metrics.cellPadding)
        .frame(minHeight: 44)
        // In the margin, so that it costs the columns nothing.
        .overlay(alignment: .trailing) {
            AdvancedChevron(state: disclosure(row))
                .frame(width: Metrics.disclosurePadding)
        }
        return VStack(alignment: .leading, spacing: 0) {
            summary(row) { cells }
            if isOpen(row) {
                breakdown(row)
                    .padding(.leading, Metrics.rowPadding + Metrics.swatch + Metrics.swatchSpacing)
                    .padding(.trailing, Metrics.disclosurePadding)
                    .padding(.bottom, Metrics.cellPadding + 2)
            }
        }
        .contextMenu { historyButton(row) }
    }

    /// A row's figures as one element: a button when there is a breakdown to open.
    @ViewBuilder
    private func summary<Content: View>(_ row: AdvancedModel.PowerRow, @ViewBuilder content: () -> Content) -> some View {
        if row.breakdown.isEmpty {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.name)
                .accessibilityValue(spoken(row))
                .accessibilityIdentifier("advanced-power-row-\(row.deviceID)")
        } else {
            Button {
                toggle(row)
            } label: {
                content()
            }
            .buttonStyle(AdvancedRowButtonStyle())
            .accessibilityLabel(row.name)
            .accessibilityValue("\(spoken(row)), \(isOpen(row) ? AdvancedStrings.expanded : AdvancedStrings.collapsed)")
            .accessibilityIdentifier("advanced-power-row-\(row.deviceID)")
        }
    }

    @ViewBuilder
    private func cell(_ row: AdvancedModel.PowerRow, _ index: Int) -> some View {
        switch index {
        case 0: AdvancedDeviceName(name: row.name, color: row.color)
        case 1: figure(row.now, isMuted: row.isOffline)
        case 2: figure(row.average)
        case 3: figure(row.peak)
        case 4: figure(row.energy)
        case 5: figure(row.cost)
        case 6: share(row)
        default:
            Text(row.source)
                .dmFont(.statValue)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func totalCell(_ table: AdvancedModel.PowerTable, _ index: Int) -> some View {
        switch index {
        case 0: figure(table.totalLabel, isStrong: true)
        case 1: figure(table.totalNow, isStrong: true)
        case 4: figure(table.totalEnergy, isStrong: true)
        case 5: figure(table.totalCost, isStrong: true)
        default: figure("")
        }
    }

    private func figure(_ text: String, isMuted: Bool = false, isStrong: Bool = false) -> some View {
        Text(text)
            .dmFont(.callout)
            .fontWeight(isStrong ? .semibold : .regular)
            .foregroundStyle(isMuted ? Theme.textMuted : Theme.textPrimary)
            .lineLimit(1)
    }

    /// "67%" and its bar (`.share`). The text is there even when empty, to keep the row's baseline.
    private func share(_ row: AdvancedModel.PowerRow) -> some View {
        HStack(alignment: .center, spacing: Metrics.swatchSpacing) {
            Text(row.share)
                .lineLimit(1)
                .fixedSize()
            MeterBar(percent: row.shareFraction * 100, color: row.color.color, height: 6)
                .frame(minWidth: 20, maxWidth: Metrics.shareBar)
        }
        .dmFont(.callout)
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: Cards

    private func cards(_ table: AdvancedModel.PowerTable) -> some View {
        let scale = cellSize / DMTextStyle.callout.size
        let columns = Metrics.cardColumns(in: width, scale: scale)
        let cardWidth = (width - CGFloat(columns - 1) * Metrics.cardSpacing) / CGFloat(columns)
        // Now, Average, Peak over Energy, Cost, Share.
        let metricColumns = Metrics.metricColumns(in: cardWidth, cellWidth: 92 * scale, atMost: 3)
        return EqualColumnsLayout(columns: columns, columnSpacing: Metrics.cardSpacing, rowSpacing: Metrics.cardSpacing) {
            ForEach(table.rows) { row in
                card(row, metricColumns: metricColumns)
            }
            totalCard(table, metricColumns: metricColumns)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advanced-power")
    }

    private func card(_ row: AdvancedModel.PowerRow, metricColumns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(row) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: Theme.Spacing.s) {
                        AdvancedDeviceName(name: row.name, color: row.color, style: .rowTitle)
                        Spacer(minLength: 0)
                        AdvancedChevron(state: disclosure(row))
                    }
                    EqualColumnsLayout(columns: metricColumns, columnSpacing: Metrics.metricSpacing, rowSpacing: 9) {
                        AdvancedMetric(Self.header(1), row.now, isMuted: row.isOffline)
                        AdvancedMetric(Self.header(2), row.average)
                        AdvancedMetric(Self.header(3), row.peak)
                        AdvancedMetric(Self.header(4), row.energy)
                        AdvancedMetric(Self.header(5), row.cost)
                        AdvancedMetric(label: Self.header(6)) { share(row) }
                    }
                    reading(row)
                }
                .padding(Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isOpen(row) {
                Hairline()
                    .padding(.horizontal, Metrics.cardPadding)
                breakdown(row)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, Metrics.cardPadding - 2)
            }
        }
        // Cards of one row are equally tall.
        .frame(maxHeight: .infinity, alignment: .top)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .contextMenu { historyButton(row) }
    }

    /// "Power reading" and how the device's power is known: on one line while it fits.
    private func reading(_ row: AdvancedModel.PowerRow) -> some View {
        let label = Text(Self.header(7))
            .dmFont(.statKey)
            .foregroundStyle(Theme.textMuted)
        let value = Text(row.source)
            .dmFont(.statValue)
            .foregroundStyle(Theme.textSecondary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                label.lineLimit(1)
                Spacer(minLength: 0)
                value.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                value.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "All devices" (`tfoot`): what the fleet draws now, and its energy and cost over the range.
    private func totalCard(_ table: AdvancedModel.PowerTable, metricColumns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(table.totalLabel)
                .dmFont(.rowTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            EqualColumnsLayout(columns: metricColumns, columnSpacing: Metrics.metricSpacing, rowSpacing: 9) {
                AdvancedMetric(label: Self.header(1)) { Text(table.totalNow).fontWeight(.semibold) }
                AdvancedMetric(label: Self.header(4)) { Text(table.totalEnergy).fontWeight(.semibold) }
                AdvancedMetric(label: Self.header(5)) { Text(table.totalCost).fontWeight(.semibold) }
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // `tfoot td { border-top: 1px solid var(--axis) }`: set apart from the devices above it.
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile, border: Theme.axis)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(table.totalLabel)
        .accessibilityValue(spokenTotal(table))
        .accessibilityIdentifier("advanced-power-total")
    }
}

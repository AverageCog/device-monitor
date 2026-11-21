import DMCore
import SwiftUI

/// A device's card (`createCard` / `updateCard` in public/index.html): grip, status dot, name,
/// status line and menu; three gauges with their line underneath; the chart with its legend and
/// range; the stats; Details.
///
/// Every text and number comes from `DeviceCardModel`. The card is compared by what it is given, so
/// a report from one device redraws that device's card and no other.
struct DashboardCard: View, Equatable {
    nonisolated enum Role: Sendable {
        /// In its place in the grid.
        case inGrid
        /// In its place, blank: its copy is in the air.
        case slot
        /// The copy in the air.
        case lifted
    }

    let device: Device
    let series: CardSeries
    let isDetailsOpen: Bool
    /// Position among the cards, for "Move up" and "Move down".
    let index: Int
    let count: Int
    var role = Role.inGrid

    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(DashboardDeviceActionModel.self) private var actions
    @Environment(DashboardReorderModel.self) private var reorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: DashboardCard, b: DashboardCard) -> Bool {
        a.device == b.device && a.series == b.series && a.isDetailsOpen == b.isDetailsOpen && a.index == b.index && a.count == b.count
            && a.role == b.role
    }

    var body: some View {
        let unit = preferences.temperatureUnit
        let model = DeviceCardModel(device: device, unit: unit, latestVersions: store.latestVersions, now: store.clock.now)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(model)
            DashboardGaugeRow(gauges: model.gauges, deviceID: model.id)
            DashboardCardChart(deviceID: model.id, series: series)
            DashboardStats(stats: model.stats)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(DashboardID.stats(model.id))
            DashboardDetailsDisclosure(deviceID: model.id, isExpanded: isDetailsOpen, toggle: toggleDetails) {
                DashboardCardDetails(model: DeviceDetailsModel(device: device, unit: unit))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(DashboardID.details(model.id))
            }
        }
        // Readings change in place every two seconds; equal-width digits keep them from shifting.
        .monospacedDigit()
        // The grid makes every card of a row as tall as the tallest (CSS grid stretch).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Layout.cardPadding)
        .dmSurface(Theme.surface1, radius: Theme.Radius.card)
        .opacity(role == .slot ? 0 : 1)
        .background {
            if role == .slot {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        // Outside what goes blank, so the drag that began on it keeps its touch.
        .overlay(alignment: .topLeading) {
            if role != .lifted {
                DashboardGripSurface(
                    onBegan: { point, windowPoint, scrollView in
                        reorder.begin(id: device.id, at: point, windowPoint: windowPoint, scrollView: scrollView, online: store.onlineDevices.map(\.id))
                    },
                    onMoved: { reorder.move(id: device.id, windowPoint: $0) },
                    onEnded: { reorder.end(id: device.id, store: store, failures: actions) }
                )
                .frame(width: DashboardReorderModel.gripReach.width, height: DashboardReorderModel.gripReach.height)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.name)
        // "online, CPU 27%": the card in a few words, for UI tests and for whoever lands on it.
        .accessibilityValue("online, \(model.cpu.label) \(model.cpu.valueText)")
        .accessibilityIdentifier(DashboardID.row(model.id))
    }

    // MARK: Head

    private func header(_ model: DeviceCardModel) -> some View {
        HStack(alignment: .top, spacing: 0) {
            grip(model)
            DashboardDeviceTitle(title: model.name, subtitle: model.subtitle, isOnline: model.isOnline)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contextMenu { DashboardDeviceMenuItems(perform: perform) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.name)
                .accessibilityValue("\(model.isOnline ? "Online" : "Offline"), \(model.subtitle)")
                .accessibilityAddTraits(.isHeader)
            DashboardDeviceMenuButton(identifier: DashboardID.menu(model.id), perform: perform)
                // The glyph, not its plate, lines up with the card's content edge.
                .padding(.top, -6)
                .padding(.trailing, -6)
                .padding(.leading, Theme.Spacing.xs)
        }
    }

    /// The six-dot grip (`.grip`). The touch surface over it is laid on the card; this is what is
    /// seen, and what assistive technologies move the card with.
    private func grip(_ model: DeviceCardModel) -> some View {
        // What VoiceOver finds under a finger is as large as what takes the drag.
        Color.clear
            .frame(width: 14 + 2 * Self.gripReach, height: 18 + 2 * Self.gripReach)
            .overlay {
                DashboardGripGlyph()
                    .fill(Theme.textMuted)
                    .frame(width: 14, height: 18)
                    .opacity(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DeviceCardText.reorderHandleLabel)
            .accessibilityValue(DashboardStrings.position(index, of: count))
            .accessibilityActions {
                if index > 0 {
                    Button(DashboardStrings.moveUp) { move(by: -1, model.name) }
                }
                if index < count - 1 {
                    Button(DashboardStrings.moveDown) { move(by: 1, model.name) }
                }
            }
            .accessibilityIdentifier(DashboardID.grip(model.id))
            .padding(-Self.gripReach)
            // margin: 2px -4px 0 -8px, next to a 9-point gap.
            .padding(.top, 2)
            .padding(.leading, -8)
            .padding(.trailing, 5)
    }

    private static let gripReach: CGFloat = 14

    // MARK: Actions

    private func perform(_ item: DeviceMenuItem) {
        actions.perform(item, on: device) { router.openHistory(deviceID: device.id) }
    }

    private func toggleDetails() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            DashboardMemory.shared.setDetails(open: !isDetailsOpen, for: device.id)
        }
    }

    private func move(by offset: Int, _ name: String) {
        let ids = store.onlineDevices.map(\.id)
        guard let position = reorder.move(id: device.id, by: offset, online: ids, store: store, failures: actions) else { return }
        AccessibilityNotification.Announcement(DashboardStrings.moved(name, to: position, of: ids.count)).post()
    }
}

/// Status dot, name and status line of a device (`.dot` + `.titles`), as the design system's
/// `DeviceTitle` draws them, but with a status line that wraps where one line cannot hold it: at
/// accessibility text sizes on a card, and in the offline list.
struct DashboardDeviceTitle: View {
    let title: String
    let subtitle: String
    let isOnline: Bool
    /// Lines the status line may take at standard text sizes.
    var subtitleLines = 1

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = DMTextStyle.cardTitle.size
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Half the height of the name's capitals, measured up from the baseline.
        let capitalsMiddle = 0.35 * titleSize
        let isLarge = dynamicTypeSize.isAccessibilitySize
        // From extra large on, one line no longer holds "… · v1.2.30 → 1.2.33" even shrunk.
        let lines = dynamicTypeSize >= .xLarge ? max(2, subtitleLines) : subtitleLines
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            StatusDot(isOnline: isOnline)
                // Centre the dot on the capitals of the name, whatever the text size.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + capitalsMiddle - $0.height / 2 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .dmFont(.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(isLarge ? 2 : 1)
                Text(subtitle)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(isLarge ? 4 : lines)
                    // On a narrow phone it gets a little smaller before it is cut.
                    .minimumScaleFactor(isLarge ? 1 : 0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The grip's two columns of three dots (the 14 × 18 SVG of `.grip`).
nonisolated struct DashboardGripGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width / 14, rect.height / 18)
        var path = Path()
        for x in [4.0, 10.0] {
            for y in [3.0, 9.0, 15.0] {
                let radius = 1.6 * unit
                path.addEllipse(in: CGRect(x: rect.minX + x * unit - radius, y: rect.minY + y * unit - radius, width: radius * 2, height: radius * 2))
            }
        }
        return path
    }
}

/// The three gauges of a card (`.gauges`). At accessibility text sizes the line under a gauge no
/// longer fits a third of the card, so each gauge gets a row with its line beside it.
struct DashboardGaugeRow: View {
    let gauges: [DeviceGaugeModel]
    let deviceID: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(gauges) { gauge in
                    HStack(spacing: Theme.Spacing.l) {
                        GaugeView(value: gauge.value, label: gauge.label, color: gauge.tint.dashboardColor)
                            .frame(width: 96)
                        caption(gauge.caption)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(gauge.label)
                    .accessibilityValue(Self.spokenValue(gauge))
                    .accessibilityIdentifier(DashboardID.gauge(gauge.kind, deviceID))
                }
            }
        } else {
            GaugeRow {
                ForEach(gauges) { gauge in
                    GaugeColumn(value: gauge.value, label: gauge.label, color: gauge.tint.dashboardColor, caption: Self.columnCaption(gauge.caption))
                        .accessibilityValue(Self.spokenValue(gauge))
                        .accessibilityIdentifier(DashboardID.gauge(gauge.kind, deviceID))
                }
            }
        }
    }

    /// "28%, 59°C, Normal, ACPI sensor": the reading, then what is under the gauge.
    private static func spokenValue(_ gauge: DeviceGaugeModel) -> String {
        let reading = gauge.value == nil ? DashboardStrings.noReading : gauge.valueText
        let caption: String? = switch gauge.caption {
        case .temperature(let pill): TempPill.spokenValue(pill.text, level: pill.status.dashboardLevel, note: pill.note)
        case .noSensor, .noGPU, .offline, .text: gauge.caption.text.isEmpty ? nil : gauge.caption.text
        }
        return [reading, caption].compactMap { $0 }.joined(separator: ", ")
    }

    private static func columnCaption(_ caption: DeviceGaugeCaption) -> GaugeCaption {
        switch caption {
        case .temperature(let pill): .temperature(pill.text, pill.status.dashboardLevel)
        case .noSensor, .noGPU, .offline: .hint(caption.text)
        case .text(let text): text.isEmpty ? .none : .text(text)
        }
    }

    @ViewBuilder
    private func caption(_ caption: DeviceGaugeCaption) -> some View {
        switch caption {
        case .temperature(let pill):
            TempPill(pill.text, level: pill.status.dashboardLevel, note: pill.note)
        case .noSensor, .noGPU, .offline:
            GaugeHint(caption.text)
        case .text(let text):
            Text(text)
                .dmFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// The stats of a card (`.stats`): the design system's two-column grid of single-line cells, as
/// long as a column holds a reading. Where it does not (larger text, a narrow card) the cells
/// come one under another and their values wrap.
struct DashboardStats: View {
    let stats: [DeviceStat]
    /// Cells per row where they fit; the drives under Details take a row each.
    var columns = 2

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The size of a value that has shrunk as far as it may.
    @ScaledMetric(relativeTo: .callout) private var smallestValueSize: CGFloat = DMTextStyle.statValue.size * DashboardStats.shrink

    /// How far a value shrinks before it is cut short ("GeForce RTX 5090 · 465 W").
    private static let shrink: CGFloat = 0.9
    /// About the longest reading a cell shows. A fixed text and not the values on show: the
    /// layout must not change with the readings.
    private static let longReading = "\u{2193} 999 KB/s \u{A0}\u{2191} 999 KB/s"

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else if columns == 1 {
            // The drives: one under another, eight points apart.
            VStack(alignment: .leading, spacing: Theme.Spacing.s) { cells }
        } else {
            ViewThatFits(in: .horizontal) {
                ZStack(alignment: .topLeading) {
                    // As wide as two long readings side by side, and nothing else: this is what
                    // has to fit for the grid to be chosen.
                    HStack(spacing: Theme.Spacing.l) {
                        reading
                        reading
                    }
                    .frame(height: 0)
                    .hidden()
                    .accessibilityHidden(true)
                    StatsGrid(columns: columns) { cells }
                        .minimumScaleFactor(Self.shrink)
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                }
                stacked
            }
        }
    }

    private var reading: some View {
        Text(Self.longReading)
            .font(.system(size: smallestValueSize).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }

    private var cells: some View {
        ForEach(stats) { stat in
            StatCell(stat.key, value: stat.value, percent: stat.percent, barColor: stat.tint.dashboardColor)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.key)
                        .dmFont(.statKey)
                        .foregroundStyle(Theme.textMuted)
                    Text(stat.value)
                        .dmFont(.statValue)
                        .foregroundStyle(Theme.textPrimary)
                    if let percent = stat.percent {
                        MeterBar(percent: percent, color: stat.tint.dashboardColor)
                            .padding(.top, 5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stat.key)
                .accessibilityValue(stat.percent.map { "\(stat.value), \(Theme.percentText(Theme.clampedPercent($0)))" } ?? stat.value)
            }
        }
    }
}

/// The collapsible "Details" of a card (`details` / `summary`), drawn like the design system's
/// `DetailsDisclosure` with a 44-point target for the row that opens it.
struct DashboardDetailsDisclosure<Content: View>: View {
    let deviceID: String
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(DeviceCardText.details)
                        .dmFont(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .padding(.bottom, isExpanded ? 0 : 2)
                // Reaches up to the stats and down to the card's edge without taking room.
                .padding(.top, 8)
                .padding(.bottom, 13)
                .contentShape(Rectangle())
                .padding(.top, -8)
                .padding(.bottom, -13)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? DashboardStrings.expanded : DashboardStrings.collapsed)
            .accessibilityIdentifier(DashboardID.detailsToggle(deviceID))
            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
    }
}

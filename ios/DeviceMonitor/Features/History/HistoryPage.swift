import DMCore
import SwiftUI

/// Places on the page that it can be scrolled to.
nonisolated enum HistoryAnchor: Hashable, Sendable {
    case top
    case tiles
    case chart(HistoryChartModel.Kind)
    case hint
}

/// The texts of the page that the dashboard does not have: it is silent while it loads, shows a
/// failed request as an empty range, and explains itself for a mouse.
nonisolated enum HistoryText {
    static let rangeLabel = "Time range"
    static let devicesLabel = "Devices"
    static let loading = "Loading history\u{2026}"
    static let failedTitle = "Couldn\u{2019}t load history"
    static let retry = "Try again"
    static let addDevice = "Add device"
    /// `HistoryModel.pointerHint`, for fingers.
    static let touchHint = "Touch and hold a chart to inspect \u{B7} drag across it to zoom in \u{B7} double-tap to reset. " + HistoryModel.bandsHint
}

/// The History page (`#historyView` of public/index.html): device chips and range buttons, the
/// device's name, the peak tiles, a chart per kind of reading, and a note on how to read them.
struct HistoryPage: View {
    let controller: HistoryController

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let padding = Theme.Layout.screenPadding(for: sizeClass)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // The very top, above the padding: scrolling here leaves the large title as it is.
                    Color.clear
                        .frame(height: 0)
                        .id(HistoryAnchor.top)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        if controller.deviceID == nil {
                            HistoryNoDevices()
                        } else {
                            HistoryControls(controller: controller)
                                .padding(.bottom, 12)
                            HistoryHeader(controller: controller)
                                .padding(.bottom, 14)
                            HistoryResults(controller: controller)
                        }
                    }
                    .frame(maxWidth: Theme.Layout.maxContentWidth, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        controller.setColumnWidth(Double(width))
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
            }
            // window.scrollTo(0, 0) in openHistory
            .onChange(of: controller.deviceID) {
                proxy.scrollTo(HistoryAnchor.top, anchor: .top)
            }
            #if DEBUG
            .background { HistoryDebugDriver(controller: controller, proxy: proxy) }
            #endif
        }
    }
}

// MARK: - Controls

/// Device chips and the range buttons (`.hv-bar`): side by side where there is room, stacked on a phone.
private struct HistoryControls: View {
    let controller: HistoryController

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            // One row while every chip and the range buttons fit in it, as on the dashboard.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.m) {
                    HistoryDeviceBar(controller: controller, bleedsToEdges: false)
                    Spacer(minLength: 0)
                    HistoryRangeControl(controller: controller)
                        .fixedSize()
                }
                stacked
            }
        } else {
            stacked
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HistoryDeviceBar(controller: controller, bleedsToEdges: true)
            HistoryRangeControl(controller: controller)
        }
    }
}

/// One chip per device, in the dashboard's order, in a row that scrolls sideways (`#hvDevices`).
///
/// This is the one view of the page that reads the device list, which changes with every report.
private struct HistoryDeviceBar: View {
    let controller: HistoryController
    /// On a phone the row runs out to the screen's edges while it scrolls.
    let bleedsToEdges: Bool

    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let chips = HistoryDeviceChipModel.chips(for: store.devices, selected: controller.deviceID)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        HistoryDeviceChip(chip: chip) {
                            // location.hash = '#/history/' + id
                            router.historyDeviceID = chip.id
                            controller.select(device: chip.id)
                        }
                        .id(chip.id)
                    }
                }
            }
            .scrollClipDisabled(bleedsToEdges)
            .onChange(of: controller.deviceID, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HistoryText.devicesLabel)
        .accessibilityIdentifier("history-devices")
    }
}

/// A device chip (`.hv-devices button`), with the hit target a finger needs around the pill.
private struct HistoryDeviceChip: View {
    let chip: HistoryDeviceChipModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(chip.isOnline ? Theme.good : Theme.textMuted)
                    .frame(width: 7, height: 7)
                Text(chip.name)
            }
        }
        .buttonStyle(HistoryChipStyle(isSelected: chip.isSelected))
        .accessibilityLabel(chip.name)
        .accessibilityValue(chip.isOnline ? "Online" : "Offline")
        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
        .accessibilityIdentifier("history-device-\(chip.id)")
    }
}

/// The design system's chip, tappable over a full 44 points of height.
private struct HistoryChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        DMChipStyle(isSelected: isSelected)
            .makeBody(configuration: configuration)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// 1 h / 6 h / 24 h / 7 days / 30 days (`#hvRange`). None is lit while zoomed.
private struct HistoryRangeControl: View {
    let controller: HistoryController

    var body: some View {
        let selection = Binding<HistoryPageRange?> {
            controller.window.selectedRange
        } set: { range in
            if let range { controller.select(range: range) }
        }
        let control = DMSegmentedControl(
            HistoryText.rangeLabel, selection: selection,
            segments: HistoryPageRange.allCases.map { DMSegment(Optional($0), $0.label, identifier: $0.rawValue) },
            identifier: "history-range"
        )
        // At the largest text sizes five labels are wider than a phone: the control then scrolls,
        // out to the screen's edge like the chips above it.
        ViewThatFits(in: .horizontal) {
            control
            ScrollView(.horizontal, showsIndicators: false) { control }
                .scrollClipDisabled()
        }
    }
}

// MARK: - Header

/// The device's name with "Windows 11 Pro · online" (`.hv-head`), and "Reset zoom" while zoomed.
private struct HistoryHeader: View {
    let controller: HistoryController

    @Environment(HubStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let header = HistoryHeaderModel(devices: store.devices, selected: controller.deviceID)
        let showsReset = controller.window.showsReset
        let showsProgress = controller.isReplacingCharts
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            titles(header)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(header.title)
                .accessibilityValue(header.subtitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen-history")
            Spacer(minLength: 0)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .accessibilityLabel(HistoryText.loading)
                    .accessibilityIdentifier("history-progress")
                    .transition(.opacity)
            }
            if showsReset {
                Button(HistoryWindow.resetTitle) { controller.resetZoom() }
                    .buttonStyle(.dm(size: .small))
                    .fixedSize()
                    .accessibilityIdentifier("history-reset-zoom")
                    .transition(.opacity)
            }
        }
        // As tall as the button, so the page does not move when it comes and goes.
        .frame(minHeight: 44)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsReset)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsProgress)
    }

    @ViewBuilder
    private func titles(_ header: HistoryHeaderModel) -> some View {
        let title = Text(header.title)
            .dmFont(.screenTitle)
            .foregroundStyle(Theme.textPrimary)
        let subtitle = Text(header.subtitle)
            .dmFont(.statValue)
            .foregroundStyle(Theme.textMuted)
        if sizeClass == .regular {
            // One line, as on the dashboard.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                title.lineLimit(1)
                subtitle.lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                title.lineLimit(2)
                if !header.subtitle.isEmpty { subtitle.lineLimit(2) }
            }
        }
    }
}

// MARK: - Results

/// Everything under the header: tiles, charts and the note, or what stands in for them.
private struct HistoryResults: View {
    let controller: HistoryController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStale = controller.isStale
        Group {
            switch controller.content {
            case .noDevice:
                EmptyView()
            case .loading:
                HistoryLoadingPanel()
            case .failed(let message):
                EmptyStateView(title: HistoryText.failedTitle, message: message) {
                    Button(HistoryText.retry) { controller.retry() }
                        .buttonStyle(.dm(.primary))
                        .accessibilityIdentifier("history-retry-button")
                }
                .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("history-error")
            case .empty(let text):
                // <div class="hv-chart hv-empty">…</div>
                EmptyStateView(message: text)
                    .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("history-empty")
            case .charts:
                if let model = controller.model {
                    HistoryCharts(model: model, controller: controller)
                }
            }
        }
        // Another device's charts under this device's name: say so by fading them.
        .opacity(isStale ? 0.4 : 1)
        .allowsHitTesting(!isStale)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isStale)
    }
}

private struct HistoryCharts: View {
    let model: HistoryModel
    let controller: HistoryController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryTileGrid(tiles: model.tiles)
                .padding(.bottom, 18)
                .id(HistoryAnchor.tiles)
            VStack(spacing: 14) {
                ForEach(model.charts) { chart in
                    HistoryChartCard(chart: chart, model: model, controller: controller)
                        .id(HistoryAnchor.chart(chart.kind))
                }
            }
            Text(HistoryText.touchHint)
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityIdentifier("history-hint")
                .id(HistoryAnchor.hint)
        }
    }
}

/// The peak tiles (`.tiles`): as many equal columns as fit, each row as tall as its tallest tile.
/// Laid out eagerly, so the page knows its height before it is scrolled.
private struct HistoryTileGrid: View {
    let tiles: [HistoryTileModel]

    /// A tile's narrowest width grows with the text in it, so large text gets fewer columns.
    @ScaledMetric(relativeTo: .title3) private var minimumWidth: CGFloat = Theme.Layout.tileMinWidth

    var body: some View {
        HistoryTileLayout(minimumWidth: minimumWidth, spacing: Theme.Layout.tileSpacing) {
            ForEach(tiles) { tile in
                Tile(label: tile.label, value: tile.value, sub: tile.detail, tickColor: tile.tint.historyColor)
                    .accessibilityIdentifier("history-tile-\(tile.kind.rawValue)")
            }
        }
    }
}

/// `grid-template-columns: repeat(auto-fill, minmax(…, 1fr))`: the design system's equal columns,
/// as many as the width it is given has room for.
private struct HistoryTileLayout: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat?) -> EqualColumnsLayout {
        // Two columns until the width is known: what every iPhone has room for.
        let count = width.flatMap { $0.isFinite ? max(1, Int(($0 + spacing) / (minimumWidth + spacing))) : nil } ?? 2
        return EqualColumnsLayout(columns: count, columnSpacing: spacing, rowSpacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        columns(for: proposal.width).sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        columns(for: bounds.width).placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

// MARK: - Stand-ins

private struct HistoryLoadingPanel: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
                .tint(Theme.textSecondary)
            Text(HistoryText.loading)
                .dmFont(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-loading")
    }
}

/// The hub knows no device, or has not said yet which it knows.
private struct HistoryNoDevices: View {
    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        if store.hasSnapshot {
            let state = DashboardEmptyState.noDevices
            EmptyStateView(title: state.title, message: state.message, systemImage: AppTab.history.systemImage) {
                Button(HistoryText.addDevice) { router.showAddDevice() }
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier("history-add-device-button")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-history")
        } else {
            HistoryLoadingPanel()
        }
    }
}

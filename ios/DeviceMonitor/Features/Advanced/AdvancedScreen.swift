import DMCore
import SwiftUI

/// The Advanced tab: electricity use, cost and usage totals (`#advView` of public/index.html).
///
/// Every figure and word comes from `AdvancedModel`; `AdvancedController` decides when to ask the
/// hub. The page is laid out for the width it gets: tiles in as many columns as fit, and each of
/// the two tables as a real table where all its columns fit and as one card per device where
/// they do not, which is every iPhone in portrait.
struct AdvancedScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if DEBUG
    @Environment(SessionController.self) private var session
    #endif

    @State private var controller = AdvancedController()
    /// The page's width between its margins; zero until it has been laid out once.
    @State private var width: CGFloat = 0

    private let options: AdvancedDebugOptions

    init() {
        options = .current
    }

    /// For previews: the page in a state the demo hub does not get into by itself.
    init(options: AdvancedDebugOptions) {
        self.options = options
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(options.width == nil ? .vertical : [.horizontal, .vertical]) {
                page
            }
            .accessibilityIdentifier("screen-advanced")
            #if DEBUG
            .task { await showRequestedState(with: scroller) }
            #endif
        }
        .navigationTitle(AdvancedModel.title)
        .refreshable { await controller.refresh() }
        // The controller works only while somebody is looking: the tab is the chosen one, it is on
        // screen, and the app is in front.
        .onAppear {
            controller.attach(store: store, preferences: preferences, inputs: inputs, range: options.range)
            controller.setForeground(scenePhase == .active)
            controller.setSelected(router.selectedTab == .advanced)
            controller.setVisible(true)
        }
        .onDisappear { controller.setVisible(false) }
        .onChange(of: router.selectedTab) { _, tab in controller.setSelected(tab == .advanced) }
        .onChange(of: scenePhase) { _, phase in controller.setForeground(phase == .active) }
        .onChange(of: store.energySettings) { controller.priceChanged() }
        .onChange(of: preferences.temperatureUnit) { controller.unitChanged() }
        .onChange(of: store.isLive) { _, isLive in
            if isLive { controller.connectionRestored() }
        }
    }

    private var inputs: AdvancedInputs {
        #if DEBUG
        options.inputs
        #else
        AdvancedInputs()
        #endif
    }

    private var margin: CGFloat {
        // `-dm-advanced-width`: an iPad's width comes with an iPad's margins.
        if let forced = options.width { return forced >= 600 ? Theme.Layout.screenPaddingRegular : Theme.Layout.screenPaddingCompact }
        return Theme.Layout.screenPadding(for: sizeClass)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Measures the page; the sections size their columns from it.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .id(AdvancedSection.top)
            if width > 0 {
                AdvancedPage(controller: controller, width: width, options: options)
            }
        }
        .frame(width: options.width)
        .frame(maxWidth: Theme.Layout.maxContentWidth)
        .padding(.horizontal, margin)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: options.width == nil ? .infinity : nil)
    }

    #if DEBUG
    /// `-dm-advanced-state stale`, `-dm-advanced-then`, `-dm-advanced-section`, `-dm-advanced-pan`.
    private func showRequestedState(with scroller: ScrollViewProxy) async {
        guard options.state == .stale || options.then != nil || options.section != nil || options.width != nil else { return }
        // The sections below the chart take their height from the totals.
        func totals() async {
            guard options.state == nil || options.state == .stale else { return }
            for _ in 0..<40 where controller.isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await totals()
        // The second request of a hub that answers once.
        if options.state == .stale { controller.retry() }
        switch options.then {
        case .range(let range):
            controller.select(range)
            await totals()
        case .price(let rate):
            // Only ever a hub that exists in memory.
            if session.isDemo { _ = try? await store.saveEnergySettings(EnergySettings(region: PriceRegions.customCode, rate: rate, currency: "USD")) }
        case nil:
            break
        }
        try? await Task.sleep(for: .milliseconds(400))
        if options.section != nil || options.width != nil {
            scroller.scrollTo(options.section ?? .top, anchor: UnitPoint(x: options.pan, y: 0))
        }
    }
    #endif
}

/// The page's sections, top to bottom.
private struct AdvancedPage: View {
    let controller: AdvancedController
    let width: CGFloat
    let options: AdvancedDebugOptions

    /// From here the range control sits beside the first heading instead of above it.
    private static let wideLayout: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
                .id(AdvancedSection.electricity)
            AdvancedFailureBanner(controller: controller)
            AdvancedTiles(controller: controller, width: width)
                .padding(.top, 12)
            AdvancedPriceLine(controller: controller)
                .padding(.top, 12)
            AdvancedChartPanel(controller: controller, preselected: options.bucket)
                .padding(.top, 16)
                // The tooltip floats above the panel, over what comes before it.
                .zIndex(1)
                .id(AdvancedSection.chart)
            AdvancedPowerSection(controller: controller, width: width, options: options)
                .padding(.top, 14)
                .id(AdvancedSection.power)
            SectionLabel(AdvancedModel.usageHeading, size: .large)
                .padding(.top, 26)
                .id(AdvancedSection.usage)
            AdvancedUsageSection(controller: controller, width: width)
                .padding(.top, 12)
            Text(AdvancedModel.note)
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                // `max-width: 900px` of #advNote.
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .accessibilityIdentifier("advanced-note")
                .id(AdvancedSection.note)
        }
    }

    @ViewBuilder private var heading: some View {
        if width >= Self.wideLayout {
            HStack(alignment: .center, spacing: Theme.Spacing.l) {
                SectionLabel(AdvancedModel.electricityHeading, size: .large)
                AdvancedRangeControl(controller: controller)
                    .frame(width: 320)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                AdvancedRangeControl(controller: controller)
                SectionLabel(AdvancedModel.electricityHeading, size: .large)
            }
        }
    }
}

// MARK: - Range

/// 24 h / 7 days / 30 days (`#advRange`).
private struct AdvancedRangeControl: View {
    let controller: AdvancedController

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var width: CGFloat = 0

    var body: some View {
        let ranges = AdvancedRange.allCases
        let selection = Binding(get: { controller.range }, set: { controller.select($0) })
        DMSegmentedControl(
            AdvancedStrings.timeRange, selection: selection,
            segments: ranges.map { DMSegment($0, $0.label, identifier: $0.rawValue) },
            fillsWidth: true, identifier: "advanced-range"
        )
        // The control is as tall as the system's own segmented control; a touch just above or
        // below a segment still chooses it.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { tap in
                guard width > 0 else { return }
                let slot = Int(tap.location.x / (width / CGFloat(ranges.count)))
                let index = min(ranges.count - 1, max(0, slot))
                controller.select(ranges[layoutDirection == .rightToLeft ? ranges.count - 1 - index : index])
            }
        )
        .sensoryFeedback(.selection, trigger: controller.range)
    }
}

// MARK: - Failure

/// Says that the totals could not be loaded, and offers to ask again.
private struct AdvancedFailureBanner: View {
    let controller: AdvancedController

    @Environment(HubStore.self) private var store

    var body: some View {
        // While the live stream is down the tab shell says so itself, and the totals are asked
        // for again the moment it is back.
        if let failure = controller.failure, store.isLive {
            BannerView(
                failure.message, kind: failure.hasTotals ? .warning : .critical, showsProgress: controller.isRetrying,
                actionTitle: AdvancedStrings.retry
            ) {
                controller.retry()
            }
            .padding(.top, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("advanced-error")
        }
    }
}

// MARK: - Tiles

/// Drawing now, Energy used, Cost, Per month (`#advTiles`).
private struct AdvancedTiles: View {
    let controller: AdvancedController
    let width: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `.tiles { grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)) }`
    private static let dashboardTileWidth: CGFloat = 170

    var body: some View {
        let spacing = Theme.Layout.tileSpacing
        // `repeat(auto-fill, minmax(170px, 1fr))`: as many columns as fit, filled from the left.
        // Tiles may be a little narrower than the dashboard's where that keeps the four on one
        // row, or two side by side on a phone.
        let roomy = Int((width + spacing) / (Self.dashboardTileWidth + spacing))
        let tight = Int((width + spacing) / (Theme.Layout.tileMinWidth + spacing))
        let fitting = max(1, roomy, min(4, tight))
        let columns = dynamicTypeSize.isAccessibilitySize ? max(1, fitting / 2) : fitting
        EqualColumnsLayout(columns: columns, columnSpacing: spacing, rowSpacing: spacing) {
            ForEach(controller.tiles) { tile in
                Tile(label: tile.label, value: tile.value, sub: tile.sub)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: tile.value)
                    .accessibilityIdentifier("advanced-tile-\(tile.kind.identifier)")
            }
        }
    }
}

// MARK: - Price

/// "Electricity price $0.316/kWh · Typical home rate for California." and "Change…" (`#advPrice`).
private struct AdvancedPriceLine: View {
    let controller: AdvancedController

    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let price = controller.price
        let text = Text(Self.styled(price))
            .dmFont(.callout)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("advanced-price-text")
        let change = Button(price.changeLabel) { router.showElectricityPrice() }
            .buttonStyle(.dm(size: .small))
            .accessibilityLabel("\(price.changeLabel) \(price.label)")
            .accessibilityIdentifier("advanced-price-button")
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    text.fixedSize(horizontal: false, vertical: true)
                    change
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    // On one line the button follows the sentence, as on the dashboard.
                    HStack(spacing: 10) {
                        text.lineLimit(1)
                        change
                    }
                    // A sentence that wraps keeps the button at the edge, where a thumb expects it.
                    HStack(spacing: 10) {
                        text
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        change
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line as the model words it, with the price itself emphasised (`.adv-price b`).
    private static func styled(_ price: AdvancedModel.PriceRow) -> AttributedString {
        var text = AttributedString(price.text)
        if let value = text.range(of: price.value) {
            text[value].swiftUI.foregroundColor = Theme.textPrimary
            text[value].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Totals") {
    NavigationStack { AdvancedScreen().dmScreen() }
        .demoEnvironment(tab: .advanced)
}

#Preview("A bar selected, a row open") {
    NavigationStack { AdvancedScreen(options: .showing(nil, range: .day, bucket: .index(9), expanded: "gaming")).dmScreen() }
        .demoEnvironment(tab: .advanced)
}

#Preview("Loading") {
    NavigationStack { AdvancedScreen(options: .showing(.loading)).dmScreen() }
        .demoEnvironment(tab: .advanced)
}

#Preview("Could not load") {
    NavigationStack { AdvancedScreen(options: .showing(.failed)).dmScreen() }
        .demoEnvironment(tab: .advanced)
}

#Preview("Nothing in range") {
    NavigationStack { AdvancedScreen(options: .showing(.empty, price: .tou)).dmScreen() }
        .demoEnvironment(tab: .advanced)
}

#Preview("No devices") {
    NavigationStack { AdvancedScreen(options: .showing(.noDevices, price: .guessed)).dmScreen() }
        .demoEnvironment(tab: .advanced)
}
#endif

import DMCore
import SwiftUI

/// The scrolling part of the Devices tab (`renderGrid` in public/index.html): a card for every
/// online device in the store's order, or what the dashboard says when there is none.
///
/// The cards are laid out eagerly. A lazy grid would build only the cards in view, but a card must
/// outlive being scrolled away while it is dragged to a new place, cards in a row are as tall as
/// the tallest (which needs them all measured), and the UI tests look for the last row of the page
/// before they scroll to it. A hub's devices are few.
struct DashboardGrid: View {
    @Binding var showsOfflineList: Bool

    @Environment(HubStore.self) private var store
    @Environment(SessionController.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(DashboardDeviceActionModel.self) private var actions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A column is never narrower than this (`minmax(290px, 1fr)`); it grows with the text.
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth = Theme.Layout.cardMinWidth
    @State private var reorder = DashboardReorderModel()

    private enum Content: Equatable {
        /// Nothing has arrived from the hub yet.
        case loading
        case empty(DashboardEmptyState)
        case cards
    }

    var body: some View {
        let padding = Theme.Layout.screenPadding(for: horizontalSizeClass)
        let placement = DashboardScreen.headerPlacement(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.gridSpacing) {
                    if placement == .page {
                        DashboardPageHeader(showsOfflineList: $showsOfflineList)
                    }
                    if session.isDemo {
                        BannerView(DashboardStrings.demoBanner, kind: .info)
                            .accessibilityIdentifier(DashboardID.demoBanner)
                    }
                    switch content {
                    case .loading: loading
                    case .empty(let state): empty(state)
                    case .cards: cards
                    }
                    #if DEBUG
                    DebugTools()
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.top, Theme.Spacing.l)
                        .id(DashboardID.debugAnchor)
                    #endif
                }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The tab bar stays as it is while a card is in the air: the drag scrolls the page near
            // the screen's edges, and those must stay put.
            .dmTitledPage(isPaused: reorder.liftedID != nil)
            .accessibilityIdentifier(DashboardID.screen)
            // Before iOS 26, header { position: sticky; top: 0 }: the cards scroll away under it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if placement == .pinned {
                    DashboardPinnedHeader(showsOfflineList: $showsOfflineList, padding: padding)
                }
            }
            // A device that leaves the grid comes back as a fresh card. Asked here and not where
            // the cards are: when the last of them goes, that view goes with it.
            .onChange(of: cardIDs, initial: true) { _, ids in
                if let ids { DashboardMemory.shared.keep(only: ids) }
            }
            #if DEBUG
            .task { await applyDebugOptions(scroll) }
            #endif
        }
    }

    /// The devices that have a card; nil until the hub has said which devices there are.
    private var cardIDs: Set<String>? {
        store.hasSnapshot ? Set(store.onlineDevices.map(\.id)) : nil
    }

    private var content: Content {
        #if DEBUG
        if DashboardDebugOptions.current.state == .loading { return .loading }
        #endif
        guard store.hasSnapshot else { return .loading }
        // counts, not the devices: this changes only when a device comes or goes.
        if let state = DashboardSummaryModel(total: store.counts.total, online: store.counts.online).emptyState { return .empty(state) }
        return .cards
    }

    // MARK: Cards

    private var columnWidth: CGFloat {
        #if DEBUG
        if let width = DashboardDebugOptions.current.cardWidth { return width }
        #endif
        return minimumCardWidth
    }

    private var cards: some View {
        let devices = reorder.arranged(store.onlineDevices)
        let ids = devices.map(\.id)
        let series = store.series
        let open = DashboardMemory.shared.openDetails
        let lifted = reorder.liftedID
        return DashboardGridLayout(minimumColumnWidth: columnWidth, spacing: Theme.Layout.gridSpacing) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                DashboardCard(
                    device: device, series: series[device.id] ?? .empty, isDetailsOpen: open.contains(device.id),
                    index: index, count: devices.count, role: lifted == device.id ? .slot : .inGrid
                )
                .equatable()
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(DashboardReorderModel.coordinateSpace))
                } action: { frame in
                    reorder.setFrame(frame, for: device.id)
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(.named(DashboardReorderModel.coordinateSpace))
        .overlay(alignment: .topLeading) { DashboardLiftedCard() }
        .environment(reorder)
        // A card arriving, leaving or changing places glides, whoever moved it.
        .animation(reduceMotion ? nil : DashboardReorderModel.glide, value: ids)
        // Above the rest of the page, for the card in the air.
        .zIndex(1)
        .onChange(of: ids, initial: true) { _, ids in
            reorder.cardsChanged(ids, store: store, failures: actions)
        }
        .onDisappear { reorder.abandon() }
    }

    // MARK: Without cards

    private var loading: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.textSecondary)
            Text(DashboardStrings.loading)
                .dmFont(.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(DashboardID.loading)
    }

    @ViewBuilder
    private func empty(_ state: DashboardEmptyState) -> some View {
        switch state {
        case .noDevices:
            EmptyStateView(title: state.title, message: state.message) {
                Button(DashboardStrings.addDevice) { router.showAddDevice() }
                    .buttonStyle(.dm(.primary))
                    .accessibilityIdentifier(DashboardID.emptyAddButton)
            }
            // .empty { padding: 80px 20px }
            .padding(.vertical, 40)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(DashboardID.empty)
        case .allOffline:
            EmptyStateView(title: state.title, message: state.message, isCompact: true) {
                Button(DashboardSummaryModel.offlineListHint) { showsOfflineList = true }
                    .buttonStyle(.dm())
                    .accessibilityIdentifier(DashboardID.emptyOfflineButton)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(DashboardID.empty)
        }
    }

    // MARK: Debug

    #if DEBUG
    /// Puts the screen in the state the launch arguments ask for (see `DashboardDebugOptions`).
    private func applyDebugOptions(_ scroll: ScrollViewProxy) async {
        let options = DashboardDebugOptions.current
        // Only a demo hub is ever emptied or silenced.
        var silenced: [String] = []
        if let hub = session.demoHub {
            switch options.state {
            case .empty:
                for device in store.devices { try? await store.remove(device: device.id) }
            case .allOffline, .offlineAndBack:
                silenced = store.onlineDevices.map(\.id)
                for device in store.devices { hub.setReporting(false, device: device.id) }
            case .loading, nil:
                break
            }
        }
        // Once the first cards are laid out.
        try? await Task.sleep(for: .milliseconds(500))
        for device in store.onlineDevices where options.opensDetails(for: device.id) {
            DashboardMemory.shared.setDetails(open: true, for: device.id)
        }
        // The questions about an offline device are the offline list's to ask.
        if let id = options.renameID, let device = store.device(id), device.online {
            actions.perform(.rename, on: device) {}
            if let text = options.renameText { actions.renameText = text }
        }
        if let id = options.removeID, let device = store.device(id), device.online {
            actions.perform(.remove, on: device) {}
            if options.removedElsewhere, session.demoHub != nil {
                // Once the question is seen to be up. The hub announces the removal to every
                // client, so the card goes as it would for one removed on the web dashboard.
                try? await Task.sleep(for: .milliseconds(600))
                try? await store.remove(device: id)
            }
        }
        if options.commits {
            // Long enough for the question to be seen to come up.
            try? await Task.sleep(for: .milliseconds(900))
            if let subject = actions.renaming { actions.commitRename(subject, store: store) }
            if let subject = actions.removing { actions.commitRemove(subject, store: store) }
        }
        if let failure = options.failure {
            actions.report(DashboardStrings.renameFailed(store.devices.first?.displayName ?? ""), .unreachable(failure))
        }
        if let choice = options.range, let range = HistoryRange(rawValue: choice.range) {
            store.setRange(range, for: choice.id)
        }
        if options.showsOfflineList { showsOfflineList = true }
        if let anchor = options.scrollAnchor {
            try? await Task.sleep(for: .milliseconds(300))
            let parts = anchor.split(separator: ":", maxSplits: 1).map(String.init)
            let edge: UnitPoint = switch parts.dropFirst().first {
            case "bottom": .bottom
            case "center": .center
            default: .top
            }
            // A card is found by its place in the ForEach, which is its device's id; an `id()` of
            // its own inside the grid's layout is not found.
            scroll.scrollTo(parts.first == "debug" ? DashboardID.debugAnchor : parts.first ?? anchor, anchor: edge)
        }
        let online = store.onlineDevices.map(\.id)
        if let move = options.move {
            try? await Task.sleep(for: .milliseconds(300))
            reorder.move(id: move.id, by: move.offset, online: online, store: store, failures: actions)
        }
        if let drag = options.drag {
            try? await Task.sleep(for: .milliseconds(300))
            await reorder.debugDrag(id: drag.id, over: drag.over, holds: drag.holds, online: online, store: store, failures: actions)
        }
        if options.state == .offlineAndBack, let hub = session.demoHub {
            // The hub calls a device offline thirty seconds after its last report.
            while !Task.isCancelled, store.counts.online > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            // Long enough for the page without cards to be seen.
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled {
                for id in silenced { hub.setReporting(true, device: id) }
            }
        }
    }
    #endif
}

/// The grid of cards: as many equal columns of at least `minimumColumnWidth` as fit, each row as
/// tall as its tallest card (`grid-template-columns: repeat(auto-fill, minmax(290px, 1fr))`).
struct DashboardGridLayout: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    /// How many columns a width holds; one at least, however narrow.
    static func columnCount(for width: CGFloat, minimumColumnWidth: CGFloat, spacing: CGFloat) -> Int {
        // An unbounded proposal gets a single column; the cap keeps the division well inside Int.
        let usable = width.isFinite ? min(max(0, width), 100_000) : minimumColumnWidth
        return max(1, Int(((usable + spacing) / (max(1, minimumColumnWidth) + spacing)).rounded(.down)))
    }

    private func columns(for width: CGFloat) -> EqualColumnsLayout {
        let count = Self.columnCount(for: width, minimumColumnWidth: minimumColumnWidth, spacing: spacing)
        return EqualColumnsLayout(columns: count, columnSpacing: spacing, rowSpacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        columns(for: proposal.width ?? minimumColumnWidth).sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        columns(for: bounds.width).placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

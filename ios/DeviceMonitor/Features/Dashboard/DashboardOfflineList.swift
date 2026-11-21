import DMCore
import SwiftUI

/// The offline devices (`renderOffline` and `#offPop` in public/index.html), opened from the
/// summary: a popover where there is room for one, a sheet on a phone. A row opens the device's
/// history; Wake sends a Wake-on-LAN signal to a device that has reported a network address; "…"
/// is the same menu a card has.
struct DashboardOfflineList: View {
    /// A sheet needs a way out of its own; a popover is left by tapping beside it.
    let showsDone: Bool

    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var actions = DashboardDeviceActionModel()
    @State private var wakeStates: [String: WakeButtonState] = [:]
    @State private var wakeOutcomes = DashboardWakeOutcomes()
    /// The tallest the popover is made: as many rows as at the standard text size.
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 560

    var body: some View {
        // The hub's heartbeat keeps "last seen 5m ago" current while the list is open.
        let _ = store.lastStatusAt
        let model = OfflineDeviceListModel(
            devices: store.offlineDevices, latestVersions: store.latestVersions, now: store.clock.now, locale: DashboardLocale.names)
        // The size of the popover; a sheet takes its detents instead.
        DashboardOfflineListSizing(idealWidth: 380, chrome: 110, margin: Theme.Layout.screenPaddingCompact, maximumHeight: maximumHeight) {
            NavigationStack {
                ScrollView {
                    rows(model)
                        .padding(Theme.Layout.screenPaddingCompact)
                }
                .accessibilityIdentifier(DashboardID.offlineList)
                .navigationTitle(OfflineDeviceListModel.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(DashboardStrings.done) { dismiss() }
                                .accessibilityIdentifier(DashboardID.offlineDone)
                        }
                    }
                }
                .dmScreen()
            }
            // What the popover's height is measured from; never seen.
            rows(model)
                .hidden()
                .accessibilityHidden(true)
        }
        .frame(minWidth: 320, minHeight: 220)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .dashboardDeviceActions(actions)
        .sensoryFeedback(.success, trigger: wakeOutcomes.sent)
        .sensoryFeedback(.error, trigger: wakeOutcomes.failed)
        // Closes itself once nothing is offline (`if (!list.length) showOffline(false)`).
        .onChange(of: model.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        #if DEBUG
        .task {
            // The questions about an offline device, opened by launch argument (`DashboardDebugOptions`).
            let options = DashboardDebugOptions.current
            try? await Task.sleep(for: .milliseconds(700))
            if let id = options.renameID, let device = store.device(id), !device.online {
                actions.perform(.rename, on: device) {}
                if let text = options.renameText { actions.renameText = text }
            }
            if let id = options.removeID, let device = store.device(id), !device.online {
                actions.perform(.remove, on: device) {}
            }
            if options.commits {
                try? await Task.sleep(for: .milliseconds(900))
                if let subject = actions.renaming { actions.commitRename(subject, store: store) }
                if let subject = actions.removing { actions.commitRemove(subject, store: store) }
            }
            if options.wake == "press", let id = model.rows.first(where: \.canWake)?.id { wake(id) }
        }
        #endif
    }

    private func rows(_ model: OfflineDeviceListModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                DashboardOfflineRow(
                    row: row,
                    wakeState: wakeState(for: row.id),
                    open: { openHistory(row.id) },
                    wake: { wake(row.id) },
                    perform: { perform($0, on: row.id) }
                )
                if row.id != model.rows.last?.id {
                    Hairline().padding(.leading, Theme.Spacing.l)
                }
            }
        }
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
    }

    private func wakeState(for id: String) -> WakeButtonState {
        #if DEBUG
        switch DashboardDebugOptions.current.wake {
        case "sending": return .sending
        case "sent": return .sent
        case "failed": return .failed
        default: break
        }
        #endif
        return wakeStates[id] ?? .idle
    }

    /// `showOffline(false); location.hash = '#/history/' + id`
    private func openHistory(_ id: String) {
        dismiss()
        router.openHistory(deviceID: id)
    }

    private func perform(_ item: DeviceMenuItem, on id: String) {
        guard let device = store.device(id) else { return }
        actions.perform(item, on: device) { openHistory(id) }
    }

    /// Wake → Sending… → Sent ✓ or Failed, as the dashboard's button goes. The dashboard leaves
    /// the outcome on a disabled button until its list is next rebuilt; here a failure gives the
    /// button back after a moment, so it can be tried again without closing the list.
    private func wake(_ id: String) {
        guard wakeState(for: id).isEnabled else { return }
        wakeStates[id] = .sending
        Task {
            do {
                try await store.wake(device: id)
                wakeStates[id] = .sent
                wakeOutcomes.sent += 1
            } catch {
                wakeStates[id] = .failed
                wakeOutcomes.failed += 1
                AccessibilityNotification.Announcement(HubError(error).errorDescription ?? DashboardStrings.wakeFailed).post()
                try? await Task.sleep(for: .seconds(3))
                if wakeStates[id] == .failed { wakeStates[id] = .idle }
            }
        }
    }
}

/// How many wake signals went out and how many did not, to play a haptic for each.
private nonisolated struct DashboardWakeOutcomes: Equatable, Sendable {
    var sent = 0
    var failed = 0
}

/// Sizes the offline list for a popover: its first subview, the list, fills whatever it is given;
/// asked how tall it would like to be, it answers with the bar and the margins and its second
/// subview, a copy of the rows that is never seen, as tall as that lays out at the list's width.
///
/// A popover asks once, before it comes up, and a scroll view in a navigation stack has no answer
/// of its own. Measuring the rows once they are on screen comes too late: a popover resized while
/// it is up keeps its content at the first size. And no fixed height per row holds at every text
/// size: at accessibility sizes Wake and the menu go under the name, and a row is several times
/// its usual height.
private struct DashboardOfflineListSizing: Layout {
    var idealWidth: CGFloat
    /// The bar above the rows and the margins round them.
    var chrome: CGFloat
    /// The margin on either side of the rows.
    var margin: CGFloat
    var maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        if let height = proposal.height, height.isFinite { return CGSize(width: width, height: height) }
        let rows = subviews.dropFirst().first?.sizeThatFits(rowsProposal(width)).height ?? 0
        return CGSize(width: width, height: min(maximumHeight, chrome + rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        subviews.dropFirst().first?.place(at: CGPoint(x: bounds.minX + margin, y: bounds.minY), proposal: rowsProposal(bounds.width))
    }

    private func rowsProposal(_ width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: max(0, width - 2 * margin), height: nil)
    }
}

/// A row of the offline list (`.off-row`): grey dot, name, "last seen 5m ago · Windows 11 · v1.2.3",
/// Wake and the menu.
private struct DashboardOfflineRow: View {
    let row: OfflineDeviceRowModel
    let wakeState: WakeButtonState
    let open: () -> Void
    let wake: () -> Void
    let perform: (DeviceMenuItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // Beside the name; under it at accessibility text sizes, where both do not fit a line.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    HStack(spacing: Theme.Spacing.s) {
                        Spacer(minLength: 0)
                        controls
                    }
                    .padding(.bottom, Theme.Spacing.xs)
                }
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    title
                    controls
                }
            }
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, Theme.Spacing.s)
        .contextMenu { DashboardDeviceMenuItems(perform: perform) }
    }

    /// The part that opens the device's history.
    private var title: some View {
        Button(action: open) {
            DashboardDeviceTitle(title: row.name, subtitle: row.subtitle, isOnline: false, subtitleLines: 2)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(DashboardOfflineRowStyle())
        .accessibilityLabel(row.name)
        .accessibilityValue(DashboardStrings.offlineSummary(row.subtitle))
        .accessibilityHint(OfflineDeviceListModel.rowHint)
        .accessibilityIdentifier(DashboardID.row(row.id))
    }

    @ViewBuilder
    private var controls: some View {
        if row.canWake {
            Button(action: wake) {
                // As wide as its widest title, so the row does not shift while it changes.
                ZStack {
                    ForEach(WakeButtonState.allCases, id: \.self) { state in
                        Text(state.title)
                            .opacity(state == wakeState ? 1 : 0)
                            .accessibilityHidden(state != wakeState)
                    }
                }
            }
            .buttonStyle(.dm(size: .small))
            .disabled(!wakeState.isEnabled)
            .accessibilityLabel(wakeState.title)
            .accessibilityHint(WakeButtonState.hint)
            .accessibilityIdentifier(DashboardID.wake(row.id))
        }
        DashboardDeviceMenuButton(identifier: DashboardID.menu(row.id), perform: perform)
    }
}

/// A row that darkens while pressed (`.off-row:hover`).
private struct DashboardOfflineRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

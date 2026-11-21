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

    var body: some View {
        // The hub's heartbeat keeps "last seen 5m ago" current while the list is open.
        let _ = store.lastStatusAt
        let model = OfflineDeviceListModel(
            devices: store.offlineDevices, latestVersions: store.latestVersions, now: store.clock.now, locale: DashboardLocale.names)
        NavigationStack {
            ScrollView {
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
        // The size of the popover; a sheet takes its detents instead.
        .frame(minWidth: 320, idealWidth: 380, minHeight: 220, idealHeight: min(560, 110 + 76 * CGFloat(max(1, model.rows.count))))
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
        }
        #endif
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
        // Starts with "offline", which is all a card-less device is to a glance or a UI test.
        .accessibilityValue("offline, \(row.subtitle)")
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

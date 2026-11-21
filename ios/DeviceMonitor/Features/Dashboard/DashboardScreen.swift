import DMCore
import SwiftUI

/// The Devices tab: the dashboard's main page (public/index.html). Its header (logo, product name,
/// "3 of 4 devices online", "+") is the navigation bar; below it the grid of cards for the devices
/// that are online. The offline ones are a list behind the summary.
///
/// In a regular-width window the logo, name and summary head the page instead of the bar: on an
/// iPad the tab bar floats where a bar's title would go, and the summary is the only way to the
/// offline list.
struct DashboardScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showsOfflineList = false
    /// The rename and remove questions of the cards' menus. The offline list has its own.
    @State private var actions = DashboardDeviceActionModel()

    /// Where the logo, name and summary go.
    static func headerPlacement(for sizeClass: UserInterfaceSizeClass?) -> DashboardTitleBar.Placement {
        #if DEBUG
        if let forced = DashboardDebugOptions.current.header { return forced == "page" ? .page : .navigationBar }
        #endif
        return sizeClass == .regular ? .page : .navigationBar
    }

    var body: some View {
        let placement = Self.headerPlacement(for: horizontalSizeClass)
        DashboardGrid(showsOfflineList: $showsOfflineList)
            .environment(actions)
            // The bar shows the product instead; the tab keeps its name for the system and for tests.
            .navigationTitle(AppTab.devices.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if placement == .navigationBar {
                    ToolbarItem(placement: .principal) {
                        DashboardTitleBar(showsOfflineList: $showsOfflineList, placement: .navigationBar)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        router.showAddDevice()
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.onAccent)
                    }
                    // The dashboard's one accent-filled button (`.btn.primary`).
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityLabel(DashboardStrings.addDevice)
                    .accessibilityIdentifier(DashboardID.addButton)
                }
            }
            .dashboardDeviceActions(actions)
            // if (!list.length) showOffline(false)
            .onChange(of: store.counts.offline == 0) { _, noneOffline in
                if noneOffline { showsOfflineList = false }
            }
    }
}

/// The dashboard's header: the logo, the product name and the summary, which opens the offline list
/// when there is one. As it gets narrower the summary takes its short form ("3/4 online"), then the
/// name goes, as in a narrow browser window.
struct DashboardTitleBar: View {
    nonisolated enum Placement: Sendable {
        /// In the navigation bar of a compact-width window; the offline list is a sheet.
        case navigationBar
        /// At the head of the page in a regular-width window; the offline list is a popover.
        case page
    }

    @Binding var showsOfflineList: Bool
    let placement: Placement

    @Environment(HubStore.self) private var store
    /// The outage "Reconnecting to hub…" is shown for.
    @State private var shownOutage: Double?

    /// As long as the tab shell waits before its banner: coming back to the app reconnects in a
    /// moment, and saying so each time would only flicker.
    private static let reconnectingDelay: Duration = .milliseconds(1200)

    var body: some View {
        let outage = lostSince
        let summary = DashboardSummaryModel(
            total: store.counts.total, online: store.counts.online, isReconnecting: outage != nil && outage == shownOutage)
        ViewThatFits(in: .horizontal) {
            row(summary, text: summary.text, showsName: true)
            row(summary, text: summary.compactText, showsName: true)
            row(summary, text: summary.compactText, showsName: false)
        }
        .popover(isPresented: $showsOfflineList) {
            // A sheet needs a way out of its own.
            DashboardOfflineList(showsDone: placement == .navigationBar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A bar does not grow with the text; past this size the system's large-content viewer takes over.
        .dynamicTypeSize(...(placement == .navigationBar ? DynamicTypeSize.xLarge : .accessibility5))
        .task(id: outage) {
            guard let outage else {
                shownOutage = nil
                return
            }
            try? await Task.sleep(for: Self.reconnectingDelay)
            if !Task.isCancelled { shownOutage = outage }
        }
    }

    private var lostSince: Double? {
        if case .reconnecting(let since) = store.connection { since } else { nil }
    }

    private func row(_ summary: DashboardSummaryModel, text: String, showsName: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                DashboardLogoGlyph()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 22)
                if showsName {
                    Text(DashboardStrings.productName)
                        .dmFont(.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DashboardStrings.productName)
            .accessibilityAddTraits(.isHeader)
            .accessibilityShowsLargeContentViewer {
                Text(DashboardStrings.productName)
            }
            DashboardSummaryControl(summary: summary, text: text, isOpen: showsOfflineList) {
                showsOfflineList = true
            }
        }
    }
}

/// The summary line (`#summary`): plain text, or a button with a chevron while some device is offline.
private struct DashboardSummaryControl: View {
    let summary: DashboardSummaryModel
    /// The form that fits: the full sentence or the short one.
    let text: String
    let isOpen: Bool
    let open: () -> Void

    var body: some View {
        if summary.hasOfflineDevices {
            Button(action: open) {
                HStack(spacing: Theme.Spacing.xs) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
            }
            .buttonStyle(DashboardSummaryButtonStyle(isOpen: isOpen))
            .accessibilityLabel(spokenText)
            .accessibilityHint(DashboardSummaryModel.offlineListHint)
            .accessibilityShowsLargeContentViewer { Text(spokenText) }
            .accessibilityIdentifier(DashboardID.summary)
        } else if !text.isEmpty {
            label
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.s)
                .accessibilityLabel(spokenText)
                .accessibilityShowsLargeContentViewer { Text(spokenText) }
                .accessibilityIdentifier(DashboardID.summary)
        }
    }

    private var label: some View {
        Text(text)
            .dmFont(.statValue)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    /// The whole sentence, also where only "3/4 online" fits.
    private var spokenText: String {
        summary.text.isEmpty ? text : summary.text
    }
}

/// `.summary.has-off`: quiet text that gets a plate while pressed or open, with a 44-point target.
private struct DashboardSummaryButtonStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isLit = configuration.isPressed || isOpen
        configuration.label
            .foregroundStyle(isLit ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: 28)
            .background(isLit ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .animation(.easeOut(duration: 0.12), value: isLit)
    }
}

/// The dashboard's logo: a monitor with a rising line (the 24 × 24 SVG of `.logo`).
nonisolated struct DashboardLogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        // <rect x="3" y="4" width="18" height="12" rx="2"/>
        path.addRoundedRect(
            in: CGRect(origin: point(3, 4), size: CGSize(width: 18 * unit, height: 12 * unit)),
            cornerSize: CGSize(width: 2 * unit, height: 2 * unit))
        // M8 20h8 M12 16v4 M7 12l3-3 2 2 4-4
        path.move(to: point(8, 20))
        path.addLine(to: point(16, 20))
        path.move(to: point(12, 16))
        path.addLine(to: point(12, 20))
        path.move(to: point(7, 12))
        path.addLine(to: point(10, 9))
        path.addLine(to: point(12, 11))
        path.addLine(to: point(16, 7))
        return path
    }
}

#Preview("Devices") {
    NavigationStack { DashboardScreen().dmScreen() }
        .demoEnvironment()
}

#Preview("Devices, large text") {
    NavigationStack { DashboardScreen().dmScreen() }
        .demoEnvironment()
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Offline list") {
    Color.clear
        .sheet(isPresented: .constant(true)) { DashboardOfflineList(showsDone: true) }
        .demoEnvironment()
}

#Preview("A card") {
    @Previewable @State var actions = DashboardDeviceActionModel()
    @Previewable @State var reorder = DashboardReorderModel()
    let gigabyte = 1_073_741_824.0
    let device = Device(
        id: "preview", name: "Gaming PC", platform: "windows", os: "Windows 11 Pro", online: true,
        latest: Report(
            platform: "windows", uptime: 18_720, appVersion: "1.2.33",
            cpu: Report.CPU(name: "AMD Ryzen 9 9950X3D", usage: 28, clockMHz: 5200, temp: 59),
            memory: Report.Memory(total: 64 * gigabyte, used: 27.6 * gigabyte),
            disks: [Report.Disk(name: "C:", label: "Windows", total: 2048 * gigabyte, used: 1100 * gigabyte)]))
    ScrollView {
        DashboardCard(device: device, series: .empty, isDetailsOpen: true, index: 0, count: 1)
            .environment(actions)
            .environment(reorder)
            .padding()
    }
    .dmScreen()
    .demoEnvironment()
}

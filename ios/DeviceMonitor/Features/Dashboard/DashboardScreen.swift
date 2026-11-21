import DMCore
import SwiftUI

/// The Devices tab: the dashboard's main page (public/index.html). Its header (logo, product name,
/// "3 of 4 devices online", "+") comes first, then the grid of cards for the devices that are
/// online. The offline ones are a list behind the summary.
///
/// From iOS 26 the header is the first line of the page and scrolls away with the cards; the tab
/// has no navigation bar, like the other tabs (`dmTitledPage()`). Before that it is the navigation
/// bar, except in a window the size of an iPad's, where the logo, name and summary are a row of
/// their own pinned above the cards like the dashboard's sticky header: there the tab bar floats
/// where a bar's title would go, and the summary is the only way to the offline list.
struct DashboardScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showsOfflineList = false
    /// The rename and remove questions of the cards' menus. The offline list has its own.
    @State private var actions = DashboardDeviceActionModel()

    /// Where the logo, name and summary go. Before iOS 26 a row of their own takes height from the
    /// cards for good, so a phone on its side keeps them in the bar: its width may be regular too,
    /// but its tab bar is at the bottom and the bar is free.
    static func headerPlacement(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> DashboardTitleBar.Placement {
        if #available(iOS 26, *) { return .page }
        #if DEBUG
        if let forced = DashboardDebugOptions.current.header { return forced == "pinned" ? .pinned : .navigationBar }
        #endif
        return horizontal == .regular && vertical == .regular ? .pinned : .navigationBar
    }

    var body: some View {
        let placement = Self.headerPlacement(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
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
                // Before iOS 26: from iOS 26 the page has no navigation bar, and "+" ends its header.
                ToolbarItem(placement: .primaryAction) {
                    DashboardAddButton()
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
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
        /// The first line of the page, which scrolls away with the cards (`DashboardPageHeader`),
        /// from iOS 26; the offline list is a popover, a sheet in a compact width.
        case page
        /// In the navigation bar, before iOS 26; the offline list is a sheet.
        case navigationBar
        /// In a row pinned above the page (`DashboardPinnedHeader`), before iOS 26, in a window
        /// that is regular both ways; the offline list is a popover.
        case pinned
    }

    @Binding var showsOfflineList: Bool
    let placement: Placement

    @Environment(HubStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The height of the summary's plate, which is the tallest thing in the row.
    static let summaryHeight: CGFloat = 28

    var body: some View {
        // The dashboard puts "Reconnecting to hub…" in place of this summary while its stream is
        // down (`#summaryText`). Here the tab shell's banner says it, on every tab, so the summary
        // keeps the last known count rather than say it a second time.
        let summary = DashboardSummaryModel(total: store.counts.total, online: store.counts.online)
        ViewThatFits(in: .horizontal) {
            row(summary, text: summary.text, showsName: true)
            row(summary, text: summary.compactText, showsName: true)
            row(summary, text: summary.compactText, showsName: false)
        }
        .popover(isPresented: $showsOfflineList) {
            DashboardOfflineList(showsDone: isListASheet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A bar does not grow with the text, and a row only so far: what the pinned one takes, the
        // cards lose. Past this size the system's large-content viewer takes over.
        .dynamicTypeSize(...(placement == .navigationBar ? DynamicTypeSize.xLarge : .accessibility1))
    }

    /// A sheet needs a way out of its own; a popover is left with a tap beside it.
    private var isListASheet: Bool {
        switch placement {
        case .navigationBar: true
        case .page: horizontalSizeClass == .compact
        case .pinned: false
        }
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

/// The header as the first line of the page, from iOS 26: the logo, name and summary, and "+" at
/// the end of the line. It scrolls away with the cards, as the other tabs' titles do (`DMPageTitle`).
struct DashboardPageHeader: View {
    @Binding var showsOfflineList: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            DashboardTitleBar(showsOfflineList: $showsOfflineList, placement: .page)
                // As tall before the first device as with a summary, so the cards never shift for it.
                .frame(minHeight: DashboardTitleBar.summaryHeight)
            DashboardAddButton()
                .buttonStyle(.dmIcon(.primary))
        }
    }
}

/// "Add a device": the dashboard's one accent-filled button (`.btn.primary`).
private struct DashboardAddButton: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.showAddDevice()
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.onAccent)
        }
        .accessibilityLabel(DashboardStrings.addDevice)
        .accessibilityIdentifier(DashboardID.addButton)
    }
}

/// Before iOS 26, the header as a row of its own that stays put while the cards scroll away under
/// it (`header { position: sticky; top: 0 }` in public/index.html).
struct DashboardPinnedHeader: View {
    @Binding var showsOfflineList: Bool
    /// The page's side padding: the row lines up with the cards.
    let padding: CGFloat

    var body: some View {
        DashboardTitleBar(showsOfflineList: $showsOfflineList, placement: .pinned)
            // As tall before the first device as with a summary, so the cards never shift for it.
            .frame(minHeight: DashboardTitleBar.summaryHeight)
            .padding(.horizontal, padding)
            .padding(.vertical, Theme.Spacing.s)
            // background: rgba(13,13,13,0.9); backdrop-filter: blur(8px). Up to the top of the
            // screen, so that no card shows again above the row, behind the tab bar.
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Theme.page.opacity(0.9))
                    .ignoresSafeArea(edges: [.top, .horizontal])
            }
            // border-bottom: 1px solid var(--border)
            .overlay(alignment: .bottom) { Hairline() }
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
            .frame(minHeight: DashboardTitleBar.summaryHeight)
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

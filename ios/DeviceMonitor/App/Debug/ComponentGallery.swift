#if DEBUG
import SwiftUI

/// Every design-system component with realistic values, for comparing the app with
/// docs/screenshots/*.png. Debug builds only.
struct ComponentGallery: View {
    /// Where to scroll when the gallery opens (`-dm-gallery <id>`). Sections: cards, gauges, pills,
    /// chart, stats, kv, tiles, buttons, selection, banners, empty, settings, colours, type, extremes.
    /// Single cards: card-details, card-offline.
    var initialSection: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Fixed when the gallery opens, so the charts do not shift while it is being looked at.
    @State private var now = Date.now.timeIntervalSince1970 * 1000
    @State private var historyRange = "24h"
    @State private var advancedRange = "7d"
    @State private var priceMode = "tou"
    @State private var unit = "C"
    @State private var selectedDevice = "DGX Spark"
    @State private var notifications = true
    @State private var quietHours = false
    @State private var deviceName = "iPhone"
    @State private var chartSelection: MiniChartSelection?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    cards
                    gauges
                    pills
                    chart
                    stats
                    keyValues
                    tiles
                    buttons
                    selection
                    banners
                    emptyStates
                    settings
                    colours
                    textStyles
                    outOfRange
                }
                .frame(maxWidth: Theme.Layout.maxContentWidth, alignment: .leading)
                .padding(Theme.Layout.screenPadding(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            }
            .task {
                // The first section is where the gallery opens anyway.
                guard let initialSection, initialSection != "cards" else { return }
                // Once the push has settled; a scroll requested during it is dropped.
                try? await Task.sleep(for: .milliseconds(400))
                scroll.scrollTo(initialSection, anchor: .top)
            }
        }
        .navigationTitle("Components")
        .navigationBarTitleDisplayMode(.inline)
        .dmScreen()
        .accessibilityIdentifier("gallery-screen")
    }

    // MARK: Sections

    /// The device grid's rule: as many columns of at least 290 points as fit.
    private var cards: some View {
        section("Device cards", id: "cards") {
            EagerCardGrid(minimumColumnWidth: Theme.Layout.cardMinWidth, spacing: Theme.Layout.gridSpacing) {
                MockDeviceCard(device: .gamingPC, windowEnd: now)
                MockDeviceCard(device: .dgxSpark, windowEnd: now, showsDetails: true)
                    .id("card-details")
                MockDeviceCard(device: .homeServer, windowEnd: now)
                    .id("card-offline")
            }
        }
    }

    private var gauges: some View {
        section("Gauges", id: "gauges") {
            DMCard {
                GaugeRow {
                    GaugeColumn(value: 28, label: "CPU", color: Theme.cpu, caption: .temperature("59°C", .normal))
                    GaugeColumn(value: 81, label: "GPU", color: Theme.gpu, caption: .temperature("75°C", .warm))
                    GaugeColumn(value: 46, label: "Memory", color: Theme.mem, caption: .text("27.6 / 60 GB"))
                }
                GaugeRow {
                    GaugeColumn(value: 100, label: "CPU", color: Theme.cpu, caption: .temperature("91°C", .hot))
                    GaugeColumn(value: nil, label: "GPU", color: Theme.gpu, caption: .hint("no GPU"))
                    GaugeColumn(value: 0, label: "Memory", color: Theme.mem, caption: .hint("offline"))
                }
            }
        }
    }

    private var pills: some View {
        section("Temperature pills, hints, status", id: "pills") {
            DMCard {
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    TempPill("59°C", level: .normal)
                    TempPill("75°C", level: .warm)
                    TempPill("91°C", level: .hot)
                    TempPill("138°F", level: .normal)
                }
                HStack(spacing: Theme.Spacing.l) {
                    GaugeHint("no sensor")
                    GaugeHint("no GPU")
                    GaugeHint("offline")
                }
                HStack(spacing: Theme.Spacing.l) {
                    statusSample(isOnline: true)
                    statusSample(isOnline: false)
                }
            }
        }
    }

    private func statusSample(isOnline: Bool) -> some View {
        HStack(spacing: 9) {
            StatusDot(isOnline: isOnline)
            Text(isOnline ? "online" : "offline")
                .dmFont(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var chart: some View {
        section("Mini chart with scrubbing", id: "chart") {
            DMCard {
                LegendRow([("CPU", Theme.cpu), ("GPU", Theme.gpu), ("Memory", Theme.mem)]) {
                    Text("hold and drag")
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                MiniChart(
                    series: gappedSeries,
                    windowEnd: now,
                    windowSpan: 60 * 60_000,
                    gapInterval: MiniChartGeometry.gapInterval(resolution: 10_000),
                    selection: $chartSelection,
                    scrubPreview: 0.72
                )
                .chartTooltip(for: chartSelection, placement: .inside) { selection in
                    ChartTooltip(title: selection.date.formatted(date: .omitted, time: .shortened), rows: selection.entries.map {
                        ChartTooltipRow(id: $0.id, label: $0.label, value: Theme.percentText($0.value), detail: $0.id == "cpu" ? "59°C" : nil, color: $0.color)
                    })
                }
                .accessibilityIdentifier("gallery-mini-chart")
            }
        }
    }

    /// The gaming PC's lines with ten minutes missing, to show how a gap is drawn.
    private var gappedSeries: [MiniChartSeries] {
        MockDevice.gamingPC.series(endingAt: now).map { line in
            var line = line
            line.points.removeSubrange(150..<210)
            return line
        }
    }

    private var stats: some View {
        section("Stats and bars", id: "stats") {
            DMCard {
                StatsGrid {
                    StatCell("CPU", value: "AMD Ryzen 9 9950X3D · 5.20 GHz")
                    StatCell("GPU", value: "GeForce RTX 5090 · 465 W")
                    StatCell("VRAM", value: "23.4 GB / 30 GB", percent: 78, barColor: Theme.gpu)
                    StatCell("Disk C:", value: "1 TB / 2 TB", percent: 50)
                    StatCell("Network", value: "↓ 1.5 MB/s  ↑ 232 KB/s")
                    StatCell("Disk I/O", value: "R 2.9 MB/s  W 5.5 MB/s")
                }
                Hairline()
                HStack(spacing: Theme.Spacing.m) {
                    Text("67%").dmFont(.callout).foregroundStyle(Theme.textPrimary)
                    MeterBar(percent: 67, color: Theme.cpu, height: 6, accessibilityLabel: "Share of energy").frame(width: 60)
                    Text("25%").dmFont(.callout).foregroundStyle(Theme.textPrimary)
                    MeterBar(percent: 25, color: Theme.gpu, height: 6, accessibilityLabel: "Share of energy").frame(width: 60)
                }
            }
        }
    }

    private var keyValues: some View {
        section("Key–value rows", id: "kv") {
            DMCard {
                SectionLabel("Loaded models")
                SubsectionHeader("ComfyUI", detail: "57.7 GB GPU memory")
                KeyValueRows([
                    KeyValueItem("flux2_dev_fp8.safetensors", "22.2 GB", detail: "unet"),
                    KeyValueItem("qwen3_vl_8b_instruct_abliterated_q8.safetensors", "15.3 GB", detail: "clip"),
                ], style: .valueFirst)
                SectionLabel("Temperature sensors")
                KeyValueRows([
                    KeyValueItem("CPU Package", "64°C"),
                    KeyValueItem("Motherboard", "41°C"),
                    KeyValueItem("Model", "NVIDIA GeForce RTX 5090 Workstation Edition"),
                ])
            }
        }
    }

    private var tiles: some View {
        section("Tiles", id: "tiles") {
            TileGrid {
                Tile(label: "CPU", value: "44%", sub: "peak · avg 18%", tickColor: Theme.cpu)
                Tile(label: "GPU", value: "98%", sub: "peak · avg 88%", tickColor: Theme.gpu)
                Tile(label: "Memory", value: "89%", sub: "peak · avg 86%", tickColor: Theme.mem)
                Tile(label: "CPU temp", value: "69°C", sub: "peak · avg 62°C", tickColor: Theme.cpu)
                Tile(label: "Drawing now", value: "896 W", sub: "$6.80 a day at this rate")
                Tile(label: "Per month", value: "$186", sub: "≈ 588 kWh at the recent average")
            }
        }
    }

    private var buttons: some View {
        section("Buttons", id: "buttons") {
            DMCard {
                FlowLayout(spacing: 8, lineSpacing: 10) {
                    Button("Try again") {}.buttonStyle(.dm(.primary))
                    Button("Change setup") {}.buttonStyle(.dm())
                    Button("Remove") {}.buttonStyle(.dm(.destructive))
                    Button("Disabled") {}.buttonStyle(.dm(.primary)).disabled(true)
                }
                FlowLayout(spacing: 8, lineSpacing: 10) {
                    Button("Wake") {}.buttonStyle(.dm(size: .small))
                    Button {} label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.dm(size: .small))
                    Button("Reset zoom") {}.buttonStyle(.dm(size: .small))
                }
                Button("Pair with hub") {}.buttonStyle(.dm(.primary, size: .large, fillsWidth: true))
                HStack(spacing: 6) {
                    Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.dmIcon).accessibilityLabel("Device options")
                    Button {} label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.dmIcon(.active)).accessibilityLabel("History")
                    Button {} label: { Image(systemName: "plus") }.buttonStyle(.dmIcon(.primary)).accessibilityLabel("Add device")
                }
            }
        }
    }

    private var selection: some View {
        section("Segmented control and chips", id: "selection") {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                DMSegmentedControl("Time range", selection: $historyRange, segments: [
                    DMSegment("1h", "1 h", identifier: "1h"), DMSegment("6h", "6 h", identifier: "6h"),
                    DMSegment("24h", "24 h", identifier: "24h"), DMSegment("7d", "7 days", identifier: "7d"),
                    DMSegment("30d", "30 days", identifier: "30d"),
                ], identifier: "gallery-range")
                DMSegmentedControl("Time range", selection: $advancedRange, segments: [
                    DMSegment("24h", "24 h"), DMSegment("7d", "7 days"), DMSegment("30d", "30 days"),
                ], fillsWidth: true)
                // Too narrow for its labels side by side, as the price editor is at the largest
                // text sizes on a phone.
                DMSegmentedControl("Electricity price", selection: $priceMode, segments: [
                    DMSegment("flat", "One rate", identifier: "flat"), DMSegment("tou", "Time of use", identifier: "tou"),
                ], identifier: "gallery-narrow")
                .frame(width: 150)
                FlowLayout {
                    ForEach(["Gaming PC", "DGX Spark", "MacBook Pro", "Home Server"], id: \.self) { name in
                        DeviceChip(name, isOnline: name != "Home Server", isSelected: name == selectedDevice) {
                            selectedDevice = name
                        }
                    }
                }
            }
        }
    }

    private var banners: some View {
        section("Banners", id: "banners") {
            VStack(spacing: Theme.Spacing.s) {
                BannerView("Reconnecting to hub…", showsProgress: true)
                BannerView("Device Monitor 1.2.32 is available for this hub.", kind: .warning, systemImage: "arrow.down.to.line", actionTitle: "Details") {}
                BannerView("Wake signal sent to Home Server.", kind: .success)
                BannerView("Could not save the electricity price.", kind: .critical)
                BannerView("Showing demo data.", kind: .info)
            }
        }
    }

    private var emptyStates: some View {
        section("Empty states", id: "empty") {
            VStack(spacing: Theme.Spacing.m) {
                EmptyStateView(
                    title: "No devices yet",
                    message: "Tap + to add the computers you want to monitor.",
                    actionTitle: "Add a device"
                ) {}
                    .dmSurface(radius: Theme.Radius.tile)
                EmptyStateView(message: "All devices are offline.", isCompact: true)
                    .dmSurface(radius: Theme.Radius.tile)
            }
        }
    }

    private var settings: some View {
        section("Settings rows", id: "settings") {
            VStack(spacing: Theme.Spacing.l) {
                SettingsSection("Display") {
                    SettingsRow("Temperature unit") {
                        DMSegmentedControl("Temperature unit", selection: $unit, segments: [DMSegment("C", "°C"), DMSegment("F", "°F")])
                    }
                    SettingsToggleRow("Alert notifications", description: "Notify me when a device crosses one of my alert rules.", isOn: $notifications)
                    SettingsToggleRow("Quiet hours", isOn: $quietHours)
                }
                SettingsSection("Hub", footer: "Disconnecting removes this device from the hub.") {
                    SettingsRow("Address", description: "https://hub.example.ts.net", isMonospaced: true)
                    SettingsRow("This device", layout: .stacked) {
                        TextField("Name", text: $deviceName)
                            .textFieldStyle(.plain)
                            .dmField()
                    }
                    SettingsRow("Dashboard link", description: "Copy a single-use browser invitation.") {
                        Button("Copy") {}.buttonStyle(.dm(size: .small))
                    }
                }
                MonoBlock("https://hub.example.ts.net/unlock#join=3q2-7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            }
        }
    }

    private var colours: some View {
        section("Colours", id: "colours") {
            DMCard {
                swatches([("page", Theme.page), ("surface1", Theme.surface1), ("surface2", Theme.surface2), ("grid", Theme.grid), ("axis", Theme.axis)])
                swatches([("cpu", Theme.cpu), ("gpu", Theme.gpu), ("mem", Theme.mem), ("accent", Theme.accent), ("danger", Theme.dangerText)])
                swatches([("good", Theme.good), ("warning", Theme.warning), ("serious", Theme.serious), ("critical", Theme.critical)])
                swatches(Theme.deviceSeries.enumerated().map { ("\($0.offset + 1)", $0.element) })
            }
        }
    }

    private var textStyles: some View {
        section("Text styles", id: "type") {
            DMCard {
                ForEach(Array(DMTextStyle.allCases.enumerated()), id: \.offset) { _, style in
                    Text("\(String(describing: style)) · 0123456789")
                        .dmFont(style)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Readings no healthy agent sends. The hub relays any finite number and a ratio such as
    /// used / total can land far outside 0–100, so none of this may trap or break the layout.
    private var outOfRange: some View {
        section("Out-of-range values", id: "extremes") {
            DMCard {
                GaugeRow {
                    GaugeColumn(value: 1e23, label: "CPU", color: Theme.cpu, caption: .temperature("59°C", .normal))
                        .accessibilityIdentifier("extreme-gauge-high")
                    GaugeColumn(value: -1e23, label: "GPU", color: Theme.gpu, caption: .hint("no sensor"))
                        .accessibilityIdentifier("extreme-gauge-low")
                    GaugeColumn(value: .infinity, label: "Memory", color: Theme.mem, caption: .text("1 EB / 1 KB"))
                        .accessibilityIdentifier("extreme-gauge-infinite")
                }
                StatsGrid {
                    StatCell("VRAM", value: "1 EB / 1 KB", percent: 1e23, barColor: Theme.gpu)
                        .accessibilityIdentifier("extreme-stat-high")
                    StatCell("Disk C:", value: "0 B / 0 B", percent: .nan)
                        .accessibilityIdentifier("extreme-stat-nan")
                }
                MeterBar(percent: -1e23, color: Theme.cpu, height: 6, accessibilityLabel: "Share of energy")
                    .frame(width: 60)
                    .accessibilityIdentifier("extreme-meter-low")
                MiniChart(
                    series: [MiniChartSeries(id: "cpu", label: "CPU", color: Theme.cpu, points: [
                        MiniChartPoint(t: now - 40 * 60_000, value: 40),
                        MiniChartPoint(t: now - 30 * 60_000, value: -1e23),
                        MiniChartPoint(t: now - 20 * 60_000, value: 250),
                        MiniChartPoint(t: now - 10 * 60_000, value: 1e23),
                    ])],
                    windowEnd: now,
                    windowSpan: 60 * 60_000,
                    gapInterval: 15 * 60_000,
                    accessibilityLabel: "Out-of-range usage"
                )
                .accessibilityIdentifier("extreme-chart")
            }
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionLabel(title, size: .large)
                .accessibilityIdentifier("gallery-section-\(id)")
            content()
        }
        .id(id)
    }

    private func swatches(_ items: [(name: String, color: Color)]) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: Theme.Spacing.xs) {
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .fill(item.color)
                        .frame(height: 28)
                        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.border) }
                    Text(item.name)
                        .dmFont(.micro)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The device grid's columns, laid out eagerly: as many equal columns of at least
/// `minimumColumnWidth` as fit, each row as tall as its tallest card.
///
/// The Dashboard uses a `LazyVGrid` for this, as the direct content of its scroll view. Here the grid
/// is one section of a long eager page, and a lazy grid only estimates the height of cards it has not
/// built yet: at the largest text sizes the page was sized from that estimate and opened part-way
/// down, with its top out of reach.
private struct EagerCardGrid: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat) -> EqualColumnsLayout {
        // An unbounded proposal gets a single column; the cap keeps the division well inside Int.
        let usable = width.isFinite ? min(width, 100_000) : minimumColumnWidth
        let count = Int(((usable + spacing) / (minimumColumnWidth + spacing)).rounded(.down))
        return EqualColumnsLayout(columns: max(1, count), columnSpacing: spacing, rowSpacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        columns(for: proposal.width ?? minimumColumnWidth).sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        columns(for: bounds.width).placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

#Preview {
    NavigationStack { ComponentGallery() }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}
#endif

#if DEBUG
import SwiftUI

/// Made-up devices for the component gallery, with the values of docs/screenshots so the result can
/// be compared with dashboard.png and card-details.png side by side.
struct MockDevice: Identifiable {
    struct Stat: Identifiable {
        let key: String
        let value: String
        var percent: Double?
        var barColor: Color = Theme.textSecondary
        var id: String { key }
    }

    struct ModelGroup: Identifiable {
        let app: String
        let memory: String
        let models: [KeyValueItem]
        var id: String { app }
    }

    let id: String
    let name: String
    let subtitle: String
    let isOnline: Bool
    let cpu: Double?
    let cpuCaption: GaugeCaption
    let gpu: Double?
    let gpuCaption: GaugeCaption
    let memory: Double?
    let memoryCaption: GaugeCaption
    /// Level and swing of the chart lines: CPU, GPU, memory. `nil` leaves the line out.
    let chart: [(base: Double, swing: Double)?]
    let stats: [Stat]
    var models: [ModelGroup] = []
    var gpuRows: [KeyValueItem] = []
    var drives: [Stat] = []

    static let gamingPC = MockDevice(
        id: "gaming-pc",
        name: "Gaming PC",
        subtitle: "Windows 11 Pro · up 5h 12m · v1.2.27",
        isOnline: true,
        cpu: 28, cpuCaption: .temperature("59°C", .normal),
        gpu: 81, gpuCaption: .temperature("66°C", .normal),
        memory: 46, memoryCaption: .text("27.6 / 60 GB"),
        chart: [(22, 7), (74, 10), (46, 0.6)],
        stats: [
            Stat(key: "CPU", value: "AMD Ryzen 9 9950X3D · 5.20 GHz"),
            Stat(key: "GPU", value: "GeForce RTX 5090 · 465 W"),
            Stat(key: "VRAM", value: "23.4 GB / 30 GB", percent: 78, barColor: Theme.gpu),
            Stat(key: "Disk C:", value: "1 TB / 2 TB", percent: 50),
            Stat(key: "Network", value: "↓ 1.5 MB/s  ↑ 232 KB/s"),
            Stat(key: "Disk I/O", value: "R 2.9 MB/s  W 5.5 MB/s"),
        ],
        gpuRows: [
            KeyValueItem("Model", "NVIDIA GeForce RTX 5090"),
            KeyValueItem("Load", "81%"),
            KeyValueItem("Temperature", "66°C"),
            KeyValueItem("VRAM", "23.4 GB / 30 GB"),
            KeyValueItem("Power", "465 W / 600 W"),
        ],
        drives: [
            Stat(key: "C: · System", value: "1 TB / 2 TB · 50%", percent: 50),
            Stat(key: "D: · Games", value: "3 TB / 4 TB · 75%", percent: 75),
        ]
    )

    static let dgxSpark = MockDevice(
        id: "dgx-spark",
        name: "DGX Spark",
        subtitle: "Ubuntu 24.04 LTS · up 12d 0h · v1.2.27",
        isOnline: true,
        cpu: 23, cpuCaption: .temperature("64°C", .normal),
        gpu: 95, gpuCaption: .temperature("75°C", .warm),
        memory: 87, memoryCaption: .text("104 / 119 GB"),
        chart: [(21, 4), (92, 2.5), (87, 0.4)],
        stats: [
            Stat(key: "CPU", value: "NVIDIA Grace (Cortex-X925 + Cortex-A725)"),
            Stat(key: "GPU", value: "GB10 · 130 W"),
            Stat(key: "Disk /", value: "2 TB / 4 TB", percent: 57),
            Stat(key: "Network", value: "↓ 1.5 MB/s  ↑ 53 KB/s"),
            Stat(key: "Disk I/O", value: "R 15.0 MB/s  W 7.6 MB/s"),
        ],
        models: [
            ModelGroup(app: "ComfyUI", memory: "57.7 GB GPU memory", models: [
                KeyValueItem("flux2_dev_fp8.safetensors", "22.2 GB", detail: "unet"),
                KeyValueItem("qwen3_vl_8b.safetensors", "15.3 GB", detail: "clip"),
                KeyValueItem("flux2_vae.safetensors", "324.2 MB", detail: "vae"),
            ]),
            ModelGroup(app: "Ollama", memory: "19.6 GB GPU memory", models: [
                KeyValueItem("qwen3:32b", "18.7 GB"),
            ]),
        ],
        gpuRows: [
            KeyValueItem("Model", "NVIDIA GB10"),
            KeyValueItem("Load", "95%"),
            KeyValueItem("Temperature", "75°C"),
            KeyValueItem("Power", "130 W / 140 W"),
            KeyValueItem("Core clock", "2686 MHz"),
            KeyValueItem("Fan", "68%"),
        ],
        drives: [
            Stat(key: "/", value: "2 TB / 4 TB · 57%", percent: 57),
        ]
    )

    /// What `zeroed()` leaves of an offline device: zeros, hints, hardware names and sizes.
    static let homeServer = MockDevice(
        id: "home-server",
        name: "Home Server",
        subtitle: "Debian 13 · offline · last seen 3h ago · v1.2.27",
        isOnline: false,
        cpu: 0, cpuCaption: .hint("offline"),
        gpu: nil, gpuCaption: .hint("no GPU"),
        memory: 0, memoryCaption: .text("0 / 30 GB"),
        chart: [nil, nil, nil],
        stats: [
            Stat(key: "CPU", value: "Intel Core i5-13500"),
            Stat(key: "Disk /", value: "112 GB / 466 GB", percent: 24),
            Stat(key: "Network", value: "↓ 0 B/s  ↑ 0 B/s"),
            Stat(key: "Disk I/O", value: "R 0 B/s  W 0 B/s"),
        ]
    )

    /// An hour of samples, one every ten seconds, ending at `end`. Seeded, so it never changes.
    func series(endingAt end: Double) -> [MiniChartSeries] {
        let lines: [(id: String, label: String, color: Color)] = [("cpu", "CPU", Theme.cpu), ("gpu", "GPU", Theme.gpu), ("mem", "Memory", Theme.mem)]
        var seed = id.stableHash
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 40) / Double(1 << 24) - 0.5
        }
        return zip(lines, chart).compactMap { line, shape in
            guard let shape else { return nil }
            let points = (0..<360).map { index -> MiniChartPoint in
                let t = end - Double(359 - index) * 10_000
                let wave = sin(Double(index) / 23 + shape.base) + 0.5 * sin(Double(index) / 7.5)
                return MiniChartPoint(t: t, value: min(100, max(0, shape.base + shape.swing * 0.6 * wave + shape.swing * 0.22 * noise())))
            }
            return MiniChartSeries(id: line.id, label: line.label, color: line.color, points: points)
        }
    }
}

private extension String {
    /// `hashValue` changes between launches; the mock data should not.
    var stableHash: UInt64 {
        utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// A device card assembled only from design-system components, the way the Dashboard feature will.
struct MockDeviceCard: View {
    let device: MockDevice
    let windowEnd: Double
    var scrubPreview: Double?

    @State private var selection: MiniChartSelection?
    @State private var showsDetails: Bool
    @State private var range = "1h"

    init(device: MockDevice, windowEnd: Double, showsDetails: Bool = false, scrubPreview: Double? = nil) {
        self.device = device
        self.windowEnd = windowEnd
        self.scrubPreview = scrubPreview
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        DMCard(isOffline: !device.isOnline) {
            CardHeader(title: device.name, subtitle: device.subtitle, isOnline: device.isOnline) {
                Button("History") {}
                Button("Rename") {}
                Button("Remove from dashboard", role: .destructive) {}
            }

            GaugeRow {
                GaugeColumn(value: device.cpu, label: "CPU", color: Theme.cpu, caption: device.cpuCaption)
                GaugeColumn(value: device.gpu, label: "GPU", color: Theme.gpu, caption: device.gpuCaption)
                GaugeColumn(value: device.memory, label: "Memory", color: Theme.mem, caption: device.memoryCaption)
            }

            VStack(spacing: 6) {
                LegendRow([("CPU", Theme.cpu), ("GPU", Theme.gpu), ("Memory", Theme.mem)]) {
                    DMInlinePicker("Chart range", selection: $range, options: [
                        DMSegment("10m", "last 10 min"), DMSegment("1h", "last 60 min"), DMSegment("6h", "last 6 hours"),
                    ])
                }
                MiniChart(
                    series: device.series(endingAt: windowEnd),
                    windowEnd: windowEnd,
                    windowSpan: 60 * 60_000,
                    gapInterval: MiniChartGeometry.gapInterval(resolution: 10_000),
                    selection: $selection,
                    accessibilityLabel: "\(device.name) usage, last 60 minutes",
                    scrubPreview: scrubPreview
                )
                .chartTooltip(for: selection) { selection in
                    ChartTooltip(title: selection.date.formatted(date: .omitted, time: .shortened), selection: selection)
                }
            }

            StatsGrid {
                ForEach(device.stats) { stat in
                    StatCell(stat.key, value: stat.value, percent: stat.percent, barColor: stat.barColor)
                }
            }

            DetailsDisclosure(isExpanded: $showsDetails) {
                details
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-card-\(device.id)")
    }

    @ViewBuilder
    private var details: some View {
        if !device.models.isEmpty {
            DMSection("Loaded models") {
                ForEach(device.models) { group in
                    VStack(spacing: Theme.Spacing.xs) {
                        SubsectionHeader(group.app, detail: group.memory)
                        KeyValueRows(group.models, style: .valueFirst)
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        if !device.gpuRows.isEmpty {
            DMSection("GPU") {
                KeyValueRows(device.gpuRows)
            }
        }
        if !device.drives.isEmpty {
            DMSection("Drives") {
                ForEach(device.drives) { drive in
                    StatCell(drive.key, value: drive.value, percent: drive.percent)
                }
            }
        }
        if device.models.isEmpty, device.gpuRows.isEmpty, device.drives.isEmpty {
            Text("No data yet.")
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 14)
        }
    }
}

#Preview("Mock device cards") {
    ScrollView {
        VStack(spacing: Theme.Layout.gridSpacing) {
            MockDeviceCard(device: .dgxSpark, windowEnd: Date.now.timeIntervalSince1970 * 1000, showsDetails: true)
            MockDeviceCard(device: .homeServer, windowEnd: Date.now.timeIntervalSince1970 * 1000)
        }
        .padding(Theme.Layout.screenPaddingCompact)
    }
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
#endif

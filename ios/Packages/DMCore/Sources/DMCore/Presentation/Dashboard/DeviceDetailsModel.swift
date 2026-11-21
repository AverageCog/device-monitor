import Foundation

/// What a card shows under "Details" (detailHtml and aiHtml in public/index.html): loaded AI
/// models, a block per GPU, drives, temperature sensors and fans, each only when the device has
/// something to list.
public struct DeviceDetailsModel: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let kind: Kind
        /// The section's heading; the dashboard shows it in capitals. nil for a hint.
        public let title: String?
        public let content: Content

        public var id: Kind { kind }
    }

    public enum Kind: Sendable, Hashable {
        case loadedModels
        /// The index is the GPU's position in the report, as in the heading "GPU 1".
        case gpu(Int)
        case drives
        case temperatureSensors
        case fans
        /// The note about LibreHardwareMonitor.
        case sensorHint
        /// "No data yet.": the only section when there is nothing else.
        case noData
    }

    public enum Content: Sendable, Equatable {
        /// Apps holding AI models. With no apps, `emptyText` ("No AI models loaded") stands in.
        case models(apps: [AIApp], emptyText: String?)
        /// Label and value pairs: a GPU's readings, temperature sensors, fans.
        case rows([Row])
        /// One stat with a bar per drive.
        case drives([DeviceStat])
        /// A sentence in the muted hint style. `emphasis` is the part the dashboard sets in bold.
        case hint(text: String, emphasis: String?)
    }

    /// An app with models in memory (Ollama, LM Studio, ComfyUI…).
    public struct AIApp: Sendable, Equatable, Identifiable {
        /// Position in the report.
        public let id: Int
        public let name: String
        /// "4.8 GB GPU memory", shown at the end of the app's line; empty when the app reports none.
        public let memory: String
        public let models: [AIModel]
        /// "Model name not available": shown in place of the list when the app names no model.
        public let placeholder: String?
    }

    public struct AIModel: Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        /// What the app uses the model as ("unet", "clip", "vae"), written small after the name.
        public let kind: String?
        /// Size of the model file, or an en dash.
        public let size: String
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: Int
        public let label: String
        /// Secondary text for the label: the hardware a temperature sensor belongs to. The
        /// dashboard shows it on hover.
        public let detail: String?
        public let value: String
    }

    public static let noDataText = "No data yet."
    public static let noModelsText = "No AI models loaded"
    public static let modelNameUnavailableText = "Model name not available"
    public static let sensorHintText = "CPU temperature, fans and motherboard sensors appear here if LibreHardwareMonitor is running on this PC."
    public static let sensorHintEmphasis = "LibreHardwareMonitor"

    /// In the order shown. Never empty: with nothing to list it holds the "No data yet." hint.
    public let sections: [Section]

    public init(device: Device, unit: TemperatureUnit) {
        self.init(reading: DeviceReading(device: device), unit: unit)
    }

    public init(reading: DeviceReading, unit: TemperatureUnit) {
        let L = reading.report
        var sections = [Section]()

        // let h = aiHtml(L.ai);
        if let ai = L.ai {
            sections.append(Section(kind: .loadedModels, title: "Loaded models", content: DeviceDetailsModel.models(ai)))
        }

        // for (const [i, g] of (L.gpus || []).entries()) { … }
        for (i, g) in L.gpus.enumerated() {
            // const rows = [['Model', esc(g.name)], ['Load', fmtPct(g.usage)], ['Temperature', fmtTemp(g.temp)]];
            var rows = [("Model", g.name ?? ""), ("Load", Format.fmtPct(g.usage)), ("Temperature", Format.fmtTemp(g.temp, unit))]
            // if (g.memTotal) rows.push(['VRAM', `${fmtBytes(g.memUsed)} / ${fmtBytes(g.memTotal, 0)}`]);
            if DashJS.number(g.memTotal) != nil { rows.append(("VRAM", DeviceCardModel.vramText(g))) }
            // if (g.power != null) rows.push(['Power', `${Math.round(g.power)} W${g.powerLimit ? ' / ' + Math.round(g.powerLimit) + ' W' : ''}`]);
            if let power = g.power {
                let limit = DashJS.number(g.powerLimit).map { " / " + JS.string(JS.round($0)) + " W" } ?? ""
                rows.append(("Power", JS.string(JS.round(power)) + " W" + limit))
            }
            // if (g.clockMHz != null) rows.push(['Core clock', `${Math.round(g.clockMHz)} MHz`]);
            if let clock = g.clockMHz { rows.append(("Core clock", JS.string(JS.round(clock)) + " MHz")) }
            // if (g.fan != null) rows.push(['Fan', fmtPct(g.fan)]);
            if let fan = g.fan { rows.append(("Fan", Format.fmtPct(fan))) }
            // <h4>GPU ${(L.gpus.length > 1) ? i : ''}</h4>
            sections.append(Section(
                kind: .gpu(i), title: L.gpus.count > 1 ? "GPU \(i)" : "GPU",
                content: .rows(rows.enumerated().map { Row(id: $0.offset, label: $0.element.0, detail: nil, value: $0.element.1) })
            ))
        }

        // if (L.disks?.length) … stat(esc(d.name + (d.label ? ' · ' + d.label : '')), `${fmtBytes(d.used, 0)} / ${fmtBytes(d.total, 0)} · ${fmtPct(d.used / d.total * 100)}`, d.used / d.total * 100)
        if !L.disks.isEmpty {
            let drives = L.disks.enumerated().map { index, d in
                let ratio = (d.used ?? 0) / (d.total ?? 0) * 100
                return DeviceStat(
                    // A drive without a name reads "null", as string concatenation makes it in the dashboard.
                    id: "drive-\(index)", key: (d.name ?? "null") + (DashJS.text(d.label).map { " \u{B7} " + $0 } ?? ""),
                    value: Format.fmtBytes(d.used, 0) + " / " + Format.fmtBytes(d.total, 0) + " \u{B7} " + Format.fmtPct(ratio),
                    ratio: ratio
                )
            }
            sections.append(Section(kind: .drives, title: "Drives", content: .drives(drives)))
        }

        // if (L.temps?.length) … <span title="${esc(t.parent)}">${esc(t.name)}</span><span>${fmtTemp(t.value)}</span>
        if !L.temps.isEmpty {
            let rows = L.temps.enumerated().map { index, t in
                Row(id: index, label: t.name ?? "", detail: DashJS.text(t.parent), value: Format.fmtTemp(t.value, unit))
            }
            sections.append(Section(kind: .temperatureSensors, title: "Temperature sensors", content: .rows(rows)))
        }

        // if (L.fans?.length) … <span>${esc(f.name)}</span><span>${f.rpm == null ? '–' : Math.round(f.rpm)} RPM</span>
        if !L.fans.isEmpty {
            let rows = L.fans.enumerated().map { index, f in
                Row(id: index, label: f.name ?? "", detail: nil, value: (f.rpm.map { JS.string(JS.round($0)) } ?? Format.dash) + " RPM")
            }
            sections.append(Section(kind: .fans, title: "Fans", content: .rows(rows)))
        }

        // if (!L.offline && !L.temps?.length && L.platform === 'windows' && L.cpu?.temp == null)
        if !reading.isOffline && L.temps.isEmpty && L.platform == "windows" && L.cpu.temp == nil {
            sections.append(Section(
                kind: .sensorHint, title: nil,
                content: .hint(text: DeviceDetailsModel.sensorHintText, emphasis: DeviceDetailsModel.sensorHintEmphasis)
            ))
        }

        // return h || '<div class="section hint">No data yet.</div>';
        if sections.isEmpty {
            sections.append(Section(kind: .noData, title: nil, content: .hint(text: DeviceDetailsModel.noDataText, emphasis: nil)))
        }
        self.sections = sections
    }

    // function aiHtml(ai)
    private static func models(_ ai: [Report.AIApp]) -> Content {
        let apps = ai.enumerated().map { index, g in
            AIApp(
                id: index, name: g.app ?? "",
                // <small>${g.mem ? fmtBytes(g.mem) + ' GPU memory' : ''}</small>
                memory: DashJS.number(g.mem).map { Format.fmtBytes($0) + " GPU memory" } ?? "",
                models: g.models.enumerated().map { index, m in
                    // ${esc(m.name)}${m.kind ? ` <small>${esc(m.kind)}</small>` : ''}</span><span>${m.size ? fmtBytes(m.size) : '–'}</span>
                    AIModel(id: index, name: m.name ?? "", kind: DashJS.text(m.kind), size: DashJS.number(m.size).map { Format.fmtBytes($0) } ?? Format.dash)
                },
                placeholder: g.models.isEmpty ? modelNameUnavailableText : nil
            )
        }
        return .models(apps: apps, emptyText: apps.isEmpty ? noModelsText : nil)
    }
}

import Foundation
import Testing
@testable import DMCore

/// presentation/dashboard/cards.json: every device of the corpus as the real dashboard's
/// updateCard and detailHtml rendered it, online and offline, in °C and °F.
@Suite struct DeviceCardFixtureTests {
    struct Cards: Decodable {
        struct Meta: Decodable {
            let now: Double
            /// CIRC × ARC of the gauge: the dash length of a full arc.
            let gaugeArcLength: Double
        }

        struct Case: Decodable {
            let label: String
            let device: Device
        }

        struct Run: Decodable {
            let unit: String
            let latestVersions: [String: String]
        }

        struct Outcome: Decodable {
            let card: Card
            let details: [Section]
        }

        struct Card: Decodable {
            let id: String
            let offline: Bool
            let name: String
            let hostname: String
            let subtitle: String
            let gauges: [Gauge]
            let stats: [Stat]
        }

        struct Gauge: Decodable {
            let label: String
            let color: String
            let valueText: String
            let dash: Double
            let caption: Caption
        }

        struct Caption: Decodable {
            let type: String
            let title: String?
            let color: String?
            let text: String
            let small: String?
        }

        struct Stat: Decodable, Equatable {
            let key: String
            let value: String
            let barWidth: String?
            let barColor: String?
        }

        struct Section: Decodable {
            struct App: Decodable, Equatable {
                struct Model: Decodable, Equatable {
                    let name: String
                    let kind: String?
                    let size: String
                }

                let name: String
                let memory: String
                let models: [Model]
                let placeholder: String?
            }

            /// A row is `[label, value]`, or `{name, parent, value}` for a temperature sensor.
            struct Row: Decodable, Equatable {
                let label: String
                let detail: String
                let value: String

                private enum Keys: String, CodingKey {
                    case name, parent, value
                }

                init(label: String, detail: String, value: String) {
                    self.label = label
                    self.detail = detail
                    self.value = value
                }

                init(from decoder: Decoder) throws {
                    if var items = try? decoder.unkeyedContainer() {
                        label = try items.decode(String.self)
                        value = try items.decode(String.self)
                        detail = ""
                    } else {
                        let object = try decoder.container(keyedBy: Keys.self)
                        label = try object.decode(String.self, forKey: .name)
                        detail = try object.decode(String.self, forKey: .parent)
                        value = try object.decode(String.self, forKey: .value)
                    }
                }
            }

            let type: String
            let title: String?
            let text: String?
            let bold: String?
            let rows: [Row]?
            let apps: [App]?
            let empty: String?
            let drives: [Stat]?
        }

        let meta: Meta
        let cases: [Case]
        let runs: [Run]
        let runC: [Outcome?]
        let runF: [Outcome?]
    }

    let fixture: Cards

    init() throws {
        fixture = try DashFixture.decode(Cards.self, "dashboard/cards.json")
    }

    /// Every recorded (device, unit) pair with what the dashboard showed.
    private func rows() -> [(label: String, device: Device, run: Cards.Run, outcome: Cards.Outcome)] {
        var rows = [(label: String, device: Device, run: Cards.Run, outcome: Cards.Outcome)]()
        for (run, outcomes) in zip(fixture.runs, [fixture.runC, fixture.runF]) {
            for (entry, outcome) in zip(fixture.cases, outcomes) {
                if let outcome { rows.append(("\(entry.label) [\(run.unit)]", entry.device, run, outcome)) }
            }
        }
        return rows
    }

    private func bar(_ stat: DeviceStat) -> String? {
        stat.percent.map { JS.toFixed($0, 1) + "%" }
    }

    /// The width the dashboard wrote, as the bar it draws: clipped at full, and full when the
    /// width is not a number (an invalid CSS width leaves the fill at its natural, full width).
    private func bar(_ width: String?) -> String? {
        guard let width else { return nil }
        let number = Double(width.dropLast()) ?? .nan
        return JS.toFixed(number.isFinite ? min(100, max(0, number)) : 100, 1) + "%"
    }

    private func same(_ stat: DeviceStat, _ expected: Cards.Stat) -> Bool {
        stat.key == expected.key && stat.value == expected.value && bar(stat) == bar(expected.barWidth)
            && (expected.barColor == nil || DashFixture.tint(expected.barColor ?? "") == stat.tint)
    }

    @Test func theCorpusIsTheOneTheSuiteExpects() {
        #expect(fixture.cases.count > 120)
        #expect(fixture.runs.map(\.unit) == ["C", "F"])
        #expect(fixture.runC.count == fixture.cases.count && fixture.runF.count == fixture.cases.count)
        #expect(fixture.runC.allSatisfy { $0 != nil })
        #expect(fixture.runF.compactMap { $0 }.count > 60)
        #expect(Set(fixture.cases.map(\.device.id)).count == fixture.cases.count)
        #expect(fixture.cases.contains { !$0.device.online } && fixture.cases.contains { $0.device.latest == nil })
    }

    @Test func titleAndStatusLine() {
        let rows = rows()
        var failures = [String]()
        for row in rows {
            let model = DeviceCardModel(device: row.device, unit: DashFixture.unit(row.run.unit), latestVersions: row.run.latestVersions, now: fixture.meta.now)
            let card = row.outcome.card
            if model.id != card.id { failures.append("\(row.label): id \(model.id), dashboard \(card.id)") }
            if model.name != card.name { failures.append("\(row.label): name \"\(model.name)\", dashboard \"\(card.name)\"") }
            if model.hostname != card.hostname { failures.append("\(row.label): hostname \"\(model.hostname)\", dashboard \"\(card.hostname)\"") }
            if model.subtitle != card.subtitle { failures.append("\(row.label): subtitle \"\(model.subtitle)\", dashboard \"\(card.subtitle)\"") }
            if model.isOnline == card.offline { failures.append("\(row.label): online \(model.isOnline), dashboard offline \(card.offline)") }
        }
        DashFixture.report(failures, of: rows.count)
    }

    @Test func gauges() {
        let rows = rows()
        var failures = [String]()
        for row in rows {
            let model = DeviceCardModel(device: row.device, unit: DashFixture.unit(row.run.unit), latestVersions: row.run.latestVersions, now: fixture.meta.now)
            guard row.outcome.card.gauges.count == 3 else {
                failures.append("\(row.label): the dashboard drew \(row.outcome.card.gauges.count) gauges")
                continue
            }
            for (gauge, expected) in zip(model.gauges, row.outcome.card.gauges) {
                let name = "\(row.label), \(expected.label)"
                if gauge.label != expected.label || DashFixture.tint(expected.color) != gauge.tint {
                    failures.append("\(name): is \(gauge.label) in \(gauge.tint)")
                }
                if gauge.valueText != expected.valueText { failures.append("\(name): reads \(gauge.valueText), dashboard \(expected.valueText)") }
                if (gauge.value == nil) != (expected.valueText == Format.dash) { failures.append("\(name): value \(String(describing: gauge.value)) for \(expected.valueText)") }
                // svg.querySelector('.fill').setAttribute('stroke-dasharray', `${Math.max(0.01, len * v / 100)} ${CIRC}`);
                let dash = max(0.01, fixture.meta.gaugeArcLength * gauge.fraction)
                if abs(dash - expected.dash) > 1e-9 { failures.append("\(name): arc \(dash), dashboard \(expected.dash)") }
                if let problem = compare(gauge.caption, expected.caption) { failures.append("\(name): \(problem)") }
            }
        }
        DashFixture.report(failures, of: rows.count)
    }

    private func compare(_ caption: DeviceGaugeCaption, _ expected: Cards.Caption) -> String? {
        switch (expected.type, caption) {
        case ("pill", .temperature(let pill)):
            let color = ["Normal": "var(--good)", "Warm": "var(--warning)", "Hot": "var(--critical)"][pill.status.label]
            if pill.text != expected.text || caption.text != expected.text { return "pill reads \(pill.text), dashboard \(expected.text)" }
            if pill.statusText != expected.small { return "pill adds \(pill.statusText ?? "nothing"), dashboard \(expected.small ?? "nothing")" }
            if pill.tooltip != expected.title { return "pill tooltip \(pill.tooltip), dashboard \(expected.title ?? "none")" }
            if color != expected.color { return "pill is \(pill.status), dashboard dot \(expected.color ?? "none")" }
            if (pill.note == "ACPI sensor") != (expected.title?.hasSuffix(" \u{B7} ACPI sensor") ?? false) || (pill.note != nil && pill.note != "ACPI sensor") {
                return "pill note \(pill.note ?? "none") for \(expected.title ?? "none")"
            }
            return caption.isHint ? "a pill is not a hint" : nil
        case ("hint", .noSensor), ("hint", .noGPU), ("hint", .offline):
            return caption.text == expected.text && caption.isHint ? nil : "hint says \(caption.text), dashboard \(expected.text)"
        case ("text", .text(let text)):
            return text == expected.text && caption.text == expected.text && !caption.isHint ? nil : "text says \(text), dashboard \(expected.text)"
        default:
            return "caption \(caption), dashboard \(expected.type) \"\(expected.text)\""
        }
    }

    @Test func statsGrid() {
        let rows = rows()
        var failures = [String]()
        for row in rows {
            let model = DeviceCardModel(device: row.device, unit: DashFixture.unit(row.run.unit), latestVersions: row.run.latestVersions, now: fixture.meta.now)
            let expected = row.outcome.card.stats
            if model.stats.count != expected.count || !zip(model.stats, expected).allSatisfy({ same($0, $1) }) {
                failures.append("\(row.label):\n   app       \(model.stats.map { "\($0.key)=\($0.value) [\(bar($0) ?? "-") \($0.tint)]" })\n   dashboard \(expected.map { "\($0.key)=\($0.value) [\($0.barWidth ?? "-") \($0.barColor ?? "")]" })")
            }
            if Set(model.stats.map(\.id)).count != model.stats.count { failures.append("\(row.label): stat ids repeat") }
            // A bar is drawn for VRAM and the drive only, the first in the GPU colour.
            for stat in model.stats where (stat.percent != nil) != (stat.id == "vram" || stat.id == "disk") { failures.append("\(row.label): \(stat.id) bar \(String(describing: stat.percent))") }
            for stat in model.stats { if let p = stat.percent, !(0...100).contains(p) { failures.append("\(row.label): \(stat.id) bar \(p) is off the scale") } }
        }
        DashFixture.report(failures, of: rows.count)
    }

    @Test func details() {
        let rows = rows()
        var failures = [String]()
        for row in rows {
            let model = DeviceDetailsModel(device: row.device, unit: DashFixture.unit(row.run.unit))
            let expected = row.outcome.details
            guard model.sections.count == expected.count else {
                failures.append("\(row.label): sections \(model.sections.map { "\($0.kind)" }), dashboard \(expected.map { $0.title ?? $0.type })")
                continue
            }
            if Set(model.sections.map(\.id)).count != model.sections.count { failures.append("\(row.label): section ids repeat") }
            for (section, wanted) in zip(model.sections, expected) {
                if let problem = compare(section, wanted) { failures.append("\(row.label), \(wanted.title ?? wanted.type): \(problem)") }
            }
        }
        DashFixture.report(failures, of: rows.count)
    }

    private func compare(_ section: DeviceDetailsModel.Section, _ expected: Cards.Section) -> String? {
        if expected.type != "hint", section.title != expected.title { return "title \(section.title ?? "none")" }
        switch (expected.type, section.kind, section.content) {
        case ("models", .loadedModels, .models(let apps, let emptyText)):
            let mine = apps.map { app in
                Cards.Section.App(
                    name: app.name, memory: app.memory,
                    models: app.models.map { Cards.Section.App.Model(name: $0.name, kind: $0.kind, size: $0.size) }, placeholder: app.placeholder
                )
            }
            if mine != expected.apps { return "apps \(mine), dashboard \(expected.apps ?? [])" }
            return emptyText == expected.empty ? nil : "empty text \(emptyText ?? "none"), dashboard \(expected.empty ?? "none")"
        case ("gpu", .gpu, .rows(let rows)), ("temps", .temperatureSensors, .rows(let rows)), ("fans", .fans, .rows(let rows)):
            let mine = rows.map { Cards.Section.Row(label: $0.label, detail: $0.detail ?? "", value: $0.value) }
            if Set(rows.map(\.id)).count != rows.count { return "row ids repeat" }
            return mine == expected.rows ? nil : "rows \(mine.map { "\($0.label)(\($0.detail))=\($0.value)" }), dashboard \((expected.rows ?? []).map { "\($0.label)(\($0.detail))=\($0.value)" })"
        case ("drives", .drives, .drives(let drives)):
            let wanted = expected.drives ?? []
            if Set(drives.map(\.id)).count != drives.count { return "drive ids repeat" }
            return drives.count == wanted.count && zip(drives, wanted).allSatisfy { same($0, $1) } && drives.allSatisfy { $0.tint == .secondary && $0.percent != nil }
                ? nil : "drives \(drives.map { "\($0.key)=\($0.value) [\(bar($0) ?? "-")]" }), dashboard \(wanted.map { "\($0.key)=\($0.value) [\($0.barWidth ?? "-")]" })"
        case ("hint", .sensorHint, .hint(let text, let emphasis)), ("hint", .noData, .hint(let text, let emphasis)):
            if text != expected.text || emphasis != expected.bold { return "hint \"\(text)\" (\(emphasis ?? "no emphasis")), dashboard \"\(expected.text ?? "")\"" }
            return (section.kind == .noData) == (text == DeviceDetailsModel.noDataText) && section.title == nil ? nil : "hint of the wrong kind"
        default:
            return "is \(section.kind), dashboard \(expected.type)"
        }
    }

    @Test func gpuHeadingsCountFromZeroOnlyWhenThereAreSeveral() throws {
        for row in rows() {
            let kinds = DeviceDetailsModel(device: row.device, unit: .celsius).sections.map(\.kind)
            let gpus = row.device.latest?.gpus.count ?? 0
            #expect(kinds.filter { if case .gpu = $0 { true } else { false } } == (0..<gpus).map { DeviceDetailsModel.Kind.gpu($0) })
        }
    }

    @Test func anOfflineCardKeepsOnlyWhatTheHardwareIs() throws {
        let devices = try ModelFixture.decode([Device].self, "devices.json")
        var workstation = try ModelFixture.device(ModelFixture.workstation, in: devices)
        let online = DeviceReading(device: workstation)
        #expect(!online.isOffline && online.report == workstation.latest)

        workstation.online = false
        let reading = DeviceReading(device: workstation)
        let latest = try #require(workstation.latest), zeroed = reading.report
        #expect(reading.isOffline)
        #expect(zeroed == DeviceReading.zeroed(latest))
        #expect(zeroed.uptime == nil && zeroed.temps.isEmpty && zeroed.fans.isEmpty && zeroed.ai == nil)
        #expect(zeroed.cpu.usage == 0 && zeroed.cpu.temp == nil && zeroed.cpu.clockMHz == nil && zeroed.cpu.name == latest.cpu.name)
        #expect(zeroed.memory.used == 0 && zeroed.memory.total == latest.memory.total)
        #expect(zeroed.gpus.map(\.name) == latest.gpus.map(\.name) && zeroed.gpus.map(\.memTotal) == latest.gpus.map(\.memTotal))
        #expect(zeroed.gpus.allSatisfy { $0.usage == 0 && $0.temp == nil && $0.memUsed == 0 && $0.clockMHz == nil && $0.fan == nil })
        #expect(zeroed.gpus.first?.power == 0 && zeroed.gpus.first?.powerLimit == latest.gpus.first?.powerLimit)
        #expect(zeroed.net == Report.Net(rx: 0, tx: 0) && zeroed.diskIO == Report.DiskIO(read: 0, write: 0))
        #expect(zeroed.disks == latest.disks && zeroed.platform == latest.platform && zeroed.appVersion == latest.appVersion)

        // A card that has no power reading does not gain one, and one without network stays without.
        var bare = Report()
        bare.gpus = [Report.GPU(name: "Card")]
        let zeroedBare = DeviceReading.zeroed(bare)
        #expect(zeroedBare.gpus.first?.power == nil && zeroedBare.net == nil && zeroedBare.diskIO == nil)
        #expect(DeviceReading(report: nil, isOnline: false).report.cpu.usage == 0)
        #expect(DeviceReading(report: nil, isOnline: true).report == Report())
    }

    @Test func versionLabelsFollowWhatTheHubPublished() {
        func device(_ platform: String?, _ version: String?) -> Device {
            Device(id: "d", platform: platform, latest: Report(appVersion: version))
        }
        let published = ["windows": "1.2.33", "mac": "1.2.31"]
        #expect(DeviceVersion.platformKey("windows") == "windows" && DeviceVersion.platformKey("macos") == "mac")
        #expect(DeviceVersion.platformKey("linux") == nil && DeviceVersion.platformKey("mac") == nil && DeviceVersion.platformKey(nil) == nil)
        #expect(DeviceVersion.label(for: device("windows", "1.2.32"), latestVersions: published) == "v1.2.32 \u{2192} 1.2.33")
        #expect(DeviceVersion.label(for: device("windows", "1.2.33"), latestVersions: published) == "v1.2.33")
        #expect(DeviceVersion.label(for: device("macos", "1.2.30"), latestVersions: published) == "v1.2.30 \u{2192} 1.2.31")
        #expect(DeviceVersion.label(for: device("linux", "1.2.30"), latestVersions: published) == "v1.2.30")
        #expect(DeviceVersion.label(for: device("windows", "1.2.32"), latestVersions: [:]) == "v1.2.32")
        #expect(DeviceVersion.label(for: device("windows", "1.2.32"), latestVersions: ["windows": ""]) == "v1.2.32")
        #expect(DeviceVersion.label(for: device("windows", nil), latestVersions: published) == nil)
        #expect(DeviceVersion.label(for: Device(id: "d", platform: "windows"), latestVersions: published) == nil)
    }
}

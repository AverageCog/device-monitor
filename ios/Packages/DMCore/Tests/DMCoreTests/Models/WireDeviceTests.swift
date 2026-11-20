import Foundation
import Testing
@testable import DMCore

/// Devices, reports and history as a real hub sends them.
@Suite struct WireDeviceTests {
    let devices: [Device]

    init() throws {
        devices = try ModelFixture.decode([Device].self, "devices.json")
    }

    private func device(_ id: String) throws -> Device {
        try ModelFixture.device(id, in: devices)
    }

    @Test func listsEveryDeviceWithItsRegistryEntry() throws {
        #expect(devices.map(\.id) == [ModelFixture.workstation, ModelFixture.dgx, ModelFixture.macbook, ModelFixture.nas, ModelFixture.lab, ModelFixture.htpc])
        #expect(devices.map(\.order) == [1, 0, 2, 4, 3, 5])
        #expect(devices.map(\.online) == [true, true, true, true, true, false])
        #expect(devices.map(\.platform) == ["windows", "linux", "macos", "linux", "windows", "linux"])
        #expect(devices.map(\.displayName) == ["DESKTOP-7QK2M1P", "dgx-station", "Sams-MacBook-Pro", "nas", "Lab PC", "htpc"])
        for d in devices {
            #expect(d.firstSeen != nil && d.lastSeen != nil)
            #expect(d.lastSeenDate == Date(timeIntervalSince1970: (d.lastSeen ?? 0) / 1000))
            // Samples are in time order and end with the report that set lastSeen.
            #expect(d.history.map(\.t) == d.history.map(\.t).sorted())
            #expect(d.history.last?.t == d.lastSeen)
            #expect(d.latest?.receivedAt == d.lastSeen)
            #expect(d.latest?.id == d.id)
        }
    }

    @Test func windowsDesktopWithOneGPUAndSensors() throws {
        let d = try device(ModelFixture.workstation)
        #expect(d.os == "Windows 11 Pro 24H2")
        #expect(d.hw == Device.Hardware(formFactor: "desktop", threads: 32))
        // The hub lower-cases addresses, turns dashes into colons and drops the all-zero one.
        #expect(d.macs == ["a4:bb:6d:12:9f:0e", "a4:bb:6d:12:9f:0f"])
        #expect(!d.renamed)
        #expect(d.history.count == 21)

        let report = try #require(d.latest)
        #expect(report.appVersion == "1.2.32")
        #expect(report.formFactor == "desktop")
        #expect(report.uptime == 266_440)
        #expect(report.features == ["procs", "actions"])
        #expect(report.actions == ["sleep", "restart", "shutdown"])
        #expect(report.actionResult == nil)
        #expect(report.cpu.name == "AMD Ryzen 9 7950X 16-Core Processor")
        #expect(report.cpu.threads == 32)
        #expect(report.cpu.clockMHz == 4491.7)
        #expect(report.cpu.cores.count == 8)
        #expect(report.cpu.cores.allSatisfy { $0 != nil })
        #expect(report.cpu.tempSource == nil)
        #expect(report.memory.total == 68_631_805_952)
        #expect((report.memory.used ?? 0) > 28_000_000_000)

        #expect(report.gpus.count == 1)
        let gpu = try #require(report.gpus.first)
        #expect(gpu.name == "NVIDIA GeForce RTX 4090")
        #expect(gpu.vendor == "NVIDIA")
        #expect(gpu.memTotal == 25_757_220_864)
        #expect(gpu.powerLimit == 450)
        #expect(gpu.fan == 41)
        #expect(gpu.clockMHz == 2520)
        #expect(gpu.power != nil && gpu.temp != nil && gpu.usage != nil)

        #expect(report.disks == [
            Report.Disk(name: "C:", label: "Windows", total: 999_650_168_832, used: 612_345_678_848),
            Report.Disk(name: "D:", label: "Games", total: 2_000_381_014_016, used: 1_234_567_890_123),
        ])
        #expect(report.temps.count == 4)
        #expect(report.temps.last == Report.Temp(name: "System", parent: "ASUS ROG STRIX X670E-E", value: -2.5))
        #expect(report.fans == [Report.Fan(name: "CPU Fan", rpm: 912), Report.Fan(name: "Chassis Fan #1", rpm: 0), Report.Fan(name: "Pump", rpm: nil)])
        #expect(report.net?.rx != nil && report.diskIO?.write != nil)
        // An empty list means the agent looked and found nothing loaded; nil means it never looks.
        #expect(report.ai == [])

        // Measured CPU and GPU power: nothing in the estimate is a guess.
        #expect(report.power?.cpu != nil)
        let estimate = try #require(report.powerEst)
        #expect(estimate.cpuMeasured && estimate.gpuMeasured && !estimate.gpuEstimated)
        #expect(estimate.cpu == report.power?.cpu)
        #expect(estimate.gpu == gpu.power)
        #expect(estimate.rest == 25)
        #expect(estimate.watts > estimate.cpu + estimate.gpu + estimate.rest)
    }

    @Test func linuxWorkstationWithSeveralGPUsAndLoadedModels() throws {
        let report = try #require(try device(ModelFixture.dgx).latest)
        #expect(report.appVersion == nil)
        #expect(report.cpu.name == "Intel(R) Xeon(R) W9-3495X CPU @ 1.90GHz")
        #expect(report.cpu.threads == 112)
        // A core the agent could not read stays in place as nil.
        #expect(report.cpu.cores == [12.5, 99.9, 0, nil, 41])

        // Biggest card first, whatever order the agent listed them in.
        #expect(report.gpus.map(\.name) == Array(repeating: "NVIDIA RTX 6000 Ada Generation", count: 4) + ["ASPEED Graphics Family"])
        #expect(report.gpus.prefix(4).allSatisfy { $0.memTotal == 51_527_024_640 && $0.powerLimit == 300 && $0.clockMHz == nil })
        #expect(report.gpus[3].usage == 0)
        #expect(report.gpus[3].power == 21.4)
        #expect(report.gpus[4] == Report.GPU(name: "ASPEED Graphics Family", vendor: "ASPEED"))

        let ai = try #require(report.ai)
        #expect(ai.map(\.app) == ["ComfyUI", "Ollama", "vLLM"])
        #expect(ai[0].mem == 110_255_669_248)
        #expect(ai[0].models == [
            Report.AIModel(name: "flux1-dev-fp8.safetensors", size: 17_246_524_772, kind: "unet"),
            Report.AIModel(name: "t5xxl_fp16.safetensors", size: 9_787_841_024, kind: "clip"),
            Report.AIModel(name: "ae.safetensors", size: 335_304_388, kind: "vae"),
        ])
        #expect(ai[1].models == [Report.AIModel(name: "qwen3:8b", size: 6_100_000_000, kind: nil)])
        #expect(ai[2] == Report.AIApp(app: "vLLM", mem: nil, models: []))

        #expect(report.disks.last == Report.Disk(name: "/raid", label: "md0", total: 30_000_000_000_000, used: 21_450_000_000_000))
        #expect(report.disks.first?.label == nil)
        #expect(report.temps.map(\.parent) == ["coretemp", "nvme"])
        #expect(report.fans.map(\.rpm) == [2310, 2295])
    }

    @Test func macLaptopWithoutGPUMemoryOrAIScan() throws {
        let d = try device(ModelFixture.macbook)
        #expect(d.hw == Device.Hardware(formFactor: "laptop", threads: 12))
        let report = try #require(d.latest)
        #expect(report.platform == "macos")
        #expect(report.os == "macOS 15.5")
        #expect(report.appVersion == "1.2.30")
        #expect(report.formFactor == "laptop")
        #expect(report.actions == ["sleep"])
        #expect(report.cpu.clockMHz == nil)
        #expect(report.gpus.count == 1)
        #expect(report.gpus[0].name == "Apple M3 Pro")
        #expect(report.gpus[0].memTotal == nil && report.gpus[0].temp == nil && report.gpus[0].power == nil)
        #expect(report.power == nil)
        #expect(report.ai == nil)
        #expect(report.temps.isEmpty && report.fans.isEmpty)
        let estimate = try #require(report.powerEst)
        #expect(!estimate.cpuMeasured && !estimate.gpuMeasured && !estimate.gpuEstimated)
        #expect(estimate.rest == 6)
    }

    @Test func deviceThatReportsAlmostNothing() throws {
        let d = try device(ModelFixture.nas)
        #expect(d.os == nil)
        #expect(d.hw == Device.Hardware(formFactor: nil, threads: nil))
        #expect(d.macs.isEmpty)   // the registry entry has no `macs` key at all
        #expect(d.history.count == 11)
        let report = try #require(d.latest)
        #expect(report.uptime == nil && report.formFactor == nil && report.appVersion == nil)
        #expect(report.cpu == Report.CPU(usage: report.cpu.usage))
        #expect(report.cpu.usage != nil)
        #expect(report.memory == Report.Memory(total: 8_233_517_056, used: 1_811_939_328))
        #expect(report.gpus.isEmpty && report.features.isEmpty && report.actions.isEmpty && report.macs.isEmpty)
        #expect(report.net == nil && report.diskIO == nil && report.ai == nil && report.power == nil)
        #expect(report.disks == [Report.Disk(name: "/volume1", total: 15_989_000_000_000, used: 9_113_730_000_000)])
        // Its samples have no GPU, temperature or throughput readings.
        let sample = try #require(d.history.last)
        #expect(sample.cpu != nil && sample.mem != nil && sample.power != nil)
        #expect(sample.gpu == nil && sample.cpuTemp == nil && sample.gpuTemp == nil && sample.gpuPower == nil)
        #expect(sample.rx == nil && sample.tx == nil && sample.dr == nil && sample.dw == nil)
    }

    @Test func renamedDeviceWithEstimatedGPUPower() throws {
        let d = try device(ModelFixture.lab)
        #expect(d.name == "Lab PC")
        #expect(d.hostname == "LAB-PC-03")
        #expect(d.renamed)
        let report = try #require(d.latest)
        #expect(report.hostname == "LAB-PC-03")
        #expect(report.cpu.tempSource == "acpi")
        #expect(report.cpu.temp == 61)
        #expect(report.gpus[0].memUsed == 3_435_973_836.8)   // bytes are not always whole
        #expect(report.gpus[0].power == nil)
        #expect(report.ai == nil)
        let estimate = try #require(report.powerEst)
        #expect(!estimate.cpuMeasured && !estimate.gpuMeasured && estimate.gpuEstimated)
        #expect(estimate.gpu > 0)
    }

    @Test func offlineDeviceKeepsItsLastReport() throws {
        let d = try device(ModelFixture.htpc)
        #expect(!d.online)
        #expect(d.macs == ["b8:27:eb:11:22:33"])
        #expect(d.history.count == 1)
        let report = try #require(d.latest)
        #expect(report.cpu.usage == 12.3)
        #expect(report.gpus == [Report.GPU(name: "Intel UHD Graphics 600", vendor: "Intel", usage: 4, memTotal: 0)])
        #expect(report.ai == [])
        #expect(report.net == Report.Net(rx: 512, tx: 256))
        #expect(report.diskIO == nil)
        #expect((d.lastSeen ?? 0) < (try device(ModelFixture.nas).lastSeen ?? 0))
    }

    @Test func afterAHubRestartDevicesHaveNoLiveData() throws {
        let restarted = try ModelFixture.decode([Device].self, "devices-after-restart.json")
        #expect(restarted.map(\.id) == devices.map(\.id))
        #expect(restarted.map(\.displayName) == devices.map(\.displayName))
        #expect(restarted.map(\.order) == devices.map(\.order))
        #expect(restarted.allSatisfy { $0.latest == nil && $0.history.isEmpty })
        #expect(try ModelFixture.device(ModelFixture.lab, in: restarted).renamed)
        #expect(try ModelFixture.device(ModelFixture.htpc, in: restarted).online == false)
        #expect(try ModelFixture.device(ModelFixture.workstation, in: restarted).hw?.threads == 32)
    }

    @Test func renameAnswersWithTheDevice() throws {
        let d = try ModelFixture.decode(Device.self, "device-patch.json")
        #expect(d.id == ModelFixture.lab)
        #expect(d.name == "Lab PC")
        #expect(d.renamed)
        #expect(d.online)
        #expect(d.history.count == 10)
        #expect(d.latest?.hostname == "LAB-PC-03")
    }

    @Test func displayNameFallsBackLikeTheDashboard() {
        #expect(Device(id: "abc", name: "Den PC", hostname: "DESKTOP-1").displayName == "Den PC")
        #expect(Device(id: "abc", name: "", hostname: "DESKTOP-1").displayName == "DESKTOP-1")
        #expect(Device(id: "abc", name: nil, hostname: "").displayName == "abc")
        #expect(Device(id: "abc").displayName == "abc")
    }

    @Test func devicesSurviveARoundTrip() throws {
        let again = try HubJSON.decode([Device].self, from: try HubJSON.encode(devices))
        #expect(again == devices)
    }

    // MARK: History

    @Test func rawHistoryIsTwoSecondSamplesWithoutPeaks() throws {
        let h = try ModelFixture.decode(HistoryResponse.self, "history-raw.json")
        #expect(h.resolution == 2000)
        #expect(h.points.count == 21)
        #expect(h.to - h.from == 86_001)
        #expect(h.fromDate < h.toDate)
        #expect(h.points.allSatisfy { $0.t > h.from && $0.t <= h.to })
        for p in h.points {
            #expect(p.n == nil)
            #expect(HistoryPoint.Metric.allCases.allSatisfy { p.peak($0) == nil })
            #expect(HistoryPoint.Metric.allCases.allSatisfy { p.value($0) != nil })
            #expect(p.date == Date(timeIntervalSince1970: p.t / 1000))
        }
        // The same samples the device list carried.
        #expect(h.points == (try device(ModelFixture.workstation)).history)
    }

    @Test func tenMinuteHistoryMixesStoredMinutesAndRawSamples() throws {
        let h = try ModelFixture.decode(HistoryResponse.self, "history-10m.json")
        #expect(h.resolution == 60_000)
        #expect(h.to - h.from == 600_000)
        #expect(h.points.count == 28)
        let minutes = h.points.filter { $0.n != nil }
        #expect(minutes.count == 7)
        #expect(minutes.allSatisfy { $0.n == 30 && $0.cpuMax != nil && $0.gpuMax != nil && $0.cpuTempMax != nil && $0.gpuTempMax != nil && $0.powerMax != nil })
        #expect(minutes.allSatisfy { ($0.cpuMax ?? 0) >= ($0.cpu ?? 0) })
        // Minute points come first, then the raw samples.
        #expect(h.points.prefix(7).allSatisfy { $0.n != nil })
        #expect(h.points.dropFirst(7).allSatisfy { $0.n == nil && $0.cpuMax == nil })
    }

    @Test func aggregatedHistoryHasPeaksAndLeavesGapsOut() throws {
        let h = try ModelFixture.decode(HistoryResponse.self, "history-24h.json")
        #expect(h.resolution == 3_600_000)
        #expect(h.to - h.from == 86_400_000)
        // Three of the 24 hours are missing: the device was off, and an empty bucket is not sent.
        #expect(h.points.count == 22)
        #expect(zip(h.points, h.points.dropFirst()).filter { $1.t - $0.t > h.resolution }.count == 1)
        #expect(h.points.first?.t == h.from)
        for p in h.points {
            #expect(p.n == nil)
            #expect(p.peak(.cpu) == p.cpuMax && p.peak(.gpu) == p.gpuMax && p.peak(.power) == p.powerMax)
            #expect(p.peak(.cpuTemp) == p.cpuTempMax && p.peak(.gpuTemp) == p.gpuTempMax)
            #expect(p.cpuMax != nil && p.gpuMax == 100 && p.powerMax != nil)
            #expect((p.powerMax ?? 0) > (p.power ?? .infinity))
            #expect(p.value(.rx) == p.rx && p.value(.dw) == p.dw && p.value(.gpuPower) == p.gpuPower && p.value(.mem) == p.mem)
            #expect(p.peak(.mem) == nil && p.peak(.rx) == nil)
        }
    }

    @Test func aggregatedHistoryCarriesNullsForWhatWasNeverMeasured() throws {
        let h = try ModelFixture.decode(HistoryResponse.self, "history-6h-no-gpu.json")
        #expect(h.resolution == 1_800_000)
        #expect(h.points.count == 12)
        #expect(h.points.allSatisfy { $0.gpu == nil && $0.gpuMax == nil && $0.cpuTemp == nil && $0.cpuTempMax == nil && $0.gpuTemp == nil && $0.gpuPower == nil })
        #expect(h.points.allSatisfy { $0.cpu != nil && $0.cpuMax != nil && $0.mem != nil && $0.rx != nil })
        // Old rows have no power; only the newest bucket, fed by live reports, does.
        #expect(h.points.filter { $0.power == nil }.count == 11)
        #expect(h.points.last?.power != nil && h.points.last?.powerMax != nil)
    }

    @Test func historySurvivesARoundTrip() throws {
        for name in ["history-raw.json", "history-10m.json", "history-24h.json", "history-6h-no-gpu.json"] {
            let h = try ModelFixture.decode(HistoryResponse.self, name)
            #expect(try HubJSON.decode(HistoryResponse.self, from: try HubJSON.encode(h)) == h)
        }
    }
}

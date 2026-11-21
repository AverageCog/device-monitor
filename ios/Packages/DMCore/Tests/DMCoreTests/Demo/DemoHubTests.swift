import Foundation
import os
import Testing
@testable import DMCore

/// Reads a hub's stream into a list the test can look at.
final class StreamListener: Sendable {
    private struct State: Sendable {
        var events: [HubEvent] = []
        var failure: HubError?
        var ended = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let task: Task<Void, Never>

    init(_ api: any HubAPI) {
        let stream = api.events(), state = state
        task = Task {
            do {
                for try await event in stream { state.withLock { $0.events.append(event) } }
            } catch {
                state.withLock { $0.failure = HubError(error) }
            }
            state.withLock { $0.ended = true }
        }
    }

    deinit {
        task.cancel()
    }

    var events: [HubEvent] { state.withLock { $0.events } }
    var failure: HubError? { state.withLock { $0.failure } }
    var hasEnded: Bool { state.withLock { $0.ended } }
    func events(_ type: String) -> [HubEvent] { events.filter { $0.type == type } }
    func stop() { task.cancel() }

    /// Waits until `count` events of `type` have arrived.
    func wait(for count: Int, _ type: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        let arrived = await EventStreamTests.eventually { self.events(type).count >= count }
        #expect(arrived, "expected \(count) \(type) events, have \(events(type).count)", sourceLocation: sourceLocation)
    }

    var alerts: [(event: AlertEvent, notify: Bool, active: [ActiveAlert])] {
        events.compactMap { if case .alert(let event, let notify, let active) = $0 { (event, notify, active) } else { nil } }
    }
}

@Suite(.timeLimit(.minutes(2))) struct DemoHubTests {
    typealias ID = DemoHubAPI.DeviceID

    static let gmt = TimeZone(identifier: "GMT")!
    /// Noon GMT, on the two-second grid.
    static let noon: Double = 1_795_262_400_000
    static let hour: Double = 3600e3, day: Double = 86400e3

    static func make(seed: UInt64 = 7, at now: Double = noon, latency: Double = 0) -> (hub: DemoHubAPI, clock: ManualHubClock) {
        let clock = ManualHubClock(now: now)
        return (DemoHubAPI(configuration: .init(seed: seed, timeZone: gmt, latency: latency), clock: clock), clock)
    }

    /// Moves the demo forward a second at a time, letting its timer run between steps.
    static func run(_ clock: ManualHubClock, for milliseconds: Double, step: Double = 1000, sleepers: Int = 1) async {
        var left = milliseconds
        while left > 0 {
            await clock.waitForSleepers(sleepers)
            clock.advance(by: min(step, left))
            left -= step
        }
        await clock.waitForSleepers(sleepers)
    }

    // MARK: The fleet

    @Test func theSnapshotDescribesTheFleet() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        guard case .snapshot(let devices) = try #require(listener.events.first) else { return }

        #expect(devices.map(\.id) == [ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.homeServer, ID.studioPC, ID.livingRoomPC])
        #expect(devices.map(\.name) == ["Gaming PC", "DGX Spark", "MacBook Pro", "Home Server", "Studio PC", "Living Room PC"])
        #expect(devices.map(\.order) == [0, 1, 2, 3, 4, 5])
        #expect(devices.map(\.platform) == ["windows", "linux", "macos", "linux", "windows", "windows"])
        #expect(devices.map(\.online) == [true, true, true, true, true, false])
        // Ten minutes of two-second samples for everything that is on.
        #expect(devices.map(\.history.count) == [301, 301, 301, 301, 301, 0])
        #expect(devices[0].history.first?.t == Self.noon - 600_000 && devices[0].history.last?.t == Self.noon)

        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        // Two GPUs, the bigger one first; no GPU at all on the server.
        #expect(byID[ID.studioPC]?.latest?.gpus.map(\.name) == ["NVIDIA GeForce RTX 4090", "NVIDIA GeForce RTX 4070 Ti SUPER"])
        #expect(byID[ID.homeServer]?.latest?.gpus.isEmpty == true)
        #expect(byID[ID.homeServer]?.history.allSatisfy { $0.gpu == nil && $0.gpuTemp == nil && $0.cpu != nil && $0.power != nil } == true)
        #expect(byID[ID.gamingPC]?.history.allSatisfy { $0.gpu != nil && $0.gpuPower != nil } == true)
        // The MacBook's GPU reports neither temperature nor power.
        #expect(byID[ID.macBookPro]?.latest?.gpus.first?.temp == nil && byID[ID.macBookPro]?.latest?.gpus.first?.power == nil)
        #expect(byID[ID.macBookPro]?.latest?.actions.isEmpty == true && byID[ID.macBookPro]?.hw?.formFactor == "laptop")
        #expect(byID[ID.dgxSpark]?.latest?.ai?.map(\.app) == ["ComfyUI", "Ollama"] && byID[ID.dgxSpark]?.latest?.powerEst?.cpuMeasured == true)
        #expect(byID[ID.gamingPC]?.latest?.ai == [] && byID[ID.homeServer]?.latest?.ai == nil)
        #expect(byID[ID.gamingPC]?.latest?.cpu.cores.count == 32 && byID[ID.gamingPC]?.latest?.fans.count == 4)
        // One version behind what the hub has published.
        #expect(byID[ID.studioPC]?.latest?.appVersion == "1.2.30" && byID[ID.gamingPC]?.latest?.appVersion == DemoHubAPI.publishedVersion)
        // Off for three days, never heard from since the hub started, and wakeable.
        let off = try #require(byID[ID.livingRoomPC])
        #expect(off.latest == nil && off.macs == ["70:85:c2:6b:f0:07"] && off.lastSeen == Self.noon - 3 * Self.day)

        // Everything is in range and adds up.
        for device in devices where device.online {
            let report = try #require(device.latest)
            #expect((0...100).contains(report.cpu.usage ?? -1) && report.memory.used ?? 0 < report.memory.total ?? 0, "\(device.id)")
            let power = try #require(report.powerEst)
            #expect(abs(power.cpu + power.gpu + power.rest + power.losses - power.watts) < 0.3 && power.watts > 10, "\(device.id)")
            #expect(device.history.last?.power == power.watts && device.history.last?.cpu == report.cpu.usage, "\(device.id)")
        }
        #expect(try await hub.devices() == devices)
    }

    @Test func theSameSeedShowsTheSameHubAndAnotherSeedADifferentOne() async throws {
        let (first, _) = Self.make(seed: 7), (second, _) = Self.make(seed: 7), (other, _) = Self.make(seed: 8)
        #expect(try await first.devices() == second.devices())
        #expect(try await first.devices() != other.devices())
        let window = (from: Self.noon - 2 * Self.day, to: Self.noon - Self.day)
        #expect(try await first.history(device: ID.gamingPC, from: window.from, to: window.to, points: 300) == second.history(device: ID.gamingPC, from: window.from, to: window.to, points: 300))
        #expect(try await first.energy(bounds: [window.from, window.to]) == second.energy(bounds: [window.from, window.to]))
        #expect(try await first.alerts() == second.alerts())
        #expect(try await first.createBrowserInvitation() == second.createBrowserInvitation())
        #expect(try await first.createBrowserInvitation() != other.createBrowserInvitation())
    }

    @Test func reportsComeEveryTwoSecondsAndStatusEveryThree() async throws {
        let (hub, clock) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        await clock.waitForSleepers()
        #expect(listener.events.count == 1)                        // nothing moves until the clock does

        await Self.run(clock, for: 2000)
        await listener.wait(for: 5, "report")
        #expect(listener.events("status").isEmpty)
        for case .report(let id, let device, let sample) in listener.events {
            #expect(device.id == id && device.online && device.history.isEmpty && device.lastSeen == Self.noon + 2000, "\(id)")
            #expect(sample.t == Self.noon + 2000 && sample.cpu == device.latest?.cpu.usage && device.latest?.receivedAt == sample.t, "\(id)")
        }
        #expect(listener.events("report").compactMap { if case .report(let id, _, _) = $0 { id } else { nil } } == [ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.homeServer, ID.studioPC])

        await Self.run(clock, for: 1000)
        await listener.wait(for: 1, "status")
        #expect(listener.events("status").last == .status([ID.gamingPC: true, ID.dgxSpark: true, ID.macBookPro: true, ID.homeServer: true, ID.studioPC: true, ID.livingRoomPC: false]))

        await Self.run(clock, for: 3000)                           // six seconds in: reports at 2, 4, 6 and status at 3, 6
        await listener.wait(for: 15, "report")
        await listener.wait(for: 2, "status")
        #expect(listener.events("report").count == 15 && listener.events("status").count == 2 && listener.events("alert").isEmpty)

        // A second listener gets its own snapshot and the same events from then on.
        let late = StreamListener(hub)
        await late.wait(for: 1, "snapshot")
        await Self.run(clock, for: 2000)
        await late.wait(for: 5, "report")
        await listener.wait(for: 20, "report")
        guard case .snapshot(let devices) = try #require(late.events.first) else { return }
        #expect(devices.first?.history.last?.t == Self.noon + 6000)

        // With nobody listening the timer stops.
        listener.stop()
        late.stop()
        #expect(await EventStreamTests.eventually { listener.hasEnded && late.hasEnded })
        clock.advance(by: 3000)
        #expect(await EventStreamTests.eventually { clock.sleeperCount == 0 })
    }

    // MARK: History

    @Test func historyComesAtTheResolutionTheHubWouldUse() async throws {
        let (hub, _) = Self.make()
        // Ten minutes in 360 points: finer than the samples, so the samples themselves.
        let live = try await hub.history(device: ID.gamingPC, range: .tenMinutes, points: 360)
        #expect(live.resolution == 2000 && live.points.count == 301 && live.from == Self.noon - 600_000 && live.to == Self.noon)
        #expect(live.points.allSatisfy { $0.cpuMax == nil && $0.n == nil && $0.gpu != nil })
        #expect(zip(live.points, live.points.dropFirst()).allSatisfy { $1.t - $0.t == 2000 })

        // An hour: ten-second averages of the raw samples, each with its peak.
        let hour = try await hub.history(device: ID.gamingPC, range: .hour, points: 360)
        #expect(hour.resolution == 10_000 && hour.points.count == 361)
        #expect(hour.points.allSatisfy { ($0.cpuMax ?? -1) >= ($0.cpu ?? 0) - 0.006 && $0.powerMax != nil && $0.gpuTempMax != nil })

        // Six hours: the stored minute averages.
        let six = try await hub.history(device: ID.gamingPC, range: .sixHours, points: 360)
        #expect(six.resolution == 60_000 && six.points.count == 361 && six.points.allSatisfy { $0.n == 30 && $0.cpuMax != nil })

        // A day in a hundred points: wider buckets of those minutes.
        let day = try await hub.history(device: ID.gamingPC, from: Self.noon - Self.day, to: Self.noon, points: 100)
        #expect(day.resolution == 864_000 && day.points.count == 101 && day.points.first?.t == Self.noon - Self.day)
        #expect(day.points.allSatisfy { ($0.cpuMax ?? -1) >= ($0.cpu ?? 0) && ($0.powerMax ?? -1) >= ($0.power ?? 0) && $0.n == nil })

        // Thirty days at the dashboard's widest: the hub's limits on the point count apply.
        let month = try await hub.history(device: ID.gamingPC, range: .month, points: 1200)
        #expect(month.resolution == 2_160_000 && (1200...1201).contains(month.points.count))
        #expect(try await hub.history(device: ID.gamingPC, range: .hour, points: 1).points.count == 11)        // Math.max(10, …)
        #expect(try await hub.history(device: ID.gamingPC, range: .day, points: 0).resolution == 72_000)       // || 1200

        // The same minute reads the same in whatever window it is asked for.
        let narrow = try await hub.history(device: ID.gamingPC, from: Self.noon - 2 * Self.hour, to: Self.noon - Self.hour, points: 60)
        #expect(narrow.resolution == 60_000 && narrow.points.count == 61)
        let within = six.points.filter { $0.t >= narrow.from && $0.t <= narrow.to }
        #expect(within == narrow.points)
    }

    @Test func historyHasTheGapsTheDevicesHad() async throws {
        let (hub, _) = Self.make()
        // The server has no GPU: every GPU series is empty at every resolution.
        for range in [HistoryRange.tenMinutes, .hour, .day] {
            let points = try await hub.history(device: ID.homeServer, range: range, points: 360).points
            #expect(!points.isEmpty && points.allSatisfy { $0.gpu == nil && $0.gpuTemp == nil && $0.gpuPower == nil && $0.gpuMax == nil && $0.cpu != nil }, "\(range)")
        }
        // The MacBook's GPU has a load but no temperature or power.
        let mac = try await hub.history(device: ID.macBookPro, range: .hour, points: 360).points
        #expect(mac.allSatisfy { $0.gpu != nil && $0.gpuTemp == nil && $0.gpuPower == nil })

        // The DGX was off from thirty to twenty-six hours ago.
        let outage = (from: Self.noon - 30 * Self.hour, to: Self.noon - 26 * Self.hour)
        let around = try await hub.history(device: ID.dgxSpark, from: outage.from - Self.hour, to: outage.to + Self.hour, points: 360)
        #expect(around.resolution == 60_000 && around.points.count == 361 - 239)
        #expect(around.points.allSatisfy { $0.t <= outage.from || $0.t >= outage.to })
        #expect(around.points.contains { $0.t == outage.from } && around.points.contains { $0.t == outage.to })

        // The laptop is closed before seven in the morning, hub time.
        let morning = try await hub.history(device: ID.macBookPro, from: Self.noon - 12 * Self.hour, to: Self.noon, points: 720)
        #expect(morning.points.count == 301 && morning.points.first?.t == Self.noon - 5 * Self.hour)

        // The living-room PC has been off for three days; before that it has a history like any other.
        #expect(try await hub.history(device: ID.livingRoomPC, range: .sixHours, points: 360) == HistoryResponse(from: Self.noon - 6 * Self.hour, to: Self.noon, resolution: 60_000))
        #expect(try await hub.history(device: ID.livingRoomPC, range: .tenMinutes, points: 360).points.isEmpty)
        let week = try await hub.history(device: ID.livingRoomPC, range: .week, points: 700)
        #expect(!week.points.isEmpty && week.points.allSatisfy { $0.t < Self.noon - 3 * Self.day })

        // Nothing is older than what the hub keeps.
        let old = try await hub.history(device: ID.gamingPC, from: Self.noon - 31 * Self.day, to: Self.noon - 29 * Self.day, points: 48)
        #expect(old.points.allSatisfy { $0.t >= Self.noon - 30 * Self.day - old.resolution } && old.points.count == 25)

        #expect(await hubError { _ = try await hub.history(device: "nobody", range: .hour, points: 360) } == .http(status: 404, message: "not found"))
        #expect(await hubError { _ = try await hub.history(device: ID.gamingPC, from: 2000, to: 1000, points: 10) } == .http(status: 400, message: "bad range"))
        #expect(await hubError { _ = try await hub.history(device: ID.gamingPC, from: 1000, to: 1000, points: 10) } == .http(status: 400, message: "bad range"))
    }

    // MARK: Energy

    @Test func energyAgreesWithTheHistoryItSummarises() async throws {
        let (hub, _) = Self.make()
        let week = (0...7).map { Self.noon - 7 * Self.day + Double($0) * Self.day }
        let response = try await hub.energy(bounds: week)
        #expect(response.bounds == week && response.settings == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))
        #expect(response.devices.map(\.id) == [ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.homeServer, ID.studioPC, ID.livingRoomPC])
        let byID = Dictionary(uniqueKeysWithValues: response.devices.map { ($0.id, $0) })

        // Minutes online: all week, minus the outage, minus seven hours a night, minus the last three days.
        #expect(byID[ID.gamingPC]?.minutes == 7 * 1440 && byID[ID.dgxSpark]?.minutes == 7 * 1440 - 239)
        #expect(byID[ID.macBookPro]?.minutes == 7 * 1020 && byID[ID.livingRoomPC]?.minutes == 4 * 1440)
        #expect(byID[ID.gamingPC]?.firstData == week[0] && byID[ID.livingRoomPC]?.buckets.suffix(3) == [0, 0, 0])
        for summary in response.devices {
            #expect(summary.buckets.count == 7 && summary.costBuckets?.count == 7 && summary.estimatedMinutes == 0, "\(summary.id)")
            #expect(abs(summary.buckets.reduce(0, +) - summary.wh) < 1 && summary.wh > 100, "\(summary.id)")
            // A flat rate: cost is energy times price.
            #expect(abs((summary.cost ?? -1) - summary.wh / 1000 * 0.316) < 0.001, "\(summary.id)")
            #expect(abs((summary.costBuckets ?? []).reduce(0, +) - (summary.cost ?? -1)) < 0.001, "\(summary.id)")
            #expect((summary.stats.power?.peak ?? 0) >= (summary.stats.power?.avg ?? 1) && summary.bytes.rx > 0 && summary.bytes.dw > 0, "\(summary.id)")
        }
        #expect(byID[ID.homeServer]?.stats.gpu == nil && byID[ID.homeServer]?.stats.gpuTemp == nil && byID[ID.homeServer]?.stats.cpu != nil)
        #expect(byID[ID.macBookPro]?.stats.gpu != nil && byID[ID.macBookPro]?.stats.gpuTemp == nil)
        // The 575 W card draws more than the laptop.
        #expect((byID[ID.gamingPC]?.wh ?? 0) > 5 * (byID[ID.macBookPro]?.wh ?? .infinity))

        // One hour, against the minute points the history gives for it.
        let from = Self.noon - 2 * Self.hour, to = Self.noon - Self.hour
        for id in [ID.gamingPC, ID.homeServer, ID.studioPC] {
            let summary = try #require(try await hub.energy(bounds: [from, to]).devices.first { $0.id == id })
            let minutes = try await hub.history(device: id, from: from, to: to, points: 60).points.filter { $0.t < to }
            #expect(minutes.count == 60 && summary.minutes == 60)
            let wattHours = minutes.compactMap(\.power).reduce(0, +) / 60
            #expect(abs(summary.wh - wattHours) <= 0.5 && abs((summary.buckets.first ?? 0) - wattHours) <= 0.051, "\(id)")
            let average = minutes.compactMap(\.cpu).reduce(0, +) / 60
            #expect(abs((summary.stats.cpu?.avg ?? -1) - average) <= 0.051, "\(id)")
            #expect(summary.stats.power?.peak == minutes.compactMap(\.powerMax).max().map { ($0 * 10).rounded() / 10 }, "\(id)")
        }

        for bad in [[], [1], [2, 1], [1, 1], [0, .nan], [0, 33 * Self.day], Array(repeating: 0.0, count: 801).enumerated().map { Double($0.offset) }] as [[Double]] {
            #expect(await hubError { _ = try await hub.energy(bounds: bad) } == .http(status: 400, message: "bad bounds"), "\(bad.count) bounds")
        }
    }

    @Test func aPriceIsValidatedSavedAnnouncedAndApplied() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        #expect(try await hub.energySettings() == EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"))

        // Rates are kept to four decimals, hours to quarters, periods in order.
        let saved = try await hub.saveEnergySettings(EnergySettings(
            region: "custom", rate: 0.100049, currency: "EUR",
            tou: [TouPeriod(from: 16.1, to: 21, rate: 0.42), TouPeriod(from: 11, to: 12, rate: 1)]))
        #expect(saved == EnergySettings(region: "custom", rate: 0.1, currency: "EUR", tou: [TouPeriod(from: 11, to: 12, rate: 1), TouPeriod(from: 16, to: 21, rate: 0.42)]))
        #expect(try await hub.energySettings() == saved)
        await listener.wait(for: 1, "energySettings")
        #expect(listener.events("energySettings") == [.energySettings(saved)])
        #expect(try await hub.alerts().priceSet)

        // Each minute is charged at the rate of its hour, in the hub's time zone: 10–11 at the base rate, 11–12 at 1.00.
        let summary = try #require(try await hub.energy(bounds: [Self.noon - 2 * Self.hour, Self.noon - Self.hour, Self.noon]).devices.first)
        let costs = try #require(summary.costBuckets)
        #expect(abs(costs[0] - summary.buckets[0] / 1000 * 0.1) < 0.0002 && abs(costs[1] - summary.buckets[1] / 1000 * 1) < 0.0002)

        let good = EnergySettings(region: "DE", rate: 0.39, currency: "EUR")
        var invalid: [EnergySettings] = []
        for change in [
            { $0.region = "Germany" }, { $0.region = "de" }, { $0.region = "US-CAL" }, { $0.rate = 0 }, { $0.rate = -1 }, { $0.rate = 1000.5 }, { $0.rate = 0.00004 },
            { $0.currency = "eur" }, { $0.currency = "EURO" }, { $0.tou = [TouPeriod(from: 5, to: 5, rate: 1)] }, { $0.tou = [TouPeriod(from: 6, to: 5, rate: 1)] },
            { $0.tou = [TouPeriod(from: -1, to: 5, rate: 1)] }, { $0.tou = [TouPeriod(from: 1, to: 25, rate: 1)] }, { $0.tou = [TouPeriod(from: 1, to: 2, rate: 0)] },
            { $0.tou = Array(repeating: TouPeriod(from: 1, to: 2, rate: 1), count: 13) },
        ] as [(inout EnergySettings) -> Void] {
            var settings = good
            change(&settings)
            invalid.append(settings)
        }
        for settings in invalid {
            #expect(await hubError { _ = try await hub.saveEnergySettings(settings) } == .http(status: 400, message: "invalid settings"), "\(settings)")
        }
        #expect(try await hub.energySettings() == saved && listener.events("energySettings").count == 1)
        #expect(try await hub.saveEnergySettings(EnergySettings(region: "US", rate: 1000, currency: "USD")) == EnergySettings(region: "US", rate: 1000, currency: "USD"))
    }

    // MARK: Devices

    @Test func renameRemoveAndReorderAnswerAndAnnounceLikeAHub() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")

        // sec.cleanText(name, 60): no control characters, trimmed, sixty characters.
        let renamed = try await hub.rename(device: ID.gamingPC, name: "  Battle\u{7}station \n")
        #expect(renamed.name == "Battlestation" && renamed.renamed && renamed.hostname == "Gaming PC" && renamed.history.count == 301)
        await listener.wait(for: 1, "device")
        #expect(listener.events("device") == [.device(renamed)])
        #expect(try await hub.rename(device: ID.gamingPC, name: String(repeating: "x", count: 80)).name == String(repeating: "x", count: 60))
        // A name with nothing in it changes nothing, and the hub still says where things stand.
        #expect(try await hub.rename(device: ID.dgxSpark, name: " \t ").name == "DGX Spark")
        await listener.wait(for: 3, "device")
        #expect(try await hub.devices().first { $0.id == ID.dgxSpark }?.renamed == false)
        #expect(await hubError { _ = try await hub.rename(device: "nobody", name: "x") } == .http(status: 404, message: "not found"))

        // Unknown ids are skipped; the positions are those of the ids that are left.
        try await hub.setOrder(ids: [ID.livingRoomPC, "nobody", ID.homeServer, ID.gamingPC])
        await listener.wait(for: 1, "order")
        #expect(listener.events("order") == [.order([ID.livingRoomPC: 0, ID.homeServer: 1, ID.gamingPC: 2, ID.dgxSpark: 1, ID.macBookPro: 2, ID.studioPC: 4])])

        try await hub.remove(device: ID.homeServer)
        await listener.wait(for: 1, "removed")
        #expect(listener.events("removed") == [.removed(ID.homeServer)])
        #expect(try await hub.devices().map(\.id) == [ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.studioPC, ID.livingRoomPC])
        // Its disk alert went with it.
        #expect(try await hub.alerts().active.map(\.device) == [ID.livingRoomPC])
        #expect(await hubError { try await hub.remove(device: ID.homeServer) } == .http(status: 404, message: "not found"))
        #expect(await hubError { _ = try await hub.history(device: ID.homeServer, range: .hour, points: 10) } == .http(status: 404, message: "not found"))
        #expect(try await hub.energy(bounds: [Self.noon - Self.hour, Self.noon]).devices.count == 5)
    }

    @Test func wakingTheSleepingPCBringsItBack() async throws {
        let (hub, clock) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        // No network card address on record: the hub says so.
        #expect(await hubError { try await hub.wake(device: ID.macBookPro) } == .http(status: 400, message: "This device hasn't reported a network card address yet."))
        #expect(await hubError { try await hub.wake(device: "nobody") } == .http(status: 404, message: "not found"))

        try await hub.wake(device: ID.livingRoomPC)
        await listener.wait(for: 1, "actionResult")
        #expect(listener.events("actionResult") == [.actionResult(id: ID.livingRoomPC, name: "Living Room PC", result: .init(ok: true, message: "Wake-up signal sent."))])

        await Self.run(clock, for: 5000)                           // not yet: it takes six seconds to come up
        await listener.wait(for: 10, "report")
        #expect(listener.events("status").last == .status([ID.gamingPC: true, ID.dgxSpark: true, ID.macBookPro: true, ID.homeServer: true, ID.studioPC: true, ID.livingRoomPC: false]))
        #expect(listener.alerts.isEmpty)

        await Self.run(clock, for: 1000)
        await listener.wait(for: 16, "report")                     // five at six seconds, plus its first
        await listener.wait(for: 2, "status")
        guard case .report(let id, let device, _) = try #require(listener.events("report").last) else { return }
        #expect(id == ID.livingRoomPC && device.online && device.latest?.cpu.name == "AMD Ryzen 5 5600G")
        #expect(listener.events("status").last == .status([ID.gamingPC: true, ID.dgxSpark: true, ID.macBookPro: true, ID.homeServer: true, ID.studioPC: true, ID.livingRoomPC: true]))

        // Its offline alert clears, and with "also announce when an alert clears" on, apps are told.
        let cleared = try #require(listener.alerts.first)
        #expect(listener.alerts.count == 1 && cleared.notify && cleared.event.state == .resolved && cleared.event.type == .offline)
        #expect(cleared.event.title == "Living Room PC is back online" && cleared.event.message.hasPrefix("It was offline since 12:00"))
        #expect(cleared.active.map(\.device) == [ID.homeServer])
        #expect(try await hub.alerts().events.first == cleared.event)

        await Self.run(clock, for: 2000)
        await listener.wait(for: 22, "report")                     // it reports with the others from now on
        #expect(try await hub.history(device: ID.livingRoomPC, range: .tenMinutes, points: 360).points.count == 2)
    }

    @Test func aDeviceThatStopsReportingGoesOfflineAndThenAlerts() async throws {
        let (hub, clock) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        hub.setReporting(false, device: ID.homeServer)
        hub.setReporting(false, device: ID.homeServer)             // twice is once

        await Self.run(clock, for: 27_000, step: 3000)
        guard case .status(let before) = try #require(listener.events("status").last) else { return }
        #expect(before[ID.homeServer] == true)                     // thirty seconds have not passed
        await Self.run(clock, for: 3000, step: 3000)
        await listener.wait(for: 10, "status")
        guard case .status(let after) = try #require(listener.events("status").last) else { return }
        #expect(after[ID.homeServer] == false && after[ID.gamingPC] == true)
        #expect(!listener.events("report").contains { if case .report(ID.homeServer, _, _) = $0 { true } else { false } })
        let stopped = try #require(try await hub.devices().first { $0.id == ID.homeServer })
        #expect(!stopped.online && stopped.lastSeen == Self.noon && stopped.latest != nil && stopped.history.last?.t == Self.noon)

        // The default rule: offline for ten minutes.
        await Self.run(clock, for: 567_000, step: 3000)
        #expect(listener.alerts.isEmpty)
        await Self.run(clock, for: 3000, step: 3000)
        await listener.wait(for: 1, "alert")
        let fired = try #require(listener.alerts.first)
        #expect(fired.notify && fired.event.state == .firing && fired.event.title == "Home Server is offline" && fired.event.message.hasPrefix("No reports since 12:00"))
        #expect(fired.event.t == Self.noon + 600_000 && fired.active.first?.device == ID.homeServer && fired.active.count == 3)

        // Back on: reports again, the alert clears.
        hub.setReporting(true, device: ID.homeServer)
        await Self.run(clock, for: 3000, step: 3000)
        await listener.wait(for: 2, "alert")
        #expect(listener.alerts.last?.event.title == "Home Server is back online" && listener.alerts.last?.active.count == 2)
    }

    @Test func aBrowserLinkIsMadeForTheHubsOrigin() async throws {
        let (hub, _) = Self.make()
        let first = try await hub.createBrowserInvitation(), second = try await hub.createBrowserInvitation()
        #expect(first != second)
        for link in [first, second] {
            let text = link.absoluteString
            #expect(text.hasPrefix("https://hub.demo.example/unlock#join="))
            #expect(HubIdentity.isValidSecret(String(text.dropFirst("https://hub.demo.example/unlock#join=".count))))
        }
        let info = try await hub.info()
        #expect(info.isDeviceMonitor && info.canShare && !info.canEnroll && !info.locked && info.origin == "https://hub.demo.example")
        #expect(try await hub.remoteStatus() == RemoteStatus(installed: false, port: 7777, canConfigure: false, platform: "linux"))
        #expect(try await hub.mobileClients() == [MobileClient(id: DemoHubAPI.enrollmentID, name: "iPhone", created: Self.noon, lastSeen: Self.noon)])
        #expect(Enrollment.isValidID(DemoHubAPI.enrollmentID))
    }

    @Test func publishedVersionsAreKnownAndAnnounced() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        #expect(try await hub.latestVersion(platform: .windows) == "1.2.33")
        #expect(try await hub.latestVersion(platform: .mac) == "1.2.33")
        hub.publishUpdate(platform: .mac, version: "1.3.0")
        await listener.wait(for: 1, "update")
        #expect(listener.events("update") == [.update(platform: "mac", version: "1.3.0")])
        #expect(try await hub.latestVersion(platform: .mac) == "1.3.0")
        #expect(try await hub.latestVersion(platform: .windows) == "1.2.33")
    }

    // MARK: Alerts

    @Test func theDemoOpensWithAlertsAlreadyFiringAndALog() async throws {
        let (hub, _) = Self.make()
        let alerts = try await hub.alerts()
        // DEFAULT_RULES of alerts.js.
        #expect(alerts.settings.rules.map(\.type) == [.offline, .cpuTemp, .gpuTemp, .disk])
        #expect(alerts.settings.rules.map(\.threshold) == [nil, 90, 85, 90] && alerts.settings.rules.map(\.minutes) == [10, 2, 2, 0])
        #expect(alerts.settings.rules.allSatisfy { $0.enabled && $0.appliesToAllDevices && $0.isAcceptable && $0.id.count == 12 })
        #expect(Set(alerts.settings.rules.map(\.id)).count == 4)
        #expect(alerts.settings.channels == AlertChannels() && alerts.settings.notifyResolved && alerts.settings.tempUnit == .celsius && alerts.priceSet)

        // Most recent first.
        #expect(alerts.active.map(\.device) == [ID.homeServer, ID.livingRoomPC])
        let disk = alerts.active[0], offline = alerts.active[1]
        #expect(disk.type == .disk && disk.title == "Home Server: disk /mnt/backup is 95% full" && disk.message == "Over your 90% limit \u{B7} 400.0 GB free.")
        #expect(disk.value == 95 && disk.threshold == 90 && disk.since == Self.noon - 2 * Self.hour && disk.deviceName == "Home Server")
        #expect(offline.type == .offline && offline.title == "Living Room PC is offline" && offline.message.hasPrefix("No reports since 12:00") && offline.message.hasSuffix("PM."))
        #expect(offline.since == Self.noon - 3 * Self.day + 600_000 && offline.value == nil && offline.threshold == nil)

        #expect(alerts.events.map(\.title) == [
            "Home Server: disk /mnt/backup is 95% full", "Gaming PC: GPU temperature back to normal", "Gaming PC: GPU temperature 87\u{B0}C",
            "DGX Spark is back online", "DGX Spark is offline", "Living Room PC is offline",
        ])
        #expect(alerts.events.map(\.t) == alerts.events.map(\.t).sorted(by: >) && Set(alerts.events.map(\.id)).count == 6)
        #expect(alerts.events[1].message == "Now 79\u{B0}C (limit 85\u{B0}C)." && alerts.events[1].state == .resolved)
        #expect(alerts.events[2].message == "Above 85\u{B0}C for 2 min." && alerts.events[2].value == 87)
        #expect(alerts.events[3].message.hasPrefix("It was offline since 6:00"))
        #expect(alerts.events.allSatisfy { !$0.test && $0.ruleId != nil && $0.deviceName != nil })
    }

    @Test func aSavedRuleIsEvaluatedAgainstTheNextReports() async throws {
        let (hub, clock) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        var settings = try await hub.alerts().settings
        settings.rules.append(AlertRule(id: "not an id", type: .mem, device: ID.dgxSpark, threshold: 50, minutes: 0))
        settings.tempUnit = .fahrenheit

        let update = try await hub.saveAlerts(settings)
        let rule = try #require(update.settings.rules.last)
        #expect(update.settings.rules.count == 5 && rule.type == .mem && rule.id != "not an id" && rule.id.count == 12)   // the hub gives it an id
        #expect(update.settings.tempUnit == .fahrenheit && update.active.count == 2)
        await listener.wait(for: 1, "alerts")
        #expect(listener.events("alerts") == [.alerts(settings: update.settings, active: update.active)])
        #expect(try await hub.alerts().settings == update.settings)

        // The DGX uses 86 % of its memory: the rule fires with its next report.
        await Self.run(clock, for: 2000)
        await listener.wait(for: 1, "alert")
        let fired = try #require(listener.alerts.first)
        #expect(listener.alerts.count == 1 && fired.notify && fired.event.ruleId == rule.id && fired.event.device == ID.dgxSpark)
        #expect(fired.event.title.hasPrefix("DGX Spark: Memory use 8") && fired.event.message == "Above 50%.")
        #expect(fired.active.map(\.ruleId).first == rule.id && fired.active.count == 3 && fired.active.first?.threshold == 50)
        await Self.run(clock, for: 4000)
        #expect(listener.alerts.count == 1)                        // firing once, not with every report

        // Switched off: what was firing under it is forgotten without a word.
        var off = update.settings
        off.rules[4].enabled = false
        #expect(try await hub.saveAlerts(off).active.count == 2)
        await Self.run(clock, for: 2000)
        #expect(listener.alerts.count == 1)

        // On again with a limit above the reading: nothing fires. Lowered again: it fires anew.
        off.rules[4].enabled = true
        off.rules[4].threshold = 99
        _ = try await hub.saveAlerts(off)
        await Self.run(clock, for: 2000)
        #expect(listener.alerts.count == 1)
        off.rules[4].threshold = 60
        _ = try await hub.saveAlerts(off)
        await Self.run(clock, for: 2000)
        await listener.wait(for: 2, "alert")
        #expect(listener.alerts.last?.event.state == .firing && listener.alerts.last?.event.message == "Above 60%.")
    }

    @Test func alertSettingsAreValidatedLikeTheHubs() async throws {
        let (hub, _) = Self.make()
        let good = try await hub.alerts().settings
        var invalid: [AlertSettings] = []
        for change in [
            { $0.rules[1].threshold = 500 }, { $0.rules[1].threshold = nil }, { $0.rules[0].minutes = 0 }, { $0.rules[3].minutes = 2000 },
            { $0.rules[2].device = "not a device!" }, { $0.rules.append(AlertRule(type: .other("humidity"), threshold: 5)) },
            { $0.channels.ntfy.topic = "has spaces" }, { $0.channels.ntfy.email = "nobody" }, { $0.channels.ntfy.server = "ftp://ntfy.example" },
            { $0.channels.ntfy.server = "http://localhost:8080" }, { $0.channels.webhook.url = "https://user:pass@example.com/hook" },
            { $0.channels.webhook.url = "http://127.0.0.1/hook" },
        ] as [(inout AlertSettings) -> Void] {
            var settings = good
            change(&settings)
            invalid.append(settings)
        }
        for (index, settings) in invalid.enumerated() {
            #expect(await hubError { _ = try await hub.saveAlerts(settings) } == .http(status: 400, message: "invalid alert settings"), "case \(index)")
        }
        #expect(try await hub.alerts().settings == good)

        // The webhook address is taken and never given back; sending the answer back keeps it.
        var channels = good
        channels.channels.webhook = .init(enabled: true, url: "https://chat.example/hooks/abc/")
        channels.channels.ntfy = .init(enabled: true, server: "", topic: " device_monitor-1 ", email: "me@example.com")
        channels.channels.desktop = false
        channels.notifyResolved = false
        let stored = try await hub.saveAlerts(channels).settings
        #expect(stored.channels.webhook == .init(enabled: true, url: "", keepUrl: true))
        #expect(stored.channels.ntfy == .init(enabled: true, server: "https://ntfy.sh", topic: "device_monitor-1", email: "me@example.com"))
        #expect(!stored.channels.desktop && !stored.notifyResolved)
        #expect(try await hub.saveAlerts(stored).settings == stored)
        // A channel without what it needs is switched off; an emptied webhook is forgotten.
        var emptied = stored
        emptied.channels.webhook = .init(enabled: true, url: "", keepUrl: false)
        emptied.channels.ntfy.topic = ""
        let cleared = try await hub.saveAlerts(emptied).settings
        #expect(cleared.channels.webhook == .init() && !cleared.channels.ntfy.enabled)
        // More than a hundred rules: the hub keeps the first hundred.
        var many = good
        many.rules = (0..<120).map { _ in AlertRule(type: .cpu, threshold: 99, minutes: 5) }
        #expect(try await hub.saveAlerts(many).settings.rules.count == 100)
    }

    @Test func aTestAlertIsAnnouncedButNotLogged() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        #expect(try await hub.testAlert() == AlertTestResult())    // no channel is on: nothing to deliver to
        await listener.wait(for: 1, "alert")
        let test = try #require(listener.alerts.first)
        #expect(test.notify && test.event.test && test.event.title == "Device Monitor test alert" && test.event.message == "Alerts from your hub will arrive like this.")
        #expect(test.event.ruleId == nil && test.event.device == nil && test.event.t == Self.noon && test.active.count == 2)
        #expect(try await hub.alerts().events.count == 6)

        // With the app channel off the hub says not to announce it; channels that are on report how it went.
        var settings = try await hub.alerts().settings
        settings.channels.desktop = false
        settings.channels.ntfy = .init(enabled: true, topic: "demo")
        _ = try await hub.saveAlerts(settings)
        #expect(try await hub.testAlert() == AlertTestResult(ntfy: .init(ok: true)))
        await listener.wait(for: 2, "alert")
        #expect(listener.alerts.last?.notify == false && listener.alerts.last?.event.id != test.event.id)

        try await hub.clearAlertLog()
        let after = try await hub.alerts()
        #expect(after.events.isEmpty && after.active.count == 2)
    }

    @Test func aFullDiskFiresAndClears() async throws {
        let (hub, clock) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        hub.simulateDiskAlert(seconds: 3)
        await Self.run(clock, for: 2000)
        await listener.wait(for: 1, "alert")
        let fired = try #require(listener.alerts.first)
        #expect(fired.notify && fired.event.state == .firing && fired.event.type == .disk && fired.event.device == ID.gamingPC)
        #expect(fired.event.title == "Gaming PC: disk D: is 97% full" && fired.event.message == "Over your 90% limit \u{B7} 120.0 GB free.")
        #expect(fired.active.map(\.device) == [ID.gamingPC, ID.homeServer, ID.livingRoomPC])
        guard case .report(_, let device, _) = try #require(listener.events("report").first) else { return }
        #expect(device.latest?.disks.last?.used == 4e12 * 0.97)

        await Self.run(clock, for: 2000)                           // four seconds in: the drive is back to normal
        await listener.wait(for: 2, "alert")
        let cleared = try #require(listener.alerts.last)
        #expect(cleared.notify && cleared.event.state == .resolved && cleared.event.title == "Gaming PC: disk space back under 90%" && cleared.event.message == "Now 78% used.")
        #expect(cleared.active.map(\.device) == [ID.homeServer, ID.livingRoomPC])
        #expect(try await hub.alerts().events.prefix(2).map(\.state) == [.resolved, .firing])
    }

    // MARK: The enrollment

    @Test func aRevokedEnrollmentIsRefusedEverywhere() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")
        hub.revokeEnrollment()
        // The hub drops the connection; the refusal comes with whatever is tried next.
        #expect(await EventStreamTests.eventually { listener.hasEnded })
        #expect(listener.failure == .unreachable("The connection to the hub was lost."))
        let refusal = HubError.unauthorized(status: 401, message: "Open a fresh dashboard invitation.")
        let again = StreamListener(hub)
        #expect(await EventStreamTests.eventually { again.hasEnded })
        #expect(again.failure == refusal && again.events.isEmpty)
        #expect(await hubError { _ = try await hub.devices() } == refusal)
        #expect(await hubError { _ = try await hub.alerts() } == refusal)
        #expect(await hubError { try await hub.wake(device: ID.livingRoomPC) } == refusal)
        #expect(await hubError { try await hub.unpairSelf() } == refusal)

        // Disconnecting does the same to oneself.
        let (other, _) = Self.make()
        let stream = StreamListener(other)
        await stream.wait(for: 1, "snapshot")
        try await other.unpairSelf()
        #expect(await EventStreamTests.eventually { stream.hasEnded })
        #expect(await hubError { _ = try await other.info() } == refusal)
    }

    @Test func latencyHoldsEveryAnswerBack() async throws {
        let (hub, clock) = Self.make(latency: 250)
        let call = Task { try await hub.devices().count }
        await clock.waitForSleepers()
        clock.advance(by: 249)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: 1)
        #expect(try await call.value == 6)

        // A caller that gives up is told so.
        let abandoned = Task { await hubError { _ = try await hub.devices() } }
        await clock.waitForSleepers()
        abandoned.cancel()
        #expect(await abandoned.value == .cancelled)
    }

    @Test func anUnreachableHubFailsEverythingUntilItIsBack() async throws {
        let (hub, _) = Self.make()
        #expect(hub.availability == .reachable)
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")

        hub.setAvailability(.unreachable)
        #expect(hub.availability == .unreachable)
        // The open stream breaks, as when the hub is switched off…
        #expect(await EventStreamTests.eventually { listener.hasEnded })
        #expect(listener.failure == .unreachable("The connection to the hub was lost."))
        // …and nothing connects after that.
        let refused = HubError.unreachable("Could not connect to the hub.")
        let again = StreamListener(hub)
        #expect(await EventStreamTests.eventually { again.hasEnded })
        #expect(again.failure == refused && again.events.isEmpty)
        #expect(await hubError { _ = try await hub.devices() } == refused)
        #expect(await hubError { try await hub.unpairSelf() } == refused)

        // Back again it is the same hub: a rename made before is still there.
        hub.setAvailability(.reachable)
        _ = try await hub.rename(device: ID.gamingPC, name: "Renamed")
        hub.setAvailability(.unreachable)
        hub.setAvailability(.reachable)
        let back = StreamListener(hub)
        await back.wait(for: 1, "snapshot")
        guard case .snapshot(let devices) = try #require(back.events.first) else { return }
        #expect(devices.first { $0.id == ID.gamingPC }?.name == "Renamed")

        // A revoked enrollment is only heard of from a hub that answers.
        hub.revokeEnrollment()
        hub.setAvailability(.unreachable)
        #expect(await hubError { _ = try await hub.info() } == refused)
        hub.setAvailability(.reachable)
        #expect(await hubError { _ = try await hub.info() }?.isUnauthorized == true)
    }

    @Test func aSilentHubAnswersNothingUntilSomethingChanges() async throws {
        let (hub, _) = Self.make()
        let listener = StreamListener(hub)
        await listener.wait(for: 1, "snapshot")

        hub.setAvailability(.silent)
        #expect(await EventStreamTests.eventually { listener.hasEnded })
        #expect(listener.failure == .unreachable("The hub did not answer in time."))

        // A connection attempt and a request both wait…
        let waiting = StreamListener(hub)
        let count = OSAllocatedUnfairLock(initialState: Int?.none)
        let request = Task {
            let devices = try await hub.devices()
            count.withLock { $0 = devices.count }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!waiting.hasEnded && waiting.events.isEmpty && count.withLock { $0 } == nil)

        // …a caller that gives up is told so…
        let abandoned = Task { await hubError { _ = try await hub.info() } }
        try await Task.sleep(for: .milliseconds(20))
        abandoned.cancel()
        #expect(await abandoned.value == .cancelled)

        // …and when the hub is back the request goes through, and the attempt fails for its owner to repeat.
        hub.setAvailability(.reachable)
        try await request.value
        #expect(count.withLock { $0 } == 6)
        #expect(await EventStreamTests.eventually { waiting.hasEnded })
        #expect(waiting.failure == .unreachable("Could not connect to the hub.") && waiting.events.isEmpty)
        let again = StreamListener(hub)
        await again.wait(for: 1, "snapshot")

        // From silent to switched off, whatever waits fails.
        hub.setAvailability(.silent)
        let late = Task { await hubError { _ = try await hub.info() } }
        try await Task.sleep(for: .milliseconds(20))
        hub.setAvailability(.unreachable)
        #expect(await late.value == .unreachable("Could not connect to the hub."))
    }

    @Test func aHubThatIsDroppedEndsItsStreams() async throws {
        var hub: DemoHubAPI? = DemoHubAPI(configuration: .init(seed: 3, timeZone: Self.gmt), clock: ManualHubClock(now: Self.noon))
        let listener = StreamListener(try #require(hub))
        await listener.wait(for: 1, "snapshot")
        hub = nil
        #expect(await EventStreamTests.eventually { listener.hasEnded })
        #expect(listener.failure == nil)
    }
}

// MARK: - Behind a store

@MainActor
@Suite(.timeLimit(.minutes(2))) struct DemoStoreTests {
    typealias ID = DemoHubAPI.DeviceID

    @Test func theDemoHubDrivesAStore() async throws {
        let (hub, clock) = DemoHubTests.make()
        let (preferences, _) = StoreFixtures.preferences()
        let notifier = NotifierProbe()
        let store = HubStore(api: hub, preferences: preferences, clock: clock, alertNotifier: notifier, locale: Locale(identifier: "en_US"))
        store.start()
        try await eventually("the store is live and has asked for the rest") { store.connection == .live && store.activeTaskCount == 2 }

        // What a dashboard would show as it opens.
        #expect(store.devices.map(\.displayName) == ["Gaming PC", "DGX Spark", "MacBook Pro", "Home Server", "Studio PC", "Living Room PC"])
        #expect(store.counts.text == "5 of 6 devices online" && store.offlineDevices.map(\.id) == [ID.livingRoomPC])
        #expect(store.offlineDevices.first?.macs.isEmpty == false)                       // so the Wake button shows
        #expect(store.series(for: ID.gamingPC).points.count == 301 && store.series(for: ID.gamingPC).hasGPU && !store.series(for: ID.homeServer).hasGPU)
        #expect(store.series(for: ID.livingRoomPC) == .empty)
        #expect(store.latestVersions == ["windows": "1.2.33", "mac": "1.2.33"])
        let label = { (id: String) in store.device(id).flatMap(store.versionLabel(for:)) }
        #expect(label(ID.studioPC) == "v1.2.30 \u{2192} 1.2.33" && label(ID.gamingPC) == "v1.2.33" && label(ID.dgxSpark) == nil)
        #expect(store.energySettings?.region == "US-CA" && store.isEnergySettingsLoaded)
        #expect(store.alerts.isLoaded && store.alerts.active.count == 2 && store.alerts.events.count == 6 && store.alerts.priceSet && store.unseenAlertCount == 6)
        #expect(store.info?.origin == "https://hub.demo.example" && store.info?.canShare == true)

        // Two seconds on: every card has a new sample and has let go of its oldest.
        let before = store.device(ID.gamingPC)?.latest
        await DemoHubTests.run(clock, for: 2000, sleepers: 2)
        try await eventually("the reports are in") { store.series(for: ID.studioPC).points.last?.t == DemoHubTests.noon + 2000 }
        #expect(store.series(for: ID.gamingPC).points.count == 301 && store.series(for: ID.gamingPC).points.first?.t == DemoHubTests.noon - 598_000)
        #expect(store.device(ID.gamingPC)?.latest != before && store.connection == .live)
        await DemoHubTests.run(clock, for: 1000, sleepers: 2)
        try await eventually("the heartbeat is in") { store.lastStatusAt == DemoHubTests.noon + 3000 }

        // A card on a longer range.
        store.setRange(.hour, for: ID.gamingPC)
        try await eventually("the hour is in") { store.series(for: ID.gamingPC).resolution == 10_000 }
        // Ten-second averages of the hour of raw samples up to the last report.
        #expect(store.series(for: ID.gamingPC).points.count == 360 && store.range(for: ID.gamingPC) == .hour)

        // Rename, reorder and remove come back through the stream.
        try await store.rename(device: ID.gamingPC, name: "Battlestation")
        try await eventually("the new name is announced") { store.device(ID.gamingPC)?.name == "Battlestation" }
        try await store.reorder(ids: [ID.studioPC, ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.homeServer])
        #expect(store.devices.map(\.id) == [ID.studioPC, ID.gamingPC, ID.dgxSpark, ID.macBookPro, ID.homeServer, ID.livingRoomPC])
        #expect(try await hub.devices().sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.id) == store.devices.map(\.id))
        try await store.remove(device: ID.macBookPro)
        try await eventually("the removal is announced") { store.device(ID.macBookPro) == nil && store.counts == FleetCounts(online: 4, total: 5) }

        // History and energy for the other two screens.
        let history = try await store.loadHistory(device: ID.dgxSpark, from: clock.now - 6 * 3600e3, to: clock.now, points: 360)
        #expect(history.points.count == 360 && history.resolution == 60_000)
        let energy = try await store.loadEnergy(bounds: (0...7).map { DemoHubTests.noon + (Double($0) - 7) * 86400e3 })
        #expect(energy.devices.count == 5 && energy.settings == store.energySettings)
        let german = try await store.saveEnergySettings(EnergySettings(region: "DE", rate: 0.39, currency: "EUR"))
        #expect(store.energySettings == german && store.energySettings?.currency == "EUR")

        // Alerts: a test alert reaches the notifier, a full disk fires and clears.
        _ = try await store.sendTestAlert()
        try await eventually("the test alert is announced") { notifier.events.count == 1 }
        #expect(notifier.events.first?.test == true && store.alerts.events.count == 6)
        hub.simulateDiskAlert(seconds: 2)
        await DemoHubTests.run(clock, for: 1000, sleepers: 2)
        try await eventually("the disk alert fired") { store.alerts.active.count == 3 }
        #expect(store.alerts.events.first?.title == "Battlestation: disk D: is 97% full" && notifier.events.count == 2 && store.unseenAlertCount == 7)
        await DemoHubTests.run(clock, for: 2000, sleepers: 2)
        try await eventually("the disk alert cleared") { store.alerts.active.count == 2 && store.alerts.events.count == 8 }
        store.markAlertsSeen()
        #expect(store.unseenAlertCount == 0)

        // Waking the sleeping PC.
        try await store.wake(device: ID.livingRoomPC)
        await DemoHubTests.run(clock, for: 9000, sleepers: 2)
        try await eventually("the PC is up") { store.offlineDevices.isEmpty && store.counts == FleetCounts(online: 5, total: 5) }
        // Its first report clears the offline alert; the alert event follows the report.
        try await eventually("its alert cleared") { store.alerts.events.first?.title == "Living Room PC is back online" }
        #expect(store.alerts.active.map(\.device) == [ID.homeServer])

        // A link to share, and the end of the enrollment.
        #expect(try await store.createBrowserInvitation().absoluteString.hasPrefix("https://hub.demo.example/unlock#join="))
        #expect(try await store.loadMobileClients().map(\.id) == [DemoHubAPI.enrollmentID])
        hub.revokeEnrollment()
        try await eventually("the store noticed the stream is gone") { store.connection != .live }
        await clock.waitForSleepers(2)
        clock.advance(by: HubStore.reconnectDelay)
        try await eventually("the store was refused") { store.connection == .unauthorized }
        // The demo's own timer has stopped too: nobody is listening any more.
        try await eventually("nothing is left running") { store.activeTaskCount == 0 && clock.sleeperCount == 0 }
    }

    @Test func theDemoRunsInRealTimeToo() async throws {
        let hub = DemoHubAPI(configuration: .init(seed: 1, reportInterval: 40, statusInterval: 60, timeZone: DemoHubTests.gmt, latency: 5))
        let store = HubStore(api: hub, preferences: StoreFixtures.preferences().0)
        store.start()
        try await eventually("the store is live") { store.connection == .live && store.alerts.isLoaded }
        let first = store.series(for: ID.gamingPC).points.last?.t ?? 0
        try await eventually("reports and heartbeats arrive") { (store.series(for: ID.gamingPC).points.last?.t ?? 0) > first && store.lastStatusAt != nil }
        #expect(store.counts == FleetCounts(online: 5, total: 6))
        // What the session does to disconnect: stop, then have the hub forget the enrollment.
        store.stop()
        try await hub.unpairSelf()
        #expect(store.connection == .idle)
        try await eventually("nothing is left running") { store.activeTaskCount == 0 }
        #expect(await storeError { _ = try await store.refreshInfo() }?.isUnauthorized == true)
        #expect(store.connection == .unauthorized)
    }

    @Test func aStoreOverAFrozenDemoCanBeLetGoOf() async throws {
        // What a preview is: answers that take a moment, on a clock nobody moves.
        let (hub, clock) = DemoHubTests.make(latency: 250)
        var store: HubStore? = HubStore(api: hub, preferences: StoreFixtures.preferences().0, clock: clock)
        let dropped = WeakReference(store)
        store?.start()
        // Waiting on the clock: the hub's ticker, the store's timer, and the four things the
        // store asked for at the start, which will never be answered.
        try await eventually("the store is live and waiting for its answers") { store?.connection == .live && clock.sleeperCount == 6 }
        #expect(store?.alerts.isLoaded == false && store?.activeTaskCount == 6)

        store = nil                                                // without stop()
        try await eventually("the store is gone") { dropped.object == nil }
        try await eventually("only the hub's ticker is still waiting") { clock.sleeperCount == 1 }
    }
}

import Foundation
import os

/// A hub that exists only in memory, for demo mode, SwiftUI previews and UI tests. It behaves
/// like a small real one: six devices that report every two seconds, thirty days of history for
/// any window, energy totals that agree with that history, alert rules that are evaluated, and
/// every operation of `HubAPI` with the answers, errors and stream events the real hub gives.
///
/// The fleet is the one in build/screenshots.js and build/test/mobile-hub.js: a gaming PC, a DGX
/// Spark with AI models loaded, a MacBook, a home server without a GPU and with a nearly full
/// disk, a studio PC with two GPUs, and a living-room PC that has been off for three days and
/// can be woken.
///
/// Nothing is random: what a device shows at a given moment depends only on the seed and that
/// moment. With a `ManualHubClock` the whole hub stands still until the clock is moved.
///
/// ```swift
/// let store = HubStore(api: DemoHubAPI(), preferences: preferences)
/// store.start()
/// ```
public final class DemoHubAPI: HubAPI {
    public struct Configuration: Sendable {
        /// Changes every curve and every generated id.
        public var seed: UInt64
        /// Milliseconds between reports (agents report every two seconds).
        public var reportInterval: Double
        /// Milliseconds between `status` events (the hub sends one every three seconds).
        public var statusInterval: Double
        /// How far back history goes. The hub keeps thirty days.
        public var historyDays: Double
        /// The hub's own time zone: when the laptop sleeps, what time-of-use hours mean and how
        /// alert messages write the time.
        public var timeZone: TimeZone
        /// Milliseconds every request takes, so loading states can be seen.
        public var latency: Double
        /// The origin the hub says it has; the browser link is made for it.
        public var origin: String
        /// How long a woken device takes to start reporting.
        public var wakeDelay: Double

        public init(
            seed: UInt64 = 1, reportInterval: Double = 2000, statusInterval: Double = 3000, historyDays: Double = 30,
            timeZone: TimeZone = .current, latency: Double = 0, origin: String = "https://hub.demo.example", wakeDelay: Double = 6000
        ) {
            self.seed = seed
            self.reportInterval = reportInterval
            self.statusInterval = statusInterval
            self.historyDays = historyDays
            self.timeZone = timeZone
            self.latency = latency
            self.origin = origin
            self.wakeDelay = wakeDelay
        }
    }

    /// The ids of the demo devices, the same as those of build/test/mobile-hub.js.
    public enum DeviceID {
        public static let gamingPC = DemoMachine.gaming
        public static let dgxSpark = DemoMachine.spark
        public static let macBookPro = DemoMachine.macbook
        public static let homeServer = DemoMachine.server
        /// Two GPUs, and a desktop app one version behind.
        public static let studioPC = DemoMachine.studio
        /// Offline, with a network card address: the one `wake` works on.
        public static let livingRoomPC = DemoMachine.livingRoom
    }

    /// The desktop app version the demo hub has published for both platforms.
    public static let publishedVersion = DemoMachine.currentAppVersion
    /// The id of the demo's own enrollment.
    public static let enrollmentID = "5d0c1b7e-3f2a-4c68-9e15-7a4b2d9c6e30"

    /// A device counts as offline after this long without a report (`OFFLINE_MS` in server.js).
    static let offlineAfter: Double = 30_000
    /// Raw samples sent with a snapshot (`LIVE_HISTORY_MS`).
    static let liveHistory: Double = 10 * 60e3

    private struct Run: Sendable {
        var from: Double
        var to: Double?
    }

    /// A registry entry and what the device has been doing since the demo began.
    private struct Machine: Sendable {
        var spec: DemoMachine
        var index: Int
        var name: String
        var renamed = false
        var order: Int
        /// Periods of reporting since the demo began; the last one is open while it reports.
        var runs: [Run]
        var wakeAt: Double?

        var isReporting: Bool { runs.last.map { $0.to == nil } ?? false }
    }

    private struct State: Sendable {
        var machines: [Machine]
        var energy: EnergySettings?
        var alerts: DemoAlerts
        var versions: [UpdatePlatform: String]
        var subscribers: [UInt64: AsyncThrowingStream<HubEvent, any Error>.Continuation] = [:]
        var nextSubscriber: UInt64 = 0
        var driver: Task<Void, Never>?
        var nextReportAt: Double = 0
        var nextStatusAt: Double = 0
        var diskAlertUntil: Double = 0
        var invitations: Int = 0
        var revoked = false
    }

    public let configuration: Configuration
    private let clock: any HubClock
    private let model: DemoModel
    private let state: OSAllocatedUnfairLock<State>

    public init(configuration: Configuration = Configuration(), clock: any HubClock = SystemHubClock()) {
        self.configuration = configuration
        self.clock = clock
        let start = clock.now
        let model = DemoModel(seed: configuration.seed, start: start, historySpan: configuration.historyDays * 86400e3, timeZone: configuration.timeZone)
        self.model = model
        let machines = DemoMachine.fleet.enumerated().map { index, spec in
            Machine(spec: spec, index: index, name: spec.name, order: index, runs: spec.offFor == nil ? [Run(from: start)] : [])
        }
        var alerts = DemoAlerts(seed: configuration.seed, timeZone: configuration.timeZone)
        let subject = { (id: String) in machines.first { $0.spec.id == id }.map { DemoAlerts.Subject(id: id, name: $0.name, online: $0.spec.offFor == nil, lastSeen: nil) } }
        // What already happened when the demo opens: two alerts still firing, three in the past.
        if let off = machines.first(where: { $0.spec.offFor != nil }), let gone = off.spec.offFor, let device = subject(off.spec.id) {
            alerts.seedFiring(rule: .offline, device: device, firedAt: start - gone + 10 * 60e3, value: nil, detail: .init(since: start - gone))
        }
        if let device = subject(DemoMachine.server) {
            alerts.seedFiring(rule: .disk, device: device, firedAt: start - 2 * 3600e3, value: 95, detail: .init(disk: "/mnt/backup", free: 0.4e12))
        }
        if let spark = machines.first(where: { $0.spec.outage != nil }), let outage = spark.spec.outage, let device = subject(spark.spec.id) {
            alerts.seedPast(rule: .offline, device: device, firing: true, at: start - outage.from + 10 * 60e3, value: nil, detail: .init(since: start - outage.from))
            alerts.seedPast(rule: .offline, device: device, firing: false, at: start - outage.to, value: nil, detail: .init(since: start - outage.from))
        }
        if let device = subject(DemoMachine.gaming) {
            alerts.seedPast(rule: .gpuTemp, device: device, firing: true, at: start - 20 * 3600e3, value: 87)
            alerts.seedPast(rule: .gpuTemp, device: device, firing: false, at: start - 19.6 * 3600e3, value: 79)
        }
        state = OSAllocatedUnfairLock(initialState: State(
            machines: machines,
            // build/test/mobile-hub.js saves the same price.
            energy: EnergySettings(region: "US-CA", rate: 0.316, currency: "USD"),
            alerts: alerts,
            versions: [.windows: Self.publishedVersion, .mac: Self.publishedVersion]))
    }

    deinit {
        let (driver, subscribers) = state.withLock { ($0.driver, Array($0.subscribers.values)) }
        driver?.cancel()
        subscribers.forEach { $0.finish() }
    }

    // MARK: - Directing the demo

    /// Stops or resumes a device's reports. The hub shows it offline thirty seconds after the
    /// last one, and an offline rule fires once it has been silent for as long as the rule says.
    public func setReporting(_ reporting: Bool, device id: String) {
        let now = clock.now
        state.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.spec.id == id }), state.machines[index].isReporting != reporting else { return }
            if reporting {
                state.machines[index].runs.append(Run(from: now))
            } else {
                state.machines[index].runs[state.machines[index].runs.count - 1].to = Self.lastTick(now, in: state.machines[index].runs.last)
            }
        }
    }

    /// The Gaming PC's D: drive passes the default 90 % disk rule for `seconds`: an alert fires
    /// with its next report and clears with the first report after that
    /// (`POST /alert` of build/test/mobile-hub.js).
    public func simulateDiskAlert(seconds: Double = 8) {
        let until = clock.now + seconds * 1000
        state.withLock { $0.diskAlertUntil = until }
    }

    /// Publishes a newer desktop app, as dropping an installer into the hub's downloads does.
    public func publishUpdate(platform: UpdatePlatform, version: String) {
        state.withLock { state in
            state.versions[platform] = version
            Self.broadcast(.update(platform: platform.rawValue, version: version), &state)
        }
    }

    /// The hub's operator removed this phone: the stream breaks and everything after is refused.
    public func revokeEnrollment() {
        let streams = state.withLock { state in
            state.revoked = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        // The hub destroys the socket; the refusal comes with the next request.
        streams.forEach { $0.finish(throwing: HubError.unreachable("The connection to the hub was lost.")) }
    }

    // MARK: - HubAPI

    public func info() async throws -> HubInfo {
        try await request { _, _ in
            HubInfo(hostname: "demo-hub", port: 7777, canEnroll: false, canShare: true, origin: self.configuration.origin)
        }
    }

    public func devices() async throws -> [Device] {
        try await request { state, now in state.machines.map { self.view($0, now: now, history: true) } }
    }

    public func rename(device id: String, name: String) async throws -> Device {
        try await request { state, now in
            let index = try Self.index(of: id, in: state)
            // sec.cleanText(body.name, 60); an empty result changes nothing.
            if let cleaned = Self.cleanText(name, 60) {
                state.machines[index].name = cleaned
                state.machines[index].renamed = true
            }
            let device = self.view(state.machines[index], now: now, history: true)
            Self.broadcast(.device(device), &state)
            return device
        }
    }

    public func remove(device id: String) async throws {
        try await request { state, _ in
            state.machines.remove(at: try Self.index(of: id, in: state))
            state.alerts.removeDevice(id)
            Self.broadcast(.removed(id), &state)
        }
    }

    public func setOrder(ids: [String]) async throws {
        try await request { state, _ in
            let known = ids.filter { id in state.machines.contains { $0.spec.id == id } }
            for (position, id) in known.enumerated() {
                if let index = state.machines.firstIndex(where: { $0.spec.id == id }) { state.machines[index].order = position }
            }
            Self.broadcast(.order(Dictionary(state.machines.map { ($0.spec.id, $0.order) }, uniquingKeysWith: { _, last in last })), &state)
        }
    }

    public func history(device id: String, range: HistoryRange, points: Int) async throws -> HistoryResponse {
        let (machine, now) = try await request { state, now in (state.machines[try Self.index(of: id, in: state)], now) }
        return query(machine, from: now - range.milliseconds, to: now, points: points, now: now)
    }

    public func history(device id: String, from: Double, to: Double, points: Int) async throws -> HistoryResponse {
        let (machine, now) = try await request { state, now in (state.machines[try Self.index(of: id, in: state)], now) }
        guard from.isFinite, to.isFinite, from < to else { throw HubError.http(status: 400, message: "bad range") }
        return query(machine, from: from, to: to, points: points, now: now)
    }

    public func energy(bounds: [Double]) async throws -> EnergyResponse {
        let (machines, settings, now) = try await request { state, now in (state.machines, state.energy, now) }
        let increasing = zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 }
        guard (2...800).contains(bounds.count), bounds.allSatisfy(\.isFinite), increasing, bounds[bounds.count - 1] - bounds[0] <= 32 * 86400e3 else {
            throw HubError.http(status: 400, message: "bad bounds")
        }
        return EnergyResponse(bounds: bounds, settings: settings, devices: machines.map { usage($0, bounds: bounds, settings: settings, now: now) })
    }

    public func energySettings() async throws -> EnergySettings? {
        try await request { state, _ in state.energy }
    }

    public func saveEnergySettings(_ settings: EnergySettings) async throws -> EnergySettings {
        try await request { state, _ in
            guard let accepted = Self.validated(settings) else { throw HubError.http(status: 400, message: "invalid settings") }
            state.energy = accepted
            Self.broadcast(.energySettings(accepted), &state)
            return accepted
        }
    }

    public func alerts() async throws -> AlertsResponse {
        try await request { state, now in
            AlertsResponse(
                settings: state.alerts.settings, active: state.alerts.active(self.subjects(state, now: now)), events: state.alerts.recentEvents,
                priceSet: state.energy != nil)
        }
    }

    public func saveAlerts(_ settings: AlertSettings) async throws -> AlertsUpdate {
        try await request { state, now in
            guard let accepted = state.alerts.update(settings) else { throw HubError.http(status: 400, message: "invalid alert settings") }
            let everyone = self.subjects(state, now: now)
            Self.broadcast(.alerts(settings: accepted, active: state.alerts.active(everyone)), &state)
            self.announce(state.alerts.tick(everyone, now: now), &state, now: now)
            return AlertsUpdate(settings: accepted, active: state.alerts.active(everyone))
        }
    }

    public func testAlert() async throws -> AlertTestResult {
        try await request { state, now in
            self.announce([state.alerts.test(now: now)], &state, now: now)
            // A real hub reports how each delivery went; here every channel that is on works.
            let channels = state.alerts.stored.channels
            return AlertTestResult(ntfy: channels.ntfy.enabled ? .init(ok: true) : nil, webhook: channels.webhook.enabled ? .init(ok: true) : nil)
        }
    }

    public func clearAlertLog() async throws {
        try await request { state, _ in state.alerts.clearLog() }
    }

    public func wake(device id: String) async throws {
        try await request { state, now in
            let index = try Self.index(of: id, in: state)
            let machine = state.machines[index]
            guard machine.spec.mac != nil else {
                throw HubError.http(status: 400, message: "This device hasn't reported a network card address yet.")
            }
            if !machine.isReporting { state.machines[index].wakeAt = now + self.configuration.wakeDelay }
            Self.broadcast(.actionResult(id: id, name: machine.name, result: .init(ok: true, message: "Wake-up signal sent.")), &state)
        }
    }

    public func createBrowserInvitation() async throws -> URL {
        try await request { state, _ in
            state.invitations += 1
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            let code = String((0..<43).map { alphabet[Int(self.model.noise(state.invitations, 9000, Double($0)) * 64) % 64] })
            guard let link = URL(string: self.configuration.origin + "/unlock#join=" + code) else { throw HubError.invalidResponse }
            return link
        }
    }

    public func latestVersion(platform: UpdatePlatform) async throws -> String? {
        try await request { state, _ in state.versions[platform] }
    }

    public func remoteStatus() async throws -> RemoteStatus {
        // What a hub without Tailscale answers.
        try await request { _, _ in RemoteStatus(installed: false, port: 7777, canConfigure: false, platform: "linux") }
    }

    public func mobileClients() async throws -> [MobileClient] {
        try await request { _, now in [MobileClient(id: Self.enrollmentID, name: "iPhone", created: self.model.start, lastSeen: now)] }
    }

    public func unpairSelf() async throws {
        try await request { _, _ in }
        revokeEnrollment()
    }

    public func events() -> AsyncThrowingStream<HubEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<HubEvent, any Error>.makeStream()
        let now = clock.now
        let subscriber: UInt64? = state.withLock { state in
            guard !state.revoked else { return nil }
            state.nextSubscriber += 1
            continuation.yield(.snapshot(state.machines.map { self.view($0, now: now, history: true) }))
            state.subscribers[state.nextSubscriber] = continuation
            if state.driver == nil {
                state.nextReportAt = now + self.configuration.reportInterval
                state.nextStatusAt = now + self.configuration.statusInterval
                state.driver = Task { [weak self, clock] in
                    while !Task.isCancelled {
                        guard let wait = self?.untilNextTick() else { return }
                        do { try await clock.sleep(milliseconds: wait) } catch { return }
                        self?.tick()
                    }
                }
            }
            return state.nextSubscriber
        }
        guard let subscriber else {
            continuation.finish(throwing: Self.refusal)
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: subscriber) }
        }
        return stream
    }

    // MARK: - Requests and the stream

    private static let refusal = HubError.unauthorized(status: 401, message: "Open a fresh dashboard invitation.")

    /// Every operation: the latency, then the hub's state under its lock.
    private func request<T: Sendable>(_ body: @Sendable (inout State, Double) throws -> T) async throws -> T {
        if configuration.latency > 0 {
            do { try await clock.sleep(milliseconds: configuration.latency) } catch { throw HubError.cancelled }
        }
        guard !Task.isCancelled else { throw HubError.cancelled }
        let now = clock.now
        return try state.withLock { state in
            guard !state.revoked else { throw Self.refusal }
            return try body(&state, now)
        }
    }

    private static func index(of id: String, in state: State) throws -> Int {
        guard let index = state.machines.firstIndex(where: { $0.spec.id == id }) else { throw HubError.http(status: 404, message: "not found") }
        return index
    }

    private static func broadcast(_ event: HubEvent, _ state: inout State) {
        for subscriber in state.subscribers.values { subscriber.yield(event) }
    }

    /// `emit` and `test` in alerts.js: each event goes out with everything firing after it.
    private func announce(_ emissions: [DemoAlerts.Emission], _ state: inout State, now: Double) {
        guard !emissions.isEmpty else { return }
        let active = state.alerts.active(subjects(state, now: now))
        for emission in emissions { Self.broadcast(.alert(event: emission.event, notify: emission.notify, active: active), &state) }
    }

    /// Milliseconds until the next report or status is due; nil once nobody is listening, which
    /// is when the timer stops.
    private func untilNextTick() -> Double? {
        let now = clock.now
        return state.withLock { state in
            guard !state.subscribers.isEmpty else {
                state.driver = nil
                return nil
            }
            return max(0, min(state.nextReportAt, state.nextStatusAt) - now)
        }
    }

    private func tick() {
        let now = clock.now
        state.withLock { state in
            if now >= state.nextReportAt {
                state.nextReportAt = now + configuration.reportInterval
                for machine in state.machines where machine.isReporting { report(machine, &state, now: now) }
            }
            if now >= state.nextStatusAt {
                state.nextStatusAt = now + configuration.statusInterval
                for index in state.machines.indices {
                    guard let wakeAt = state.machines[index].wakeAt, wakeAt <= now else { continue }
                    state.machines[index].wakeAt = nil
                    state.machines[index].runs.append(Run(from: now))
                    report(state.machines[index], &state, now: now)
                }
                let everyone = subjects(state, now: now)
                announce(state.alerts.tick(everyone, now: now), &state, now: now)
                // Heartbeat + lets clients notice devices that went offline.
                Self.broadcast(.status(Dictionary(everyone.map { ($0.id, $0.online) }, uniquingKeysWith: { _, last in last })), &state)
            }
        }
    }

    /// One report: `handleReport` in server.js.
    private func report(_ machine: Machine, _ state: inout State, now: Double) {
        let override = machine.spec.id == DemoMachine.gaming && now < state.diskAlertUntil ? ["D:": 0.97] : [:]
        let body = model.report(machine.spec, index: machine.index, name: machine.spec.name, at: now, diskOverride: override)
        // `{ ...reg, online: true, latest: body }`: no history, the sample travels beside it.
        var device = entry(machine, now: now)
        device.lastSeen = now
        device.online = true
        device.latest = body
        Self.broadcast(.report(id: machine.spec.id, device: device, sample: model.rawPoint(machine.spec, index: machine.index, at: now)), &state)
        let subject = DemoAlerts.Subject(id: machine.spec.id, name: machine.name, online: true, lastSeen: now)
        announce(state.alerts.onReport(body, from: subject, now: now), &state, now: now)
    }

    // MARK: - Devices

    /// The time of the last report in a run: reports fall on a two-second grid.
    private static func lastTick(_ now: Double, in run: Run?) -> Double? {
        guard let run else { return nil }
        let end = min(now, run.to ?? .infinity)
        return max(run.from, (end / DemoModel.rawInterval).rounded(.down) * DemoModel.rawInterval)
    }

    private func lastSeen(_ machine: Machine, now: Double) -> Double? {
        Self.lastTick(now, in: machine.runs.last) ?? machine.spec.offFor.map { model.start - $0 }
    }

    private func isOn(_ machine: Machine, at t: Double) -> Bool {
        t < model.start ? model.wasOn(machine.spec, at: t) : machine.runs.contains { $0.from <= t && t <= $0.to ?? .infinity }
    }

    private func subjects(_ state: State, now: Double) -> [DemoAlerts.Subject] {
        state.machines.map { machine in
            let seen = lastSeen(machine, now: now)
            return DemoAlerts.Subject(id: machine.spec.id, name: machine.name, online: seen.map { now - $0 < Self.offlineAfter } ?? false, lastSeen: seen)
        }
    }

    /// The registry entry of a device and whether it is online.
    private func entry(_ machine: Machine, now: Double) -> Device {
        let spec = machine.spec, seen = lastSeen(machine, now: now)
        return Device(
            id: spec.id, name: machine.name, hostname: spec.name, platform: spec.platform, os: spec.os, firstSeen: model.start - model.historySpan,
            lastSeen: seen, order: machine.order, renamed: machine.renamed, hw: .init(formFactor: spec.formFactor, threads: spec.cpu.threads),
            macs: spec.mac.map { [$0] } ?? [], online: seen.map { now - $0 < Self.offlineAfter } ?? false)
    }

    /// `deviceView(id)` in server.js: the entry, the latest report and ten minutes of samples.
    private func view(_ machine: Machine, now: Double, history: Bool) -> Device {
        var device = entry(machine, now: now)
        // A device that has not reported since the hub started has no latest report.
        device.latest = Self.lastTick(now, in: machine.runs.last).map { model.report(machine.spec, index: machine.index, name: machine.spec.name, at: $0) }
        if history { device.history = rawPoints(machine, from: now - Self.liveHistory, to: now, now: now) }
        return device
    }

    /// `str(v, max)` in security.js: no control characters, trimmed, cut to length; nil when
    /// nothing is left.
    private static func cleanText(_ text: String, _ limit: Int) -> String? {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
        var out = JS.trim(String(kept))
        while out.utf16.count > limit { out.unicodeScalars.removeLast() }
        return out.isEmpty ? nil : out
    }

    // MARK: - History

    /// Raw two-second samples: the hub has them for the last hour.
    private func rawPoints(_ machine: Machine, from: Double, to: Double, now: Double) -> [HistoryPoint] {
        let step = DemoModel.rawInterval
        var t = (max(from, now - DemoModel.rawWindow) / step).rounded(.up) * step
        var out: [HistoryPoint] = []
        while t <= min(to, now) {
            if isOn(machine, at: t) { out.append(model.rawPoint(machine.spec, index: machine.index, at: t)) }
            t += step
        }
        return out
    }

    /// `minutePoints(id, from, to)`: stored minute averages, the unfinished minute included.
    private func minutePoints(_ machine: Machine, from: Double, to: Double, now: Double) -> [HistoryPoint] {
        let step = DemoModel.minute
        var t = (max(from, model.start - model.historySpan) / step).rounded(.up) * step
        var out: [HistoryPoint] = []
        while t <= min(to, now) {
            if isOn(machine, at: t) { out.append(model.minutePoint(machine.spec, index: machine.index, at: t)) }
            t += step
        }
        return out
    }

    /// `query(id, from, to, maxPoints)` in history.js.
    private func query(_ machine: Machine, from: Double, to: Double, points: Int, now: Double) -> HistoryResponse {
        // Math.max(10, Math.min(3000, qnum('points') || 1200))
        let limit = Double(max(10, min(3000, points == 0 ? 1200 : points)))
        let width = max(1, max(1, to - from) / limit)
        if width < DemoModel.minute {
            // Fine-grained: raw samples, with minute data filling in before raw starts.
            let raw = rawPoints(machine, from: from, to: to, now: now)
            let rawStart = raw.first?.t ?? .infinity
            let older = minutePoints(machine, from: from, to: min(to, rawStart), now: now).filter { $0.t + DemoModel.minute <= rawStart }
            let fine = width <= DemoModel.rawInterval ? raw : DemoModel.aggregate(raw, width: width, start: from)
            return HistoryResponse(from: from, to: to, resolution: older.isEmpty ? max(DemoModel.rawInterval, width) : DemoModel.minute, points: older + fine)
        }
        let all = minutePoints(machine, from: from, to: to, now: now)
        return HistoryResponse(
            from: from, to: to, resolution: max(DemoModel.minute, width),
            points: width <= DemoModel.minute ? all : DemoModel.aggregate(all, width: width, start: from))
    }

    // MARK: - Energy

    /// `usageSummary(id, bounds)` in server.js.
    private func usage(_ machine: Machine, bounds: [Double], settings: EnergySettings?, now: Double) -> UsageSummary {
        struct Sum {
            var sum = 0.0, n = 0, peak = -Double.infinity
            mutating func add(_ value: Double?, peak top: Double?) {
                guard let value else { return }
                sum += value
                n += 1
                if let top, top > peak { peak = top }
            }
            var stat: UsageSummary.Stat? {
                let tenth = { (v: Double) in (v * 10).rounded() / 10 }
                return n == 0 ? nil : UsageSummary.Stat(avg: tenth(sum / Double(n)), peak: peak == -.infinity ? nil : tenth(peak))
            }
        }
        let from = bounds[0], to = bounds[bounds.count - 1]
        var buckets = [Double](repeating: 0, count: bounds.count - 1), costs = buckets
        var power = Sum(), cpu = Sum(), gpu = Sum(), memory = Sum(), cpuTemp = Sum(), gpuTemp = Sum()
        var b = 0, wh = 0.0, cost = 0.0, minutes = 0
        var first: Double?
        var bytes = UsageSummary.Bytes()
        for p in minutePoints(machine, from: from, to: to, now: now) where p.t >= from && p.t < to {
            while p.t >= bounds[b + 1] { b += 1 }
            minutes += 1
            first = first ?? p.t
            if let watts = p.power {
                buckets[b] += watts / 60
                wh += watts / 60
                power.add(watts, peak: p.powerMax ?? watts)
                let spent = watts / 60 / 1000 * (rate(at: p.t, settings) ?? 0)
                costs[b] += spent
                cost += spent
            }
            cpu.add(p.cpu, peak: p.cpuMax)
            gpu.add(p.gpu, peak: p.gpuMax)
            memory.add(p.mem, peak: p.mem)
            cpuTemp.add(p.cpuTemp, peak: p.cpuTempMax)
            gpuTemp.add(p.gpuTemp, peak: p.gpuTempMax)
            bytes.rx += (p.rx ?? 0) * 60
            bytes.tx += (p.tx ?? 0) * 60
            bytes.dr += (p.dr ?? 0) * 60
            bytes.dw += (p.dw ?? 0) * 60
        }
        let money = { (v: Double) in (v * 1e4).rounded() / 1e4 }
        return UsageSummary(
            id: machine.spec.id, wh: wh.rounded(), buckets: buckets.map { ($0 * 10).rounded() / 10 }, cost: settings == nil ? nil : money(cost),
            costBuckets: settings == nil ? nil : costs.map(money), minutes: minutes, estimatedMinutes: 0,
            stats: .init(power: power.stat, cpu: cpu.stat, gpu: gpu.stat, mem: memory.stat, cpuTemp: cpuTemp.stat, gpuTemp: gpuTemp.stat),
            bytes: .init(rx: bytes.rx.rounded(), tx: bytes.tx.rounded(), dr: bytes.dr.rounded(), dw: bytes.dw.rounded()), firstData: first)
    }

    /// `rateAt(t, e)`: time-of-use periods are in the hub's local time.
    private func rate(at t: Double, _ settings: EnergySettings?) -> Double? {
        guard let settings else { return nil }
        guard settings.isTimeOfUse else { return settings.rate }
        let local = t / 1000 + Double(configuration.timeZone.secondsFromGMT(for: Date(hubTime: t)))
        var seconds = local.truncatingRemainder(dividingBy: 86400)
        if seconds < 0 { seconds += 86400 }
        let hour = (seconds / 60).rounded(.down) / 60
        return settings.tou.first { hour >= $0.from && hour < $0.to }?.rate ?? settings.rate
    }

    /// `validEnergySettings(b)` in server.js.
    static func validated(_ settings: EnergySettings) -> EnergySettings? {
        let capitals = { (text: Substring, count: Int) in text.utf8.count == count && text.utf8.allSatisfy { (65...90).contains($0) } }
        let parts = settings.region.split(separator: "-", omittingEmptySubsequences: false)
        let region = settings.region == "custom" || ((1...2).contains(parts.count) && parts.allSatisfy { capitals($0, 2) })
        let price = { (rate: Double) -> Double? in
            guard rate > 0, rate <= 1000 else { return nil }
            let rounded = (rate * 1e4).rounded() / 1e4
            return rounded == 0 ? nil : rounded
        }
        guard region, let rate = price(settings.rate), capitals(Substring(settings.currency), 3) else { return nil }
        guard settings.tou.count <= 12 else { return nil }
        let hour = { (v: Double) -> Double? in v >= 0 && v <= 24 ? (v * 4).rounded() / 4 : nil }
        var periods: [TouPeriod] = []
        for period in settings.tou {
            guard let from = hour(period.from), let to = hour(period.to), from < to, let rate = price(period.rate) else { return nil }
            periods.append(TouPeriod(from: from, to: to, rate: rate))
        }
        return EnergySettings(region: settings.region, rate: rate, currency: settings.currency, tou: periods.sorted { $0.from < $1.from })
    }
}

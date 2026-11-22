import Foundation
import os
import Testing
@testable import DMCore

/// A hub the test plays by hand: every `events()` call is a connection the test feeds and ends,
/// and every request is answered by a handler the test can replace or hold back.
final class ScriptedHub: HubAPI {
    /// One call of `events()`: one connection attempt.
    final class Connection: Sendable {
        private let continuation: AsyncThrowingStream<HubEvent, any Error>.Continuation
        private let terminated = OSAllocatedUnfairLock(initialState: false)

        init(_ continuation: AsyncThrowingStream<HubEvent, any Error>.Continuation) {
            self.continuation = continuation
            continuation.onTermination = { [terminated] _ in terminated.withLock { $0 = true } }
        }

        /// The consumer let go of the stream, or it was ended.
        var isClosed: Bool { terminated.withLock { $0 } }

        func send(_ event: HubEvent) { continuation.yield(event) }
        func send(_ events: [HubEvent]) { events.forEach(send) }
        /// The hub ends the response.
        func finish() { continuation.finish() }
        func fail(_ error: HubError) { continuation.finish(throwing: error) }
    }

    struct Handlers: Sendable {
        var info: @Sendable () async throws -> HubInfo = { HubInfo(hostname: "scripted", canShare: true, origin: "https://hub.test") }
        var devices: @Sendable () async throws -> [Device] = { [] }
        var rename: @Sendable (String, String) async throws -> Device = { id, name in Device(id: id, name: name, renamed: true) }
        var remove: @Sendable (String) async throws -> Void = { _ in }
        var setOrder: @Sendable ([String]) async throws -> Void = { _ in }
        var history: @Sendable (String, HistoryRange) async throws -> HistoryResponse = { _, _ in HistoryResponse(from: 0, to: 0) }
        var window: @Sendable (String, Double, Double, Int) async throws -> HistoryResponse = { _, from, to, _ in HistoryResponse(from: from, to: to) }
        var energy: @Sendable ([Double]) async throws -> EnergyResponse = { EnergyResponse(bounds: $0) }
        var energySettings: @Sendable () async throws -> EnergySettings? = { nil }
        var saveEnergySettings: @Sendable (EnergySettings) async throws -> EnergySettings = { $0 }
        var alerts: @Sendable () async throws -> AlertsResponse = { AlertsResponse() }
        var saveAlerts: @Sendable (AlertSettings) async throws -> AlertsUpdate = { AlertsUpdate(settings: $0) }
        var testAlert: @Sendable () async throws -> AlertTestResult = { AlertTestResult() }
        var clearAlertLog: @Sendable () async throws -> Void = {}
        var wake: @Sendable (String) async throws -> Void = { _ in }
        var invitation: @Sendable () async throws -> URL = { URL(string: "https://hub.test/unlock#join=" + String(repeating: "c", count: 43))! }
        var latestVersion: @Sendable (UpdatePlatform) async throws -> String? = { _ in nil }
        var remoteStatus: @Sendable () async throws -> RemoteStatus = { RemoteStatus() }
        var mobileClients: @Sendable () async throws -> [MobileClient] = { [] }
        var unpairSelf: @Sendable () async throws -> Void = {}
    }

    private struct State: Sendable {
        var handlers = Handlers()
        var calls: [String] = []
        var connections: [Connection] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Replaces handlers: `hub.on { $0.rename = { _, _ in throw … } }`.
    func on(_ change: @Sendable (inout Handlers) -> Void) {
        state.withLock { change(&$0.handlers) }
    }

    /// Every request so far, as text: "rename ws New name", "history ws 1h 360", …
    var calls: [String] { state.withLock { $0.calls } }
    func calls(_ prefix: String) -> [String] { calls.filter { $0 == prefix || $0.hasPrefix(prefix + " ") } }
    var connections: [Connection] { state.withLock { $0.connections } }

    private func handlers(_ call: String) -> Handlers {
        state.withLock { state in
            state.calls.append(call)
            return state.handlers
        }
    }

    func info() async throws -> HubInfo { try await handlers("info").info() }
    func devices() async throws -> [Device] { try await handlers("devices").devices() }
    func rename(device id: String, name: String) async throws -> Device { try await handlers("rename \(id) \(name)").rename(id, name) }
    func remove(device id: String) async throws { try await handlers("remove \(id)").remove(id) }
    func setOrder(ids: [String]) async throws { try await handlers("order \(ids.joined(separator: ","))").setOrder(ids) }
    func history(device id: String, range: HistoryRange, points: Int) async throws -> HistoryResponse {
        try await handlers("history \(id) \(range.rawValue) \(points)").history(id, range)
    }
    func history(device id: String, from: Double, to: Double, points: Int) async throws -> HistoryResponse {
        try await handlers("window \(id) \(Int(from)) \(Int(to)) \(points)").window(id, from, to, points)
    }
    func energy(bounds: [Double]) async throws -> EnergyResponse {
        try await handlers("energy \(bounds.map { String(Int($0)) }.joined(separator: ","))").energy(bounds)
    }
    func energySettings() async throws -> EnergySettings? { try await handlers("energySettings").energySettings() }
    func saveEnergySettings(_ settings: EnergySettings) async throws -> EnergySettings {
        try await handlers("saveEnergySettings \(settings.region)").saveEnergySettings(settings)
    }
    func alerts() async throws -> AlertsResponse { try await handlers("alerts").alerts() }
    func saveAlerts(_ settings: AlertSettings) async throws -> AlertsUpdate { try await handlers("saveAlerts \(settings.rules.count)").saveAlerts(settings) }
    func testAlert() async throws -> AlertTestResult { try await handlers("testAlert").testAlert() }
    func clearAlertLog() async throws { try await handlers("clearAlertLog").clearAlertLog() }
    func wake(device id: String) async throws { try await handlers("wake \(id)").wake(id) }
    func createBrowserInvitation() async throws -> URL { try await handlers("invitation").invitation() }
    func latestVersion(platform: UpdatePlatform) async throws -> String? { try await handlers("latestVersion \(platform.rawValue)").latestVersion(platform) }
    func remoteStatus() async throws -> RemoteStatus { try await handlers("remoteStatus").remoteStatus() }
    func mobileClients() async throws -> [MobileClient] { try await handlers("mobileClients").mobileClients() }
    func unpairSelf() async throws { try await handlers("unpairSelf").unpairSelf() }

    func events() -> AsyncThrowingStream<HubEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<HubEvent, any Error>.makeStream()
        let connection = Connection(continuation)
        state.withLock { $0.connections.append(connection) }
        return stream
    }
}

/// An answer the test holds back until it says otherwise.
final class Gate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var outcome: Result<Value, any Error>?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
        var arrivals = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many callers have come to wait so far.
    var arrivals: Int { state.withLock { $0.arrivals } }

    func wait() async throws -> Value {
        let id = state.withLock { state in
            state.nextID += 1
            state.arrivals += 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let ready: Result<Value, any Error>? = state.withLock { state in
                    if state.cancelled.contains(id) { return .failure(HubError.cancelled) }
                    if let outcome = state.outcome { return outcome }
                    state.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled.insert(id)
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: HubError.cancelled)
        }
    }

    func open(_ value: Value) { settle(.success(value)) }
    func fail(_ error: HubError) { settle(.failure(error)) }

    private func settle(_ outcome: Result<Value, any Error>) {
        let waiters = state.withLock { state in
            state.outcome = outcome
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume(with: outcome) }
    }
}

/// Collects what a store hands its notifier.
@MainActor
final class NotifierProbe: AlertNotifier {
    private(set) var events: [AlertEvent] = []
    func notify(_ event: AlertEvent) { events.append(event) }
}

struct TimedOut: Error {}

/// Holds an object without keeping it alive, to see it go.
final class WeakReference<Object: AnyObject> {
    private(set) weak var object: Object?

    init(_ object: Object?) {
        self.object = object
    }
}

/// The `HubError` a store action throws, nil when it does not throw.
@MainActor
func storeError(_ operation: @MainActor () async throws -> Void) async -> HubError? {
    do {
        try await operation()
        return nil
    } catch let error as HubError {
        return error
    } catch {
        Issue.record("a store action threw something that is not a HubError: \(error)")
        return nil
    }
}

/// Waits until `condition` holds. The store works across a few hops between the main actor and
/// wherever the hub answers, so its tests wait for outcomes rather than count turns.
@MainActor
func eventually(
    _ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting until \(what)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// Lets everything that is ready to run do so. Only for showing that nothing happens.
@MainActor
func settle() async {
    for _ in 0..<5 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(4))
    }
}

enum StoreFixtures {
    /// A time after everything in the captured fixtures.
    static let now: Double = 1_795_214_000_000

    /// A fresh, empty defaults suite for one test.
    @MainActor
    static func preferences() -> (Preferences, UserDefaults) {
        let name = "dm-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (Preferences(defaults: defaults), defaults)
    }

    static func device(_ id: String, name: String? = nil, order: Int? = nil, online: Bool = true, history: [HistoryPoint] = [], platform: String? = nil, appVersion: String? = nil) -> Device {
        Device(
            id: id, name: name ?? id, platform: platform, order: order, online: online,
            latest: appVersion.map { Report(appVersion: $0) }, history: history)
    }

    static func point(_ t: Double, cpu: Double = 10, gpu: Double? = nil) -> HistoryPoint {
        HistoryPoint(t: t, cpu: cpu, gpu: gpu, mem: 50)
    }

    static func alert(_ id: String, t: Double, device: String = "a", firing: Bool = true, test: Bool = false) -> AlertEvent {
        AlertEvent(id: id, t: t, ruleId: test ? nil : "0123456789ab", type: test ? nil : .cpu, device: test ? nil : device, state: firing ? .firing : .resolved, title: "Alert \(id)", test: test)
    }

    static func refused(_ status: Int, _ message: String = "no") -> HubError {
        status == 401 ? .unauthorized(status: 401, message: message) : .http(status: status, message: message)
    }
}

/// A store over a scripted hub and a hand-moved clock.
@MainActor
struct StoreHarness {
    let hub = ScriptedHub()
    let clock = ManualHubClock(now: StoreFixtures.now)
    let preferences: Preferences
    let defaults: UserDefaults
    let notifier = NotifierProbe()
    let store: HubStore

    init() {
        (preferences, defaults) = StoreFixtures.preferences()
        store = HubStore(api: hub, preferences: preferences, clock: clock, alertNotifier: notifier, locale: Locale(identifier: "en_US"))
    }

    /// The `n`th connection the store opened, once it has.
    func connection(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ScriptedHub.Connection {
        try await eventually("connection \(index) is opened", sourceLocation: sourceLocation) { hub.connections.count > index }
        return hub.connections[index]
    }

    /// Starts the store and takes it live with `devices`.
    @discardableResult
    func goLive(_ devices: [Device] = [StoreFixtures.device("a", order: 0), StoreFixtures.device("b", order: 1)]) async throws -> ScriptedHub.Connection {
        store.start()
        let connection = try await connection(hub.connections.count)
        connection.send(.snapshot(devices))
        try await eventually("the store is live") { store.connection == .live && store.hasSnapshot }
        try await idle()
        return connection
    }

    /// Waits until the store has no request in flight: only its stream loop and its timer remain.
    func idle(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await eventually("the store has nothing in flight", sourceLocation: sourceLocation) { store.activeTaskCount <= 2 }
    }
}

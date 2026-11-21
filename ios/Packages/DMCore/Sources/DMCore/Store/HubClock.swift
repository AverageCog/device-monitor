import Foundation
import os

/// The time source of everything in the store and the demo hub that waits or stamps: the
/// reconnect delay, the series refresh, the demo's report timer. Injected so tests and previews
/// can hold time still or move it by hand.
public protocol HubClock: Sendable {
    /// Milliseconds since 1970, as `Date.now()` in JavaScript.
    var now: Double { get }
    /// Suspends for `milliseconds` of this clock's time. Throws `CancellationError` when the task
    /// is cancelled first.
    func sleep(milliseconds: Double) async throws
}

/// The device's own clock.
public struct SystemHubClock: HubClock {
    public init() {}

    public var now: Double { Date().hubTime }

    public func sleep(milliseconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
    }
}

/// A clock that only moves when told to. Sleepers wake when `advance` carries the time past
/// their deadline, in deadline order.
///
/// ```swift
/// let clock = ManualHubClock(now: 1_800_000_000_000)
/// store.start()
/// await clock.waitForSleepers()        // something is waiting on the clock
/// clock.advance(by: 3000)              // …and is released
/// ```
public final class ManualHubClock: HubClock {
    private struct Sleeper: Sendable {
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Watcher: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now: Double
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        /// Sleeps whose task was cancelled before they got as far as waiting.
        var cancelled: Set<UInt64> = []
        var watchers: [Watcher] = []

        mutating func satisfiedWatchers() -> [CheckedContinuation<Void, Never>] {
            let ready = watchers.filter { sleepers.count >= $0.count }
            watchers.removeAll { sleepers.count >= $0.count }
            return ready.map(\.continuation)
        }
    }

    private enum Entry {
        case wait([CheckedContinuation<Void, Never>])
        case finish
        case cancel
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(now: Double = Date().hubTime) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    public var now: Double { state.withLock { $0.now } }

    /// How many tasks are waiting on this clock right now.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(milliseconds: Double) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let entry: Entry = state.withLock { state in
                    if state.cancelled.contains(id) { return .cancel }
                    guard milliseconds > 0 else { return .finish }
                    state.sleepers[id] = Sleeper(deadline: state.now + milliseconds, continuation: continuation)
                    return .wait(state.satisfiedWatchers())
                }
                switch entry {
                case .wait(let watchers): watchers.forEach { $0.resume() }
                case .finish: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                state.cancelled.insert(id)
                return state.sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the time forward and wakes every sleeper whose deadline has come.
    public func advance(by milliseconds: Double) {
        let due = state.withLock { state in
            state.now += max(0, milliseconds)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
                .sorted { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }
            for (id, _) in due { state.sleepers[id] = nil }
            return due.map(\.value.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Returns once at least `count` tasks are waiting on this clock.
    public func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.sleepers.count >= count { return true }
                state.watchers.append(Watcher(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

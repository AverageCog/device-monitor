import Foundation
import os
import Testing
@testable import DMCore

@Suite(.timeLimit(.minutes(1))) struct HubClockTests {
    @Test func aManualClockOnlyMovesWhenTold() async {
        let clock = ManualHubClock(now: 1000)
        #expect(clock.now == 1000 && clock.sleeperCount == 0)
        clock.advance(by: 250)
        clock.advance(by: -40)                                    // time does not run backwards
        #expect(clock.now == 1250)
    }

    @Test func sleepersWakeInDeadlineOrderOnceTheirTimeHasCome() async {
        let clock = ManualHubClock(now: 0)
        let order = OSAllocatedUnfairLock(initialState: [Int]())
        let woken = { order.withLock { $0 } }
        let sleepers = [300.0, 100, 200].map { delay in
            Task {
                try? await clock.sleep(milliseconds: delay)
                order.withLock { $0.append(Int(delay)) }
            }
        }
        await clock.waitForSleepers(3)
        clock.advance(by: 99)
        #expect(clock.sleeperCount == 3)
        clock.advance(by: 1)                                      // exactly on the first deadline
        await sleepers[1].value
        #expect(woken() == [100] && clock.sleeperCount == 2)
        clock.advance(by: 500)
        for sleeper in sleepers { await sleeper.value }
        #expect(woken().sorted() == [100, 200, 300] && clock.sleeperCount == 0)
    }

    @Test func aSleepOfNothingReturnsAtOnce() async throws {
        let clock = ManualHubClock(now: 0)
        try await clock.sleep(milliseconds: 0)
        try await clock.sleep(milliseconds: -5)
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellingASleeperThrowsAndForgetsIt() async {
        let clock = ManualHubClock(now: 0)
        let sleeper = Task { () -> Bool in
            do {
                try await clock.sleep(milliseconds: 1000)
                return false
            } catch {
                return error is CancellationError
            }
        }
        await clock.waitForSleepers()
        sleeper.cancel()
        #expect(await sleeper.value)
        #expect(clock.sleeperCount == 0)

        // Cancelled before it ever got to wait.
        let early = Task { () -> Bool in
            await Task.yield()
            do {
                try await clock.sleep(milliseconds: 1000)
                return false
            } catch {
                return true
            }
        }
        early.cancel()
        #expect(await early.value)
        #expect(clock.sleeperCount == 0)
    }

    @Test func theSystemClockIsTheDevicesTime() async throws {
        let clock = SystemHubClock()
        #expect(abs(clock.now - Date().hubTime) < 2000)
        let started = ContinuousClock.now
        try await clock.sleep(milliseconds: 30)
        #expect(ContinuousClock.now - started >= .milliseconds(25))
        let cancelled = Task { try await clock.sleep(milliseconds: 60_000) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}

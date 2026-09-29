import Foundation
import SpottyTestSupport
import Testing

@Suite("Harness synchronization")
@MainActor
struct HarnessSynchronizationTests {
    @Test(arguments: [HarnessClock.SleepBehavior.immediate, .parked, .scheduled], [0.0, 10.0])
    func cancelledClockCannotCompleteACooperativeSleep(behavior: HarnessClock.SleepBehavior, seconds: Double)
        async throws
    {
        let clock = HarnessClock(sleep: behavior)
        defer { clock.releaseAll() }
        let task = Task { try await clock.sleep(seconds: seconds) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.waiterCount == 0)
    }

    @Test
    func scheduledClockWakesOnlyDueSleepers() async throws {
        let clock = HarnessClock.scheduled()
        defer { clock.releaseAll() }
        let later = Task { try await clock.sleep(seconds: 10) }
        defer { later.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        let sooner = Task { try await clock.sleep(seconds: 4) }
        defer { sooner.cancel() }
        try await requireEventually { clock.waiterCount == 2 }
        clock.advance(seconds: 3)
        #expect(clock.waiterCount == 2)
        clock.advance(seconds: 1)
        #expect(clock.waiterCount == 1)
        try await sooner.value
        #expect(clock.now() == HarnessDates.fixed.addingTimeInterval(4))
        clock.advance(seconds: 6)
        #expect(clock.waiterCount == 0)
        try await later.value
    }

    @Test
    func newSleepUsesItsOwnStartTimeAndZeroDurationDoesNotPark() async throws {
        let clock = HarnessClock.scheduled()
        defer { clock.releaseAll() }
        try await clock.sleep(seconds: 0)
        clock.advance(seconds: 5)
        let task = Task { try await clock.sleep(seconds: 4) }
        defer { task.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        clock.set(now: HarnessDates.fixed.addingTimeInterval(8))
        #expect(clock.waiterCount == 1)
        clock.set(now: HarnessDates.fixed.addingTimeInterval(9))
        try await task.value
        #expect(clock.waiterCount == 0)
    }

    @Test(arguments: [HarnessClock.SleepBehavior.parked, .scheduled])
    func cancellingParkedClockRemovesItsWaiter(behavior: HarnessClock.SleepBehavior)
        async throws
    {
        let clock = HarnessClock(sleep: behavior)
        defer { clock.releaseAll() }
        let parked = Task { try await clock.sleep(seconds: 10) }
        defer { parked.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        parked.cancel()
        await #expect(throws: CancellationError.self) { try await parked.value }
        #expect(clock.waiterCount == 0)
    }

    @Test
    func responseGateRetainsEarlyRepliesAndResolvesWaitersInOrder() async throws {
        let gate = HarnessResponseGate<Int>()
        defer { gate.close() }
        gate.finish(1)
        gate.finish(2)
        #expect(try await gate.wait() == 1)
        #expect(try await gate.wait() == 2)
        let first = Task { try await gate.wait() }
        defer { first.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        let second = Task { try await gate.wait() }
        defer { second.cancel() }
        try await requireEventually { gate.waiterCount == 2 }
        gate.finish(3)
        gate.finish(4)
        #expect(try await first.value == 3)
        #expect(try await second.value == 4)
        #expect(gate.requestCount == 4)
    }

    @Test
    func gateCancellationDoesNotConsumeAnEarlyReplyOrAnotherWaiter() async throws {
        let gate = HarnessResponseGate<Int>()
        defer { gate.close() }
        gate.finish(1)
        let early = Task { try await gate.wait() }
        early.cancel()
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(try await gate.wait() == 1)
        let cancelled = Task { try await gate.wait() }
        defer { cancelled.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        let survivor = Task { try await gate.wait() }
        defer { survivor.cancel() }
        try await requireEventually { gate.waiterCount == 2 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(gate.waiterCount == 1)
        gate.finish(2)
        #expect(try await survivor.value == 2)
    }

    @Test(arguments: [HarnessResponseGate<Int>.Cancellation.cooperative, .ignored])
    func closingGateReleasesCurrentAndFutureCalls(cancellation: HarnessResponseGate<Int>.Cancellation) async throws {
        let gate = HarnessResponseGate<Int>(cancellation: cancellation)
        defer { gate.close() }
        let task = Task { try await gate.wait() }
        defer { task.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        gate.close()
        gate.close()
        gate.finish(99)
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await gate.wait() }
        #expect(gate.waiterCount == 0)
    }

    @Test
    func ignoredCancellationAllowsALateResponse() async throws {
        let gate = HarnessResponseGate<Int>(cancellation: .ignored)
        defer { gate.close() }
        let task = Task { try await gate.wait() }
        defer { task.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        task.cancel()
        #expect(gate.waiterCount == 1)
        gate.finish(42)
        #expect(try await task.value == 42)
    }
}

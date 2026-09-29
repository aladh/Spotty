import SpottyTestSupport
import Testing

@MainActor
struct HarnessSuspensionTests {
    @Test func rearmingReleasesEarlierWorkAndPreservesTheNewWaiter() async throws {
        let suspension = HarnessSuspension()
        let completed = HarnessCounters()
        defer { suspension.close() }
        suspension.arm()
        let earlier = Task {
            await suspension.waitIfArmed(); completed.record("earlier")
        }
        defer { earlier.cancel() }
        try await requireEventually { suspension.isWaiting }
        suspension.arm()
        let newer = Task {
            await suspension.waitIfArmed(); completed.record("newer")
        }
        defer { newer.cancel() }
        try await requireEventually { suspension.isWaiting }
        try await requireEventually { completed.count("earlier") == 1 }
        await earlier.value
        #expect(suspension.isWaiting)
        // Only one upcoming call was armed; a second call cannot steal that suspension.
        let unarmed = Task {
            await suspension.waitIfArmed(); completed.record("unarmed")
        }
        defer { unarmed.cancel() }
        try await requireEventually { completed.count("unarmed") == 1 }
        await unarmed.value
        #expect(suspension.isWaiting)
        suspension.resume()
        suspension.resume()
        try await requireEventually { completed.count("newer") == 1 }
        await newer.value
        #expect(suspension.isWaiting == false)
    }

    @Test(arguments: [false, true])
    func closeReleasesWorkAndPreventsLateArming(entered: Bool) async throws {
        let suspension = HarnessSuspension()
        let completed = HarnessCounters()
        defer { suspension.close() }
        suspension.arm()
        var work: Task<Void, Never>?
        defer { work?.cancel() }
        if entered {
            work = Task {
                await suspension.waitIfArmed(); completed.record("work")
            }
            try await requireEventually { suspension.isWaiting }
        }
        suspension.close()
        if entered { try await requireEventually { completed.count("work") == 1 } }
        await work?.value
        suspension.arm()
        let late = Task {
            await suspension.waitIfArmed(); completed.record("late")
        }
        defer { late.cancel() }
        try await requireEventually { completed.count("late") == 1 }
        await late.value
        #expect(suspension.isWaiting == false)
    }

    @Test func cancellationDoesNotConsumeTheNextArming() async throws {
        let suspension = HarnessSuspension()
        let completed = HarnessCounters()
        defer { suspension.close() }
        suspension.arm()
        let cancelled = Task {
            await suspension.waitIfArmed(); completed.record("cancelled")
        }
        cancelled.cancel()
        try await requireEventually { completed.count("cancelled") == 1 }
        await cancelled.value
        #expect(suspension.isWaiting == false)
        suspension.arm()
        let next = Task {
            await suspension.waitIfArmed(); completed.record("next")
        }
        defer { next.cancel() }
        try await requireEventually { suspension.isWaiting }
        suspension.resume()
        try await requireEventually { completed.count("next") == 1 }
        await next.value
    }
}

import Testing
@testable import SpottyCore

@Suite("App termination")
@MainActor
struct AppTerminationTests {
    @Test
    func quitWaitsForCleanupAndCoalescesRepeatedRequests() async {
        let deadline = HarnessClock.parked()
        let cleanup = HarnessClock.parked()
        defer {
            deadline.releaseAll()
            cleanup.releaseAll()
        }
        let termination = AppTermination(clock: deadline)
        var shutdowns = 0
        var replies = 0
        termination.begin {
            shutdowns += 1
            try? await cleanup.sleep(seconds: 1)
        } completion: {
            replies += 1
        }
        termination.begin {
            Issue.record("repeated quit must not start another shutdown")
        } completion: {
            Issue.record("repeated quit must not replace the original reply")
        }
        await expectEventually { cleanup.waiterCount == 1 && deadline.waiterCount == 1 }

        #expect(termination.hasBegun)
        #expect(shutdowns == 1)
        #expect(replies == 0, "AppKit must wait for the final playback publication")
        #expect(deadline.requestedSleeps.count == 1)
        #expect(
            (deadline.requestedSleeps.first ?? 0) > 8.25,
            "the quit budget must cover both four-second engine drains and the 250ms effect drain")

        cleanup.releaseAll()
        await expectEventually { replies == 1 && deadline.waiterCount == 0 }
        #expect(shutdowns == 1)
    }

    @Test
    func deadlineStillQuitsAndLateCleanupCannotReplyAgain() async {
        let deadline = HarnessClock.parked()
        let cleanup = HarnessClock(sleep: .uncooperativelyParked)
        defer {
            deadline.releaseAll()
            cleanup.releaseAll()
        }
        let termination = AppTermination(clock: deadline)
        var replies = 0
        var cleanupFinished = false
        termination.begin {
            try? await cleanup.sleep(seconds: 1)
            cleanupFinished = true
        } completion: {
            replies += 1
        }
        await expectEventually { cleanup.waiterCount == 1 && deadline.waiterCount == 1 }
        #expect(
            (deadline.requestedSleeps.first ?? .infinity) <= 10,
            "a stalled cleanup must retain a bounded quit deadline")

        deadline.releaseAll()
        await expectEventually { replies == 1 }
        #expect(!cleanupFinished)
        cleanup.releaseAll()
        await expectEventually { cleanupFinished }
        #expect(replies == 1)
    }
}

@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("App termination")
@MainActor
struct AppTerminationTests {
    @Test
    func quitWaitsForSubmittedPreferences() async throws {
        let write = HarnessSuspension()
        defer { write.close() }
        write.arm()
        let preferences = HarnessPreferences(beforeHistoryWrite: { _ in
            await write.waitIfArmed()
        })
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, preferences: preferences))
        player.recordPlayed("spotify:track:last-played")
        try await requireEventually { write.isWaiting }
        let runtime = player.runtime
        let shutdown = Task { @SessionRuntimeActor in
            await runtime.shutdownForTermination()
            return preferences.storedHistory
        }
        defer { shutdown.cancel() }
        // This check samples storage inside the shutdown task: resuming persistence after
        // termination has already returned must not conceal the missing shutdown barrier.
        try await requireEventually { engine.count(.cleanup) > 0 }
        write.resume()
        #expect(await shutdown.value["spotify:track:last-played"] != nil)
    }

    @Test
    func quitDuringLogoutWaitsForGrantRemovalAndStopsSubscriptions() async throws {
        let engine = HarnessEngine(events: .live)
        let account = HarnessAccount(hasGrant: true, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        account.parkClear = true
        defer { account.completeClear() }
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, account: account, lifecycle: lifecycle))
        await player.restore()
        let logout = Task { await player.logout() }
        try await requireEventually { account.isClearParked }

        let runtime = player.runtime
        let shutdown = Task { @SessionRuntimeActor in
            await runtime.shutdownForTermination()
            // Sample on the shutdown executor before any other task can finish logout.
            return account.clearCount
        }
        try await requireEventually {
            SessionRuntimeActor.sync { runtime.lifecycle.isTerminating }
        }
        let repeatedEntered = HarnessCounters()
        let repeatedShutdown = Task { @SessionRuntimeActor in
            repeatedEntered.record("entered")
            await runtime.shutdownForTermination()
            return account.clearCount
        }
        try await requireEventually {
            SessionRuntimeActor.sync { repeatedEntered.count("entered") == 1 }
        }
        account.completeClear()
        #expect(await shutdown.value == 1, "Quit must wait for the in-progress durable logout")
        #expect(await repeatedShutdown.value == 1, "Every quit caller must join durable cleanup")
        await logout.value
        player.connect()
        #expect(player.isTearingDown, "Completing logout during quit cannot reopen the session")
        #expect(!player.allowsCommands)
        await expectEventually {
            engine.activeEventSubscriptionCount == 0 && account.activeSubscriptionCount == 0
                && lifecycle.activeSubscriptionCount == 0
        }
        #expect(engine.count(.shutdown) == 1, "Quit joins logout's engine shutdown")
        #expect(engine.count(.cleanup) == 1)
    }

    @Test
    func terminationBeforeRestoreCannotStartProcessSubscriptions() async {
        let engine = HarnessEngine(events: .live)
        let account = HarnessAccount(hasGrant: true, revocations: .live)
        let events = HarnessLifecycleEvents(.live)
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, account: account, lifecycle: events))
        await player.shutdownForTermination()
        let runtime = player.runtime
        await expectEventually { SessionRuntimeActor.sync { runtime.presentationSubscribers.isEmpty } }
        await player.restore()
        #expect(SessionRuntimeActor.sync { runtime.presentationSubscribers.isEmpty })
        player.connect()
        player.reauthorize()
        #expect(engine.activeEventSubscriptionCount == 0)
        #expect(account.activeSubscriptionCount == 0)
        #expect(events.activeSubscriptionCount == 0)
        #expect(engine.count(.initialize) == 0)
        #expect(!player.allowsCommands)
    }

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
    func deadlineStillQuitsAndLateCleanupCannotReplyAgain() async throws {
        let deadline = HarnessClock.scheduled()
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
        try await requireEventually { cleanup.waiterCount == 1 && deadline.waiterCount == 1 }
        #expect(
            (deadline.requestedSleeps.first ?? .infinity) <= 10,
            "a stalled cleanup must retain a bounded quit deadline")

        deadline.advance(seconds: 9)
        #expect(deadline.waiterCount == 1)
        #expect(replies == 0)
        deadline.advance(seconds: 1)
        await expectEventually { replies == 1 }
        #expect(!cleanupFinished)
        cleanup.releaseAll()
        await expectEventually { cleanupFinished }
        #expect(replies == 1)
    }
}

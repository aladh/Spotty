import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

@MainActor
struct SessionCommandRolloverTests {
    @Test func repeatedRolloverRestoresAdmissionWithoutReplayingAnOldWrite() async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine: engine)
        let initial = await runtime.snapshot()
        let original = SessionCommand(sessionID: initial.sessionID, action: .playURI("spotify:track:original"))
        _ = await runtime.submit(original)
        let intentID = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[original.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intentID)) }
        await settlement?.wait()
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing, trackURI: "spotify:track:original",
                        timing: PlaybackTiming(duration: 180, anchoredAt: HarnessDates.fixed))),
                source: .enginePlayback, revision: 1)
        }
        #expect(await runtime.submit(original).disposition == .observedConfirmed)
        let playback = await runtime.snapshot()

        // Exercise real admission past the old lifetime limit twice, without replacing an account.
        var previous = playback
        for cycle in 0..<2 {
            let count = serviceCommandLedgerLimit - (cycle == 0 ? 1 : 0)
            for _ in 0..<count {
                let receipt = await runtime.submit(
                    SessionCommand(sessionID: previous.sessionID, action: .cancelQueueRefresh))
                #expect(receipt.disposition == .observedConfirmed)
            }
            let renewed = await runtime.snapshot()
            #expect(renewed.sessionID != previous.sessionID)
            #expect(renewed.accountEpoch == initial.accountEpoch)
            #expect(renewed.phase == playback.phase)
            #expect(renewed.owner == playback.owner)
            #expect(renewed.queue == playback.queue)
            #expect(renewed.presentation == playback.presentation)
            #expect(renewed.capabilities.contains(.play))
            #expect(renewed.receipts.count <= 128)
            #expect(SessionRuntimeActor.sync { runtime.serviceCommandLedger.isEmpty })
            #expect(await runtime.submit(original).disposition == .rejected)
            #expect(engine.operations.count == 1)
            previous = renewed
        }

        let fresh = SessionCommand(sessionID: previous.sessionID, action: .playURI("spotify:track:fresh"))
        #expect(await runtime.submit(fresh).disposition == .admitted)
        let freshIntent = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[fresh.id]?.first })
        let freshSettlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(freshIntent)) }
        await freshSettlement?.wait()
        #expect(engine.operations.count == 2)
        #expect(await runtime.submit(original).disposition == .rejected)
        #expect(engine.operations.count == 2)
        await runtime.shutdownForTermination()
    }

    @Test func pendingWorkDefersRolloverAndUnknownWorkCannotPolluteTheNewNamespace() async throws {
        let clock = CooperativeParkedClock()
        let gate = HarnessEngineGate(result: .ok)
        defer { gate.finish(with: .ok) }
        let engine = HarnessEngine()
        engine.onExecute = { [gate] _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        let initial = await runtime.snapshot()
        seedTerminalLedger(runtime, count: serviceCommandLedgerLimit - 1)
        let original = SessionCommand(sessionID: initial.sessionID, action: .playURI("spotify:track:uncertain"))
        _ = await runtime.submit(original)
        await expectEventually { gate.enteredCount == 1 && clock.waiterCount >= 2 }
        let intentID = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[original.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intentID)) }
        #expect((await runtime.snapshot()).sessionID == initial.sessionID)
        #expect(!(await runtime.snapshot()).capabilities.contains(.play))
        #expect(
            await runtime.submit(SessionCommand(sessionID: initial.sessionID, action: .next)).disposition == .rejected)
        #expect(SessionRuntimeActor.sync { runtime.serviceCommandLedger.count } == serviceCommandLedgerLimit)

        // Timeouts end observation, but the synthetic blocking worker cannot finish yet.
        // Rollover must preserve that uncertainty without waiting forever or dispatching it again.
        clock.releaseAll()
        await expectEventually {
            let snapshot = await runtime.snapshot()
            return snapshot.sessionID != initial.sessionID && snapshot.capabilities.contains(.queueRefresh)
        }
        let renewed = await runtime.snapshot()
        let unknown = try #require(
            renewed.receipts.first { $0.commandID == original.id && $0.sessionID == original.sessionID })
        #expect(unknown.disposition == .unknown)
        #expect(renewed.accountEpoch == initial.accountEpoch)
        #expect(await runtime.submit(original).disposition == .rejected)
        #expect(gate.enteredCount == 1)

        // UUIDs are scoped by the immutable command session. A late old result cannot replace
        // the new receipt, and keeping the old unknown receipt must not hide the new one.
        let reused = SessionCommand(id: original.id, sessionID: renewed.sessionID, action: .cancelQueueRefresh)
        let current = await runtime.submit(reused)
        #expect(current.disposition == .observedConfirmed)
        gate.finish(with: .ok)
        await settlement?.wait()
        #expect(await runtime.submit(reused) == current)
        #expect(engine.operations.count == 1)
        let afterLateResult = await runtime.snapshot()
        #expect(afterLateResult.receipts.contains(unknown))
        #expect(afterLateResult.receipts.contains(current))

        await runtime.logout()
        let signedOut = await runtime.snapshot()
        #expect(signedOut.accountEpoch > initial.accountEpoch)
        #expect(signedOut.receipts.isEmpty, "real account retirement still clears retained receipt payloads")
    }

    @Test func refusedLogoutCannotConsumeTheReservedRetirementSlot() async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine: engine)
        let initial = await runtime.snapshot()
        seedTerminalLedger(runtime, count: serviceCommandLedgerLimit - 1)
        let pending = SessionCommand(sessionID: initial.sessionID, action: .playURI("spotify:track:pending"))
        _ = await runtime.submit(pending)
        let intentID = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[pending.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intentID)) }
        await settlement?.wait()
        #expect(await runtime.submit(pending).disposition == .sent)

        let staleLogout = SessionCommand(
            sessionID: initial.sessionID, expectedRouteRevision: initial.routeRevision &+ 1, action: .logout)
        #expect(await runtime.submit(staleLogout).disposition == .rejected)
        #expect(SessionRuntimeActor.sync { runtime.serviceCommandLedger.count } == serviceCommandLedgerLimit)
        let logout = await runtime.submit(SessionCommand(sessionID: initial.sessionID, action: .logout))
        #expect(logout.disposition == .observedConfirmed)
        let signedOut = await runtime.snapshot()
        #expect(signedOut.phase == .signedOut)
        #expect(signedOut.accountEpoch > initial.accountEpoch)
        #expect(signedOut.receipts.isEmpty)
    }

    private func makeRuntime(
        engine: HarnessEngine, clock: any PlaybackClock = HarnessClock.sticky()
    ) -> PlaybackSessionRuntime {
        let environment = HarnessEnvironment.make(engine: engine, clock: clock)
        return SessionRuntimeActor.sync {
            let runtime = PlaybackSessionRuntime(environment: environment)
            _ = runtime.send(.session(.ready), source: .account)
            _ = runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                        localDeviceID: "mac", revision: 1)),
                source: .engineDevices, revision: 1)
            return runtime
        }
    }

    private func seedTerminalLedger(_ runtime: PlaybackSessionRuntime, count: Int) {
        SessionRuntimeActor.sync {
            for _ in 0..<count {
                let id = UUID()
                runtime.serviceCommandLedger[id] = SessionCommandReceipt(
                    commandID: id, sessionID: runtime.sessionID, disposition: .observedConfirmed)
            }
        }
    }
}

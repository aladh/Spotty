import Foundation
import SpottyDomain
import Testing
@testable import SpottySessionRuntime

/// Advance the diagnostic history through real admissions without starting unrelated I/O.
@SessionRuntimeActor
func fillPlaybackIntentHistory(_ runtime: PlaybackSessionRuntime) {
    for _ in 0..<128 {
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
        #expect(
            runtime.send(.queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command)
        )
        #expect(runtime.send(.queueIntentFinished(id: command.id, accepted: false), source: .command))
    }
}

@MainActor
struct PlaybackIntentRetentionTests {
    @Test
    func expiryKeepsAnUnconsumedDispatchReceiptAfterHistoryPruning() async throws {
        let clock = HarnessClock.parked()
        let gate = HarnessEngineGate(result: .ok)
        let engine = HarnessEngine()
        engine.onExecute = { _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        let completions = RuntimeCallbackRecorder<Bool>()
        defer {
            SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
            gate.release()
            clock.releaseAll()
        }
        let id = try #require(
            SessionRuntimeActor.sync {
                runtime.performCommand("Could not pause", expecting: false, operation: .pause) {
                    completions.append($0)
                }
                let id = runtime.state.pendingCommands[.transport]?.id
                fillPlaybackIntentHistory(runtime)
                return id
            })
        let deadline = try #require(SessionRuntimeActor.sync { runtime.effects.settlement(of: .commandDeadline(id)) })
        let worker = try #require(SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(id)) })
        try await requireEventually { gate.hasStarted && clock.waiterCount == 1 }
        #expect(SessionRuntimeActor.sync { runtime.state.intents.first { $0.command.id == id }?.dispatchedAt } == nil)
        clock.releaseAll()
        await deadline.wait()
        #expect(
            SessionRuntimeActor.sync { runtime.state.notice?.message }
                == "Spotify has not confirmed this request. Its result is unknown.")
        #expect(SessionRuntimeActor.sync { runtime.state.intents.count } == 128)
        #expect(SessionRuntimeActor.sync { !runtime.state.intents.contains { $0.command.id == id } })
        #expect(completions.snapshot == [false])
        gate.release()
        await worker.wait()
        await runtime.shutdownForTermination()
    }

    @Test
    func queueExpiryKeepsDispatchClassificationAndStopsTheUnsentRemainder() async throws {
        let clock = HarnessClock.parked()
        let gate = HarnessEngineGate(result: .ok)
        let engine = HarnessEngine()
        engine.onExecute = { _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        defer {
            SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
            gate.release()
            clock.releaseAll()
        }
        SessionRuntimeActor.sync { runtime.addToQueue(uris: ["spotify:track:first", "spotify:track:unsent"]) }
        try await requireEventually { gate.hasStarted && clock.waiterCount == 1 }
        let id = try #require(SessionRuntimeActor.sync { runtime.state.intents.last?.command.id })
        let deadline = try #require(SessionRuntimeActor.sync { runtime.effects.settlement(of: .commandDeadline(id)) })
        let worker = try #require(queueWorker(runtime))
        SessionRuntimeActor.sync { fillPlaybackIntentHistory(runtime) }
        clock.releaseAll()
        await deadline.wait()
        #expect(
            SessionRuntimeActor.sync { runtime.feedback.message?.text }
                == "Spotify has not confirmed the queue request. Its result is unknown. The remaining queue request was not sent."
        )
        #expect(SessionRuntimeActor.sync { !runtime.state.intents.contains { $0.command.id == id } })
        gate.release()
        await worker.wait()
        #expect(engine.executeCount == 1)
        await runtime.shutdownForTermination()
    }

    @Test(arguments: [false, true])
    func prunedQueueRejectionStillReportsFailureAndReconnectsWhenRequired(reconnect: Bool) async throws {
        let clock = HarnessClock.parked()
        let gate = HarnessEngineGate(result: reconnect ? .init(rawValue: -2) : .error)
        let engine = HarnessEngine()
        engine.onExecute = { _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        defer {
            SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
            gate.release()
            clock.releaseAll()
        }
        SessionRuntimeActor.sync { runtime.addToQueue(uris: ["spotify:track:rejected"]) }
        try await requireEventually { gate.hasStarted }
        let id = try #require(SessionRuntimeActor.sync { runtime.state.intents.last?.command.id })
        let worker = try #require(queueWorker(runtime))
        SessionRuntimeActor.sync { fillPlaybackIntentHistory(runtime) }
        gate.release()
        await worker.wait()
        let recovery = SessionRuntimeActor.sync { runtime.effects.settlement(of: .engineRecovery) }
        await recovery?.wait()
        #expect(
            SessionRuntimeActor.sync { runtime.feedback.message?.text } == "Could not add that track to the queue.")
        #expect(engine.forceReconnectCount == (reconnect ? 1 : 0))
        #expect(SessionRuntimeActor.sync { !runtime.state.intents.contains { $0.command.id == id } })
        await runtime.shutdownForTermination()
    }

    @Test
    func prunedQueueSupersessionIgnoresALateReconnectFailure() async throws {
        let clock = HarnessClock.parked()
        let gate = HarnessEngineGate(result: .init(rawValue: -2))
        let engine = HarnessEngine()
        engine.onExecute = { _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        defer {
            SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
            gate.release()
            clock.releaseAll()
        }
        SessionRuntimeActor.sync { runtime.addToQueue(uris: ["spotify:track:superseded"]) }
        try await requireEventually { gate.hasStarted }
        let id = try #require(SessionRuntimeActor.sync { runtime.state.intents.last?.command.id })
        let worker = try #require(queueWorker(runtime))
        SessionRuntimeActor.sync {
            #expect(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                            ], localDeviceID: "mac", revision: 2)),
                    source: .engineDevices, revision: 2))
            fillPlaybackIntentHistory(runtime)
            #expect(!runtime.state.intents.contains { $0.command.id == id })
            #expect(runtime.state.transportCommandResolutions[id] == .superseded)
        }
        gate.release()
        await worker.wait()
        #expect(SessionRuntimeActor.sync { runtime.state.transportCommandResolutions[id] } == nil)
        #expect(SessionRuntimeActor.sync { runtime.feedback.message } == nil)
        #expect(SessionRuntimeActor.sync { runtime.effects.settlement(of: .engineRecovery) } == nil)
        #expect(engine.forceReconnectCount == 0)
        await runtime.shutdownForTermination()
    }

    @Test
    func cancelledObservedQueueCallDiscardsItsReceiptAfterHistoryPruning() async throws {
        let clock = HarnessClock.parked()
        let gate = HarnessEngineGate(result: .ok)
        let engine = HarnessEngine()
        engine.onExecute = { _ in gate.enter() }
        let runtime = makeRuntime(engine: engine, clock: clock)
        defer {
            SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
            gate.release()
            clock.releaseAll()
        }
        let uri = "spotify:track:observed"
        SessionRuntimeActor.sync { runtime.addToQueue(uris: [uri]) }
        try await requireEventually { gate.hasStarted }
        let id = try #require(SessionRuntimeActor.sync { runtime.state.intents.last?.command.id })
        let worker = try #require(
            SessionRuntimeActor.sync {
                #expect(
                    runtime.send(
                        .queue(
                            PlaybackQueueSnapshot(
                                entries: [PlaybackQueueItem(uri: uri, provider: "queue", uid: "observed")],
                                source: .connect, completeness: .complete, revision: 1, receivedAt: HarnessDates.fixed)),
                        source: .engineQueue, revision: 1))
                fillPlaybackIntentHistory(runtime)
                #expect(!runtime.state.intents.contains { $0.command.id == id })
                #expect(runtime.state.transportCommandResolutions[id] == .confirmed)
                let effect = runtime.effects.settlements().keys.first {
                    if case .queueCommand = $0 { return true }; return false
                }
                return effect.flatMap { runtime.effects.cancel($0) }
            })
        gate.release()
        await worker.wait()
        #expect(SessionRuntimeActor.sync { runtime.state.transportCommandResolutions[id] } == nil)
        #expect(SessionRuntimeActor.sync { runtime.feedback.message } == nil)
        await runtime.shutdownForTermination()
    }

    @Test
    func settlingAnOldIntentInvalidatesItsUnclaimedPermitAfterPruning() async {
        let runtime = makeRuntime(engine: HarnessEngine(), clock: HarnessClock.parked())
        SessionRuntimeActor.sync {
            let command = PendingPlaybackCommand(
                id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
            #expect(
                runtime.send(
                    .queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command))
            let permit = runtime.makePlaybackDispatchPermit(intentID: command.id, ifStillWanted: { true })
            #expect(permit != nil)
            fillPlaybackIntentHistory(runtime)
            #expect(runtime.send(.queueIntentFinished(id: command.id, accepted: false), source: .command))
            #expect(!runtime.state.intents.contains { $0.command.id == command.id })
            #expect(permit?.claim() == false)
        }
        await runtime.shutdownForTermination()
    }

    private func makeRuntime(engine: HarnessEngine, clock: HarnessClock) -> PlaybackSessionRuntime {
        SessionRuntimeActor.sync {
            let runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(engine: engine, clock: clock))
            #expect(runtime.send(.session(.ready), source: .account))
            #expect(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                            localDeviceID: "mac", revision: 1)),
                    source: .engineDevices, revision: 1))
            return runtime
        }
    }

    private func queueWorker(_ runtime: PlaybackSessionRuntime) -> SpottySessionRuntime.PlaybackEffectSettlement? {
        SessionRuntimeActor.sync {
            runtime.effects.settlements().first {
                if case .queueCommand = $0.key { return true }; return false
            }?.value
        }
    }
}

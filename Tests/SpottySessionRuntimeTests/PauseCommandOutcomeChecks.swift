import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let pauseAction = "Pause was rejected"
private let pauseTrack = CurrentTrack(
    uri: "spotify:track:fixture", title: "Now", artist: "Artist", duration: 200, metadataSource: .catalog)
private let pauseTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: HarnessDates.fixed)

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedPauseTarget(local: Bool, playing: Bool = true) throws {
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !local),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: pauseTrack, transport: playing ? .playing : .paused, timing: pauseTiming)),
                source: .user))
    }

    func restoreReadyAccount() async throws {
        account.hasStoredGrant = true
        await runtime.restore()
        runtime.receive(
            RustConnectionState(
                revision: 1, sessionGeneration: runtime.engineGeneration,
                sessionConnected: true, spircReady: true, isActiveDevice: true,
                resumePending: false, lastError: nil, deviceID: "mac"),
            revision: 1, receivedAt: HarnessDates.fixed)
        try #require(runtime.phase == .ready)
        try #require(runtime.isConnected)
        try seedPauseTarget(local: true)
    }

    func joinRecovery(_ gate: HarnessEngineGate) async throws {
        try await requireEventually(description: "Recovery enters the held engine rebuild") { gate.enteredCount == 1 }
        let recovery = try #require(runtime.effects.settlement(of: .engineRecovery))
        gate.finish(with: .ok)
        await recovery.wait()
        #expect(engine.forceReconnectCount == 1)
        #expect(account.authorizeCount == 0)
    }
}

@Suite("Pause and resume command outcomes")
@SessionRuntimeActor
struct PauseCommandOutcomeTests {
    @Test(arguments: [false, true], [false, true])
    func pauseReportsItsDependencyOutcomeExactlyOnce(local: Bool, success: Bool) async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedPauseTarget(local: local)
            var completions: [Bool] = []
            let command = try fixture.capture(.transport) {
                fixture.runtime.submitCommand(
                    .pause, failureMessage: pauseAction, completion: { completions.append($0) })
            }
            try await fixture.reply(through: local ? .local : .remote, success: success)
            await command.settlement.wait()
            #expect(completions == [success])
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.semantic.notice?.message == (success ? nil : pauseAction))
            #expect(fixture.account.authorizeCount == 0)
            #expect(fixture.engine.forceReconnectCount == 0)
            if local {
                guard case .pause? = fixture.engine.operations.first else {
                    Issue.record("The local engine must receive pause")
                    return
                }
                #expect(fixture.engine.operations.count == 1)
                #expect(fixture.remote.sendCount == 0)
            } else {
                #expect(fixture.remote.endpoints == [.pause])
                #expect(fixture.engine.operations.isEmpty)
            }
        }
    }

    @Test func cancellingAnEnteredRemotePauseCompletesOnceWithoutNotice() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedPauseTarget(local: false)
            var completions: [Bool] = []
            let command = try fixture.capture(.transport) {
                fixture.runtime.submitCommand(
                    .pause, failureMessage: pauseAction, completion: { completions.append($0) })
            }
            try await fixture.requireDispatch(through: .remote)
            try #require(fixture.runtime.effects.cancel(.command(command.id)) != nil)
            await command.settlement.wait()
            #expect(completions == [false])
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remote.endpoints == [.pause])
            #expect(fixture.remoteResponses.waiterCount == 0)
            #expect(fixture.engine.operations.isEmpty)
        }
    }

    @Test func reconnectRequiredWithoutAReadyAccountStartsAccountConnection() async throws {
        try await withCommandRuntime { fixture in
            // Exercise the command owner's fallback before account readiness, independently of
            // desktop command admission, which requires a ready session.
            try fixture.seedPauseTarget(local: true)
            var completions: [Bool] = []
            let command = try fixture.capture(.transport) {
                fixture.runtime.submitCommand(
                    .pause, failureMessage: pauseAction, completion: { completions.append($0) })
            }
            try await fixture.requireDispatch(through: .local)
            fixture.engineGate.finish(with: PlaybackEngineResult(rawValue: -2))
            await command.settlement.wait()
            #expect(completions == [false])
            #expect(fixture.runtime.semantic.notice?.message == pauseAction)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            try await requireEventually { fixture.account.authorizeCount == 1 }
            #expect(fixture.engine.forceReconnectCount == 0)
        }
    }

    @Test(arguments: [Int32(-2), -3])
    func reconnectRequiredOnAReadyAccountRebuildsWithoutAuthorization(code: Int32) async throws {
        let recovery = HarnessEngineGate()
        try await withCommandRuntime(closing: { recovery.close() }) { fixture in
            try await fixture.restoreReadyAccount()
            fixture.engine.onForceReconnect = { recovery.enter().rawValue }
            var completions: [Bool] = []
            let command = try fixture.capture(.transport) {
                fixture.runtime.submitCommand(
                    .pause, failureMessage: pauseAction, completion: { completions.append($0) })
            }
            try await fixture.requireDispatch(through: .local)
            fixture.engineGate.finish(with: PlaybackEngineResult(rawValue: code))
            await command.settlement.wait()
            #expect(completions == [false])
            #expect(fixture.runtime.semantic.notice?.message == pauseAction)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            try await fixture.joinRecovery(recovery)
        }
    }

    @Test func cancellingRecoveryBeforeDispatchPreventsAnEngineRebuild() async throws {
        try await withCommandRuntime { fixture in
            try await fixture.restoreReadyAccount()
            // Admit, capture and cancel on the runtime actor before its worker can start.
            fixture.runtime.recoverEngineAfterCommandFailure()
            let recovery = try #require(fixture.runtime.effects.settlement(of: .engineRecovery))
            try #require(fixture.runtime.effects.cancel(.engineRecovery) != nil)
            await recovery.wait()
            #expect(fixture.engine.forceReconnectCount == 0)
            #expect(fixture.account.authorizeCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func observedPauseStillRecoversFromALateReconnectFailure(engineObservation: Bool) async throws {
        let recovery = HarnessEngineGate()
        try await withCommandRuntime(closing: { recovery.close() }) { fixture in
            try await fixture.restoreReadyAccount()
            fixture.engine.onForceReconnect = { recovery.enter().rawValue }
            var completions: [Bool] = []
            let command = try fixture.capture(.transport) {
                fixture.runtime.submitCommand(
                    .pause, failureMessage: pauseAction, completion: { completions.append($0) })
            }
            try await fixture.requireDispatch(through: .local)
            if engineObservation {
                try #require(
                    fixture.runtime.send(
                        .enginePlayback(
                            EnginePlaybackSnapshot(transport: .paused, trackURI: pauseTrack.uri, timing: pauseTiming)),
                        source: .enginePlayback, revision: 1))
            } else {
                try #require(
                    fixture.runtime.send(
                        .presentation(
                            PlaybackPresentationSnapshot(
                                currentTrack: pauseTrack, transport: .paused, timing: pauseTiming)),
                        source: .user))
            }
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.state.transportCommandResolutions[command.id] == .confirmed)
            fixture.engineGate.finish(with: PlaybackEngineResult(rawValue: -2))
            await command.settlement.wait()
            #expect(completions == [true])
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.runtime.state.transport == .paused)
            #expect(fixture.runtime.state.transportCommandResolutions[command.id] == nil)
            try await fixture.joinRecovery(recovery)
        }
    }

    @Test func resumeValidatesDisplayedIdentityAndPositionInsteadOfStickyEngineValues() async throws {
        try await withCommandRuntime { fixture in
            fixture.engine.resumePosition = 93_606
            fixture.engine.onResumeContextURI = { "spotify:playlist:sticky-context" }
            fixture.engine.onResumeTrackURI = { "spotify:track:sticky-track" }
            try #require(fixture.runtime.send(.session(.ready), source: .account))
            try fixture.seedPauseTarget(local: true, playing: false)
            #expect(fixture.runtime.canTogglePlayback)
            let command = try fixture.capture(.transport) { fixture.runtime.togglePlayback() }
            try await fixture.requireDispatch(through: .local)
            guard case let .resumeObserved(target)? = fixture.engine.operations.first else {
                Issue.record("Resume must validate the displayed target through the engine")
                return
            }
            #expect(target.contextURI == nil)
            #expect(target.trackURI == pauseTrack.uri)
            #expect(target.positionMS == 50_000)
            #expect(target.engineGeneration == fixture.runtime.engineGeneration)
            #expect(fixture.engine.operations.count == 1)
            #expect(fixture.remote.sendCount == 0)
            fixture.engineGate.finish(with: .ok)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport]?.id == command.id)
            #expect(fixture.runtime.state.intents.last?.outcome == .sent, "Engine return alone cannot confirm resume")
        }
    }
}

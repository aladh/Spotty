import Foundation
import Testing
import SpottyDomain
import SpottyRuntimeContracts
@testable import SpottyCore
@testable import SpottyEngineAdapter
@testable import SpottySessionRuntime

@Suite("Hydrated resume")
@MainActor
struct HydratedResumeTests {
    private let track = "spotify:track:hydrated"
    private let context = "spotify:playlist:hydrated-context"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func playback(
        revision: UInt64, uri: String, playing: Bool, positionMS: Int64 = 152_000,
        carriesContext: Bool = true
    )
        -> RustPlaybackState
    {
        RustPlaybackState(
            revision: revision, sessionGeneration: 1, isPlaying: playing, isPaused: !playing,
            trackURI: uri, positionMS: positionMS, durationMS: 240_000, timestampMS: 0,
            shuffle: !uri.isEmpty, repeatTrack: false, repeatContext: !uri.isEmpty,
            isActiveDevice: revision > 1, contextURI: carriesContext ? (uri.isEmpty ? "" : context) : nil)
    }

    private func hydratedPlayer(engine: HarnessEngine, clock: any PlaybackClock = HarnessClock.sticky()) async
        -> PlaybackStore
    {
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: HarnessRemote(metadataTitle: "Hydrated"), clock: clock))
        await player.queueService.reset(accountEpoch: player.accountEpoch)
        player.receive(
            RustConnectClusterState(
                revision: 1, sessionGeneration: 1, source: 1, localDeviceID: "mac",
                devices: RustDevicesState(
                    revision: 1, sessionGeneration: 1, activeDeviceID: "",
                    devices: [ConnectProtocolDevice(id: "mac", name: "Mac", type: "computer")]),
                connection: RustConnectionState(
                    revision: 1, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                    isActiveDevice: false, resumePending: false, lastError: nil, deviceID: "mac"),
                playback: playback(revision: 1, uri: track, playing: false),
                queue: RustQueueState(
                    revision: 1, sessionGeneration: 1,
                    track: RustQueueState.Item(uri: track, provider: "context", uid: "current"),
                    protocolNextTracks: [
                        QueueProtocolTrack(uri: "spotify:track:next", uid: "next", provider: "context")
                    ],
                    protocolPrevTracks: [], queueRevision: "initial", disallowSetQueue: false,
                    disallowRemovingFromNextTracks: false)),
            receivedAt: now)
        return player
    }

    @Test func firstPlayKeepsHydratedIdentityUntilMatchingPlaybackArrives() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .ok)
        engine.onExecute = { _ in gate.enter() }
        let player = await hydratedPlayer(engine: engine)
        await expectEventually { player.canTogglePlayback && player.queueNextEntries.count == 1 }
        let initialQueue = player.queueNextEntries
        #expect(player.trackURI == track)
        #expect(player.position == 152)
        #expect(player.defaultLocalPlaybackDevice?.id == "mac")
        #expect(player.isShuffleEnabled && player.repeatMode == .context)
        #expect(CatalogPlaybackAccess(player: player).isPlayingPlaylist(context))

        player.togglePlayback()
        await expectEventually { gate.hasStarted }
        #expect(player.state.transport == .paused, "resume does not claim audio before a Playing observation")
        if case let .resumeObserved(target) = engine.operations.first {
            #expect(
                target
                    == PlaybackResumeTarget(
                        trackURI: track, contextURI: context, positionMS: 152_000, engineGeneration: 1))
        } else {
            Issue.record("First Play must validate the hydrated snapshot")
        }

        // A cold activation can briefly omit its player. It cannot erase a pending resume.
        player.receive(playback(revision: 2, uri: "", playing: false, positionMS: 0), revision: 2, receivedAt: now)
        #expect(player.trackURI == track)
        #expect(player.position == 152)
        #expect(player.playingContextURI == context)
        #expect(player.queueNextEntries == initialQueue)
        #expect(player.isShuffleEnabled && player.repeatMode == .context)
        #expect(player.state.intents.last?.outcome == .dispatched)

        player.receive(playback(revision: 3, uri: track, playing: false), revision: 3, receivedAt: now)
        #expect(player.state.transport == .paused)
        #expect(player.state.intents.last?.outcome == .dispatched)
        player.receive(
            playback(revision: 4, uri: track, playing: true, carriesContext: false), revision: 4, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .dispatched, "omitted context is not resume confirmation")
        #expect(player.state.transport == .paused, "local audio cannot establish Spotify playback authority")
        #expect(player.position == 152 && player.isShuffleEnabled && player.repeatMode == .context)
        player.receive(playback(revision: 5, uri: track, playing: true), revision: 5, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .observedConfirmed)
        #expect(player.trackURI == track && player.position == 152)
        #expect(player.state.transport == .playing)
        gate.finish(with: .ok)
        await player.shutdownForTermination()
    }

    @Test func unsafeResumeLeavesAnExplicitNoticeAndRequiresSelection() async {
        let engine = HarnessEngine(executeResult: .resumeMismatch, position: 152_000)
        let player = await hydratedPlayer(engine: engine)
        await expectEventually { player.canTogglePlayback }
        player.togglePlayback()
        await expectEventually { player.playbackNotice?.kind == .resumeUnavailable }
        #expect(player.trackURI == track && player.position == 152)
        #expect(player.state.transport == .paused)
        #expect(!player.canTogglePlayback)
        #expect(player.canStartPlayback)
        #expect(engine.executeCount == 1, "a rejected snapshot cannot fall back to another load")
        #expect(engine.forceReconnectCount == 0)
        player.togglePlayback()
        #expect(engine.executeCount == 1, "the stale track is not advertised as resumable")
        engine.executeResult = .ok
        player.play(uri: "spotify:track:chosen")
        await expectEventually { engine.executeCount == 2 && player.state.pendingCommands[.transport] == nil }
        #expect(player.playbackNotice == nil)
        await player.shutdownForTermination()
    }

    @Test func aMovedPositionCannotConfirmTheHydratedResume() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .resumeMismatch)
        engine.onExecute = { _ in gate.enter() }
        let player = await hydratedPlayer(engine: engine)
        await expectEventually { player.canTogglePlayback }
        player.togglePlayback()
        await expectEventually { gate.hasStarted }
        player.receive(playback(revision: 2, uri: track, playing: false, positionMS: 0), revision: 2, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .dispatched)
        gate.finish(with: .resumeMismatch)
        await expectEventually { player.playbackNotice?.kind == .resumeUnavailable }
        #expect(player.state.intents.last?.outcome == .rejected)
        #expect(!player.canTogglePlayback && engine.executeCount == 1)
        await player.shutdownForTermination()
    }

    @Test func missingContextCannotHideAnEngineResumeRejection() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .resumeMismatch)
        engine.onExecute = { _ in gate.enter() }
        let player = await hydratedPlayer(engine: engine)
        await expectEventually { player.canTogglePlayback }
        player.togglePlayback()
        await expectEventually { gate.hasStarted }
        player.receive(
            playback(revision: 2, uri: track, playing: true, carriesContext: false), revision: 2, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .dispatched)
        gate.finish(with: .resumeMismatch)
        await expectEventually { player.playbackNotice?.kind == .resumeUnavailable }
        #expect(player.state.intents.last?.outcome == .rejected)
        #expect(player.state.transport == .paused)
        #expect(!player.canTogglePlayback && engine.executeCount == 1)
        await player.shutdownForTermination()
    }

    @Test func transientFailuresCannotEraseAnUnsafeResumeNotice() async {
        let engine = HarnessEngine(executeResult: .resumeMismatch, position: 152_000)
        let clock = HarnessClock.parked()
        let player = await hydratedPlayer(engine: engine, clock: clock)
        await expectEventually { player.canTogglePlayback }
        player.showTransientCommandError("An earlier failure")
        await expectEventually { clock.requestedSleeps.contains(4) }
        let oldDismissal = player.effects.settlement(of: .commandError)
        #expect(oldDismissal != nil)
        player.togglePlayback()
        await expectEventually { player.playbackNotice?.kind == .resumeUnavailable }
        let notice = player.playbackNotice
        clock.releaseAll()
        await oldDismissal?.wait()
        #expect(player.playbackNotice == notice, "an older dismissal cannot clear the resume notice")

        player.receive(
            RustConnectionState(
                revision: 2, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                isActiveDevice: true, resumePending: false, lastError: nil, deviceID: "mac"),
            revision: 2, receivedAt: now)
        engine.executeResult = .error
        player.toggleShuffle()
        await expectEventually { engine.executeCount == 2 && player.state.pendingCommands[.options] == nil }
        #expect(player.playbackNotice == notice, "a rejected command cannot replace the resume notice")
        player.showTransientCommandError("Another failure")
        #expect(player.playbackNotice == notice)
        #expect(player.effects.settlement(of: .commandError) == nil, "no new transient dismissal is scheduled")
        #expect(!player.canTogglePlayback)
        await player.shutdownForTermination()
    }

    @Test func unconfirmedResumeTimesOutWithoutPublishingLocalProgressOrAdvancement() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .ok)
        engine.onExecute = { _ in gate.enter() }
        let clock = HarnessClock.parked(now: now)
        let player = await hydratedPlayer(engine: engine, clock: clock)
        await expectEventually { player.canTogglePlayback && player.queueNextEntries.count == 1 }
        let originalQueue = player.queueNextEntries
        player.togglePlayback()
        await expectEventually { gate.hasStarted && clock.requestedSleeps.contains(8) }
        gate.finish(with: .ok)
        await expectEventually { player.state.intents.last?.outcome == .sent }
        #expect(player.state.pendingCommands[.transport] != nil)

        player.receive(
            playback(revision: 2, uri: track, playing: true, positionMS: 155_000, carriesContext: false),
            revision: 2, receivedAt: now.addingTimeInterval(3))
        #expect(player.state.transport == .paused && player.position == 152)
        clock.advance(seconds: 8)
        clock.releaseAll()
        await expectEventually {
            player.state.intents.last?.outcome == .timedOut && player.playbackNotice?.kind == .resumeUnavailable
        }
        #expect(player.playbackNotice?.kind == .resumeUnavailable)
        #expect(player.state.transport == .paused && player.position == 152)
        #expect(player.isShuffleEnabled && player.repeatMode == .context)
        #expect(player.queueNextEntries == originalQueue)
        #expect(!player.canTogglePlayback)

        // An abandoned local player completing a track is still not Spotify session evidence.
        player.receive(
            playback(revision: 3, uri: "spotify:track:wrong", playing: true, positionMS: 0, carriesContext: false),
            revision: 3, receivedAt: now.addingTimeInterval(9))
        #expect(player.trackURI == track && player.state.transport == .paused && player.position == 152)
        // Reconcile to a fresh server snapshot without rewriting the terminal timeout outcome.
        player.receive(
            playback(revision: 4, uri: track, playing: false), revision: 4, receivedAt: now.addingTimeInterval(10))
        #expect(player.trackURI == track && player.state.transport == .paused && player.position == 152)
        #expect(player.state.intents.last?.outcome == .timedOut)
        await player.shutdownForTermination()
    }

    @Test func confirmedResumeAdvancesOnlyWithTheObservedQueue() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .ok)
        engine.onExecute = { _ in gate.enter() }
        let player = await hydratedPlayer(engine: engine)
        await expectEventually { player.canTogglePlayback && player.queueNextEntries.count == 1 }
        let nextURI = player.queueNextEntries[0].uri
        player.togglePlayback()
        await expectEventually { gate.hasStarted }
        player.receive(
            playback(revision: 2, uri: track, playing: true, carriesContext: false), revision: 2, receivedAt: now)
        #expect(player.state.transport == .paused)
        player.receive(playback(revision: 3, uri: track, playing: true), revision: 3, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .observedConfirmed)
        gate.finish(with: .ok)
        // These are the same protocol facts available to a second Connect client after natural end.
        let crossClient = playback(revision: 4, uri: nextURI, playing: true, positionMS: 250)
        player.receive(crossClient, revision: 4, receivedAt: now.addingTimeInterval(90))
        #expect(player.trackURI == crossClient.trackURI && player.position == 0.25)
        #expect(player.isShuffleEnabled && player.repeatMode == .context)
        #expect(player.playbackNotice == nil)
        await player.shutdownForTermination()
    }

}

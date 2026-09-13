import Foundation
import Testing
import SpottyDomain
import SpottyRuntimeContracts
@testable import SpottyCore
@testable import SpottyEngineAdapter

@Suite("Hydrated resume")
@MainActor
struct HydratedResumeTests {
    private let track = "spotify:track:hydrated"
    private let context = "spotify:playlist:hydrated-context"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func playback(revision: UInt64, uri: String, playing: Bool, positionMS: Int64 = 152_000) -> RustPlaybackState {
        RustPlaybackState(
            revision: revision, sessionGeneration: 1, isPlaying: playing, isPaused: !playing,
            trackURI: uri, positionMS: positionMS, durationMS: 240_000, timestampMS: 0,
            shuffle: true, repeatTrack: false, repeatContext: true,
            isActiveDevice: revision > 1, contextURI: uri.isEmpty ? "" : context)
    }

    private func hydratedPlayer(engine: HarnessEngine) -> PlaybackStore {
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: HarnessRemote(metadataTitle: "Hydrated")))
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
                    protocolNextTracks: [QueueProtocolTrack(uri: "spotify:track:next", uid: "next", provider: "context")],
                    protocolPrevTracks: [], queueRevision: "initial", disallowSetQueue: false,
                    disallowRemovingFromNextTracks: false)),
            receivedAt: now)
        return player
    }

    @Test func firstPlayKeepsHydratedIdentityUntilMatchingPlaybackArrives() async {
        let engine = HarnessEngine(position: 152_000)
        let gate = HarnessEngineGate(result: .ok)
        engine.onExecute = { _ in gate.enter() }
        let player = hydratedPlayer(engine: engine)
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
            #expect(target == PlaybackResumeTarget(
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
        #expect(player.state.intents.last?.outcome == .dispatched)

        player.receive(playback(revision: 3, uri: track, playing: false), revision: 3, receivedAt: now)
        #expect(player.state.transport == .paused)
        #expect(player.state.intents.last?.outcome == .dispatched)
        player.receive(playback(revision: 4, uri: track, playing: true), revision: 4, receivedAt: now)
        #expect(player.state.intents.last?.outcome == .observedConfirmed)
        #expect(player.trackURI == track && player.position == 152)
        #expect(player.state.transport == .playing)
        gate.finish(with: .ok)
        await player.shutdownForTermination()
    }

    @Test func unsafeResumeLeavesAnExplicitNoticeAndRequiresSelection() async {
        let engine = HarnessEngine(executeResult: .resumeMismatch, position: 152_000)
        let player = hydratedPlayer(engine: engine)
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
}

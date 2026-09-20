import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Catalog row playback actions")
@MainActor
struct CatalogPlaybackActionChecks {
    @Test(arguments: [false, true])
    func currentRowResumesOrPausesWithoutReloading(playing: Bool) async throws {
        let remote = HarnessRemote(send: .park)
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
        let track = HarnessFixtures.track(uri: "spotify:track:current", title: "Current", duration: 200)
        seed(player, track: track, playing: playing)
        let access = CatalogPlaybackAccess(player: player)
        #expect(access.action(for: track, behavior: .activateSelection).isEnabled)
        access.action(for: track, behavior: .activateSelection).perform()
        try await requireEventually { remote.sendCount == 1 }
        #expect(remote.endpoints == [playing ? .pause : .resume])
        #expect(player.trackURI == track.uri && player.position == 42)
        #expect(engine.operations.isEmpty)
        #expect(
            !access.action(for: track, behavior: .activateSelection).isEnabled,
            "pending transport disables repeat activation")
        access.action(for: track, behavior: .activateSelection).perform()
        #expect(remote.sendCount == 1)
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true], [false, true])
    func retainedRowTargetsItsTrackAfterTheCurrentTrackChanges(published: Bool, isPlayable: Bool) async throws {
        let remote = HarnessRemote(send: .park)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: remote))
        let first = HarnessFixtures.track(uri: "spotify:track:first", title: "First", duration: 200)
        let second = HarnessFixtures.track(uri: "spotify:track:second", title: "Second", duration: 200)
        seed(player, track: first, playing: true)
        let access = CatalogPlaybackAccess(player: player)
        if published {
            seed(player, track: second, playing: true)
        } else {
            let runtime = player.runtime
            SessionRuntimeActor.sync { seed(runtime, track: second, playing: true) }
            #expect(player.trackURI == first.uri, "the desktop has not consumed the next publication")
        }
        let before = player.state
        access.action(for: first, behavior: .activateSelection, isPlayable: isPlayable).perform()
        if isPlayable {
            try await requireEventually { remote.sendCount == 1 }
            #expect(remote.endpoints == [.play], "a retained Pause control cannot pause a different track")
            #expect(remote.commands.first?.context?.uri == first.uri)
        } else {
            #expect(player.state == before, "a retained Pause control cannot start an unavailable track")
        }
        await player.shutdownForTermination()
        if !isPlayable { #expect(remote.sendCount == 0) }
    }

    @Test(arguments: [false, true])
    func unavailableCurrentTrackCanOnlyBePaused(playing: Bool) async throws {
        let remote = HarnessRemote(send: .park)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: remote))
        let track = HarnessFixtures.track(uri: "spotify:track:unavailable", title: "Unavailable", duration: 200)
        seed(player, track: track, playing: playing)
        let access = CatalogPlaybackAccess(player: player)
        #expect(access.action(for: track, behavior: .activateSelection, isPlayable: false).isEnabled == playing)
        let before = player.state
        access.action(for: track, behavior: .activateSelection, isPlayable: false).perform()
        if playing {
            try await requireEventually { remote.sendCount == 1 }
            #expect(remote.endpoints == [.pause])
        } else {
            #expect(player.state == before)
        }
        await player.shutdownForTermination()
        if !playing { #expect(remote.sendCount == 0) }
    }

    @Test func replacedAccountAndDisconnectedRowsCannotActivate() async {
        let remote = HarnessRemote()
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
        let track = HarnessFixtures.track(uri: "spotify:track:row", title: "Row", duration: 200)
        let access = CatalogPlaybackAccess(player: player)
        #expect(!access.action(for: track, behavior: .activateSelection).isEnabled)
        access.action(for: track, behavior: .activateSelection).perform()
        seed(player, track: track, playing: true)
        #expect(access.action(for: track, behavior: .activateSelection).isEnabled)
        player.withRuntime {
            $0.accountStore.advanceEpoch()
            _ = $0.send(.reset(session: .ready), source: .account)
        }
        seed(player, track: track, playing: true)
        #expect(player.canTogglePlayback)
        let replacement = player.state
        #expect(!access.action(for: track, behavior: .activateSelection).isEnabled)
        access.action(for: track, behavior: .activateSelection).perform()
        #expect(player.state == replacement)
        #expect(remote.sendCount == 0 && engine.operations.isEmpty)
        await player.shutdownForTermination()
    }

    private func seed(_ player: PlaybackStore, track: CatalogTrack, playing: Bool) {
        player.withRuntime { seed($0, track: track, playing: playing) }
    }

    @SessionRuntimeActor
    private func seed(_ runtime: PlaybackSessionRuntime, track: CatalogTrack, playing: Bool) {
        _ = runtime.send(.session(.ready), source: .account)
        _ = runtime.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer")],
                    localDeviceID: "mac", revision: 1)),
            source: .engineDevices, revision: 1)
        _ = runtime.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: track.uri, title: track.title, artist: "Artist", duration: 200,
                        metadataSource: .catalog),
                    transport: playing ? .playing : .paused,
                    timing: PlaybackTiming(position: 42, duration: 200, anchoredAt: HarnessDates.fixed))),
            source: .user)
        _ = runtime.send(
            .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
            source: .engineConnection)
    }
}

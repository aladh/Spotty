import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Catalog playlist shuffle target")
@MainActor
struct CatalogPlaylistShuffleChecks {
    @Test(arguments: [false, true], [false, true])
    func shuffleUsesLoadedTracksOnlyForTheSelectedPlaylist(local: Bool, matchesLoaded: Bool) async throws {
        let engine = HarnessEngine()
        let remote = HarnessRemote(send: .park)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
        let current = HarnessFixtures.track(uri: "spotify:track:current")
        let selected = CatalogItem(
            id: "selected", uri: "spotify:playlist:selected", title: "Selected", subtitle: "", artworkURL: nil,
            kind: .playlist)
        let loadedTracks = [
            HarnessFixtures.track(uri: "spotify:track:first"),
            HarnessFixtures.track(uri: "spotify:track:second"),
            HarnessFixtures.track(uri: "spotify:track:first"),
        ]
        let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local)
        player.withRuntime {
            _ = $0.send(.session(.ready), source: .account)
            _ = $0.send(
                .devices(PlaybackDeviceSnapshot(devices: [device], localDeviceID: "mac", revision: 1)),
                source: .engineDevices, revision: 1)
            _ = $0.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: current.uri, title: current.title, artist: current.artist, duration: current.duration,
                            metadataSource: .catalog),
                        transport: .paused,
                        timing: PlaybackTiming(position: 42, duration: current.duration, anchoredAt: HarnessDates.fixed)
                    )),
                source: .user)
            _ = $0.send(
                .owner(
                    local ? .local(device) : .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
                source: .engineConnection)
            $0.setShuffleEnabled(true)
        }
        player.catalog.playlistStore.replaceLoadedPlaylist(
            uri: matchesLoaded ? selected.uri : "spotify:playlist:previous", tracks: loadedTracks)
        CatalogPlaybackAccess(player: player).activateItem(selected)
        try await requireEventually { local ? engine.executeCount == 1 : remote.sendCount == 1 }
        if local {
            #expect(remote.sendCount == 0)
            switch try #require(engine.operations.first) {
            case let .playTracks(uris):
                #expect(matchesLoaded)
                #expect(uris.sorted() == loadedTracks.map(\.uri).sorted())
            case let .playURI(uri):
                #expect(!matchesLoaded)
                #expect(uri == selected.uri)
            default:
                Issue.record("Playlist selection must dispatch the selected URI or its own shuffled tracks")
            }
        } else {
            #expect(engine.operations.isEmpty)
            let command = try #require(remote.commands.first)
            #expect(command.endpoint == .play)
            if matchesLoaded {
                #expect(command.context?.trackURIs?.sorted() == loadedTracks.map(\.uri).sorted())
            } else {
                #expect(command.context?.uri == selected.uri)
                #expect(command.context?.trackURIs == nil)
            }
        }
        if !matchesLoaded {
            #expect(
                player.trackURI == current.uri, "an unrelated loaded playlist cannot supply optimistic track metadata")
        }
        await player.shutdownForTermination()
    }
}

@testable import SpottyRuntimeTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@MainActor
struct CatalogRuntimeExportTests {
    @Test func snapshotsPreserveLearnedLinksWithoutSharingMutableOrAccountState() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let artist = CatalogItem(
            id: "artist", uri: "spotify:artist:artist", title: "Artist", subtitle: "", artworkURL: nil, kind: .artist)
        let rich = CatalogTrack(
            id: "row", uri: "spotify:track:shared", title: "Track", artist: "Artist", album: "Album",
            duration: 180, artworkURL: nil, addedAt: nil, artists: [artist])
        let partial = CatalogTrack(
            id: "row-2", uri: rich.uri, title: "Updated", artist: rich.artist, album: rich.album,
            duration: rich.duration, artworkURL: nil, addedAt: nil)
        metadata.replaceTracks([rich], from: .search)
        let earlier = metadata.browsingMetadata
        metadata.replaceTracks([partial], from: .library)
        metadata.replaceTracks([], from: .search)
        let later = metadata.browsingMetadata
        #expect(earlier.tracks[rich.uri]?.title == rich.title)
        #expect(later.tracks[rich.uri]?.title == partial.title)
        #expect(later.tracks[rich.uri]?.artists == [artist])
        session.update(accountEpoch: 2, isAvailable: true)
        metadata.replaceTracks([partial], from: .library)
        #expect(metadata.browsingMetadata.accountEpoch == 2)
        #expect(metadata.browsingMetadata.tracks[rich.uri]?.artists == [])
        #expect(later.tracks[rich.uri]?.artists == [artist])
    }

    @Test func runtimeRejectsUnavailableStaleAndRetiredBrowsingSnapshots() async {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let runtime = player.runtime
        let track = HarnessFixtures.track(uri: "spotify:track:browsing", title: "Current")
        let entities = [track.uri: CatalogTrackMetadata(track: track, requestedURI: track.uri)]
        SessionRuntimeActor.sync {
            let initial = BrowsingMetadataSnapshot(accountEpoch: runtime.accountEpoch, revision: 3, tracks: entities)
            #expect(runtime.acceptCatalogMetadata(initial) == false)
            runtime.accountStore.publishPhase(.ready)
            #expect(runtime.acceptCatalogMetadata(initial))
            let stale = BrowsingMetadataSnapshot(accountEpoch: runtime.accountEpoch, revision: 2, tracks: [:])
            #expect(runtime.acceptCatalogMetadata(stale) == false)
            runtime.accountStore.publishPhase(.connecting)
            let refused = BrowsingMetadataSnapshot(accountEpoch: runtime.accountEpoch, revision: 10, tracks: [:])
            #expect(runtime.acceptCatalogMetadata(refused) == false)
            runtime.accountStore.publishPhase(.ready)
            let next = BrowsingMetadataSnapshot(accountEpoch: runtime.accountEpoch, revision: 4, tracks: entities)
            #expect(runtime.acceptCatalogMetadata(next))
            #expect(runtime.catalogMetadata.knownTrack(for: track.uri)?.title == track.title)
            #expect(runtime.catalogMetadata.playbackTracks.isEmpty)
        }
        let previousEpoch = player.accountEpoch
        await player.logout()
        SessionRuntimeActor.sync {
            runtime.accountStore.publishPhase(.ready)
            let current = BrowsingMetadataSnapshot(accountEpoch: runtime.accountEpoch, revision: 0, tracks: entities)
            #expect(runtime.acceptCatalogMetadata(current))
            let retired = BrowsingMetadataSnapshot(accountEpoch: previousEpoch, revision: 100, tracks: [:])
            #expect(runtime.acceptCatalogMetadata(retired) == false)
            #expect(runtime.catalogMetadata.knownTrack(for: track.uri)?.title == track.title)
        }
        await player.shutdownForTermination()
    }

    @Test func desktopOwnsCatalogLoadAndPreservesSkippedSessionTransitions() async throws {
        let provider = HarnessCatalog()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(account: HarnessAccount(hasGrant: true), catalog: provider))
        await player.restore()
        await player.catalogLoadTask?.value
        #expect(provider.count("home") == 1)
        let initial = player.catalogSession.snapshot
        var savedContent = CatalogLoadState()
        savedContent.receive(session: initial)

        // Playback and engine publications within the same catalog session must not reload it.
        player.withRuntime { runtime in
            runtime.send(.session(runtime.state.session), source: .account, engineEpoch: runtime.engineGeneration &+ 1)
        }
        await player.catalogLoadTask?.value
        #expect(provider.count("home") == 1)
        #expect(savedContent.isCurrent(in: player.catalogSession.snapshot))

        // Both transitions occur before the desktop can consume a publication. The latest
        // snapshot must carry their lifetime change even though its final Boolean is still true.
        player.withRuntime { runtime in
            runtime.accountStore.publishPhase(.connecting)
            runtime.accountStore.publishPhase(.ready)
        }
        await player.catalogLoadTask?.value
        #expect(provider.count("home") == 2)
        #expect(player.catalogSession.snapshot.accountEpoch == initial.accountEpoch)
        #expect(player.catalogSession.snapshot.isAvailable)
        #expect(!savedContent.isCurrent(in: player.catalogSession.snapshot))
        await player.shutdownForTermination()
    }

    @Test func playbackPublicationsNeverBecomeBrowsingInput() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let track = HarnessFixtures.track(uri: "spotify:track:current", title: "Runtime label")
        metadata.replaceTracks([track], from: .playback)
        #expect(metadata.browsingMetadata.tracks.isEmpty)
        #expect(metadata.browsingMetadata.revision == 0)

        // Export must change even when the UI's effective label remains equal to its queue copy.
        metadata.replaceTracks([track], from: .playlist)
        #expect(
            metadata.browsingMetadata.tracks == [track.uri: CatalogTrackMetadata(track: track, requestedURI: track.uri)]
        )
        #expect(metadata.browsingMetadata.revision == 1)
        metadata.replaceTracks([], from: .playlist)
        #expect(metadata.knownTrack(for: track.uri) == track)
        #expect(metadata.browsingMetadata.tracks.isEmpty)
        #expect(metadata.browsingMetadata.revision == 2)
    }

    @Test func exportRevisionIgnoresUnchangedAndShadowedWrites() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let preferred = HarnessFixtures.track(uri: "spotify:track:current", title: "Library label")
        let fallback = HarnessFixtures.track(uri: preferred.uri, title: "Search label")
        metadata.replaceTracks([preferred], from: .library)
        let revision = metadata.browsingMetadata.revision
        metadata.replaceTracks([preferred], from: .library)
        metadata.replaceTracks([fallback], from: .search)
        metadata.replaceTracks([fallback], from: .playback)
        #expect(metadata.browsingMetadata.revision == revision)
        #expect(
            metadata.browsingMetadata.tracks == [
                preferred.uri: CatalogTrackMetadata(track: preferred, requestedURI: preferred.uri)
            ])
        metadata.replaceTracks([], from: .library)
        #expect(metadata.browsingMetadata.revision == revision + 1)
        #expect(
            metadata.browsingMetadata.tracks == [
                fallback.uri: CatalogTrackMetadata(track: fallback, requestedURI: fallback.uri)
            ])
    }

    @Test func exportCannotReadAnOlderAccountBeforeReset() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let previous = HarnessFixtures.track(uri: "spotify:track:account-a")
        metadata.replaceTracks([previous], from: .library)
        session.update(accountEpoch: 2, isAvailable: true)
        #expect(metadata.browsingMetadata.tracks.isEmpty)
        let current = HarnessFixtures.track(uri: "spotify:track:account-b")
        metadata.replaceTracks([current], from: .playlist)
        #expect(
            metadata.browsingMetadata.tracks == [
                current.uri: CatalogTrackMetadata(track: current, requestedURI: current.uri)
            ])
        #expect(metadata.browsingMetadata.tracks[previous.uri] == nil)
    }
}

import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

@MainActor
struct CatalogRuntimeExportTests {
    @Test func playbackPublicationsNeverBecomeBrowsingInput() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
        let track = HarnessFixtures.track(uri: "spotify:track:current", title: "Runtime label")
        metadata.replaceTracks([track], from: .nowPlaying)
        metadata.replaceTracks([track], from: .queue)
        #expect(metadata.runtimeTracks.isEmpty)
        #expect(metadata.runtimeTracksRevision == 0)

        // Export must change even when the UI's effective label remains equal to its queue copy.
        metadata.replaceTracks([track], from: .playlist)
        #expect(metadata.runtimeTracks == [track.uri: track])
        #expect(metadata.runtimeTracksRevision == 1)
        metadata.replaceTracks([], from: .playlist)
        #expect(metadata.knownTrack(for: track.uri) == track)
        #expect(metadata.runtimeTracks.isEmpty)
        #expect(metadata.runtimeTracksRevision == 2)
    }

    @Test func exportRevisionIgnoresUnchangedAndShadowedWrites() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
        let preferred = HarnessFixtures.track(uri: "spotify:track:current", title: "Library label")
        let fallback = HarnessFixtures.track(uri: preferred.uri, title: "Search label")
        metadata.replaceTracks([preferred], from: .library)
        let revision = metadata.runtimeTracksRevision
        metadata.replaceTracks([preferred], from: .library)
        metadata.replaceTracks([fallback], from: .search)
        metadata.cacheTracks([fallback], from: .queue)
        metadata.cacheTracks([fallback], from: .nowPlaying)
        #expect(metadata.runtimeTracksRevision == revision)
        #expect(metadata.runtimeTracks == [preferred.uri: preferred])
        metadata.replaceTracks([], from: .library)
        #expect(metadata.runtimeTracksRevision == revision + 1)
        #expect(metadata.runtimeTracks == [fallback.uri: fallback])
    }

    @Test func exportCannotReadAnOlderAccountBeforeReset() {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
        let previous = HarnessFixtures.track(uri: "spotify:track:account-a")
        metadata.replaceTracks([previous], from: .library)
        session.update(accountEpoch: 2, isAvailable: true)
        #expect(metadata.runtimeTracks.isEmpty)
        let current = HarnessFixtures.track(uri: "spotify:track:account-b")
        metadata.replaceTracks([current], from: .playlist)
        #expect(metadata.runtimeTracks == [current.uri: current])
        #expect(metadata.runtimeTracks[previous.uri] == nil)
    }
}

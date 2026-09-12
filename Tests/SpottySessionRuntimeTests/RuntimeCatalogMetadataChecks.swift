import Foundation
import SpottyDomain
import Testing
@testable import SpottySessionRuntime

struct RuntimeCatalogMetadataTests {
    @Test func browsingOccurrenceChangesDoNotPublishUnchangedPlaybackLabels() {
        SessionRuntimeActor.sync {
            let metadata = RuntimeCatalogMetadata()
            let uri = "spotify:track:queued"
            metadata.retainTracks(from: .queue, for: [uri])
            var publications = 0
            metadata.changed = { publications += 1 }
            for index in 0..<2 {
                metadata.replaceTracks(
                    [
                        CatalogTrack(
                            id: "display-\(index)", uri: uri, title: "Track", artist: "Artist",
                            album: "Album", duration: 180, artworkURL: nil,
                            addedAt: Date(timeIntervalSince1970: Double(index)),
                            occurrenceUID: "server-\(index)")
                    ], from: .browsing)
            }
            #expect(publications == 1)
            #expect(metadata.playbackTracks.first?.id == uri)
            #expect(metadata.playbackTracks.first?.occurrenceUID == nil)
            #expect(metadata.playbackTracks.first?.addedAt == nil)
        }
    }

    @Test func browsingLabelsSurviveRouteReplacementForRetainedPlaybackEntities() {
        SessionRuntimeActor.sync {
            let metadata = RuntimeCatalogMetadata()
            let provisional = track("spotify:track:queued", title: "Provisional")
            let enriched = track(provisional.uri, title: "Complete catalog title")
            metadata.replaceTracks([provisional], from: .queue)
            metadata.retainTracks(from: .queue, for: [provisional.uri])
            metadata.replaceTracks([provisional], from: .nowPlaying)
            metadata.replaceTracks([enriched], from: .browsing)
            metadata.replaceTracks([], from: .browsing)
            #expect(metadata.knownTrack(for: provisional.uri) == enriched)
            #expect(metadata.playbackTracks == [enriched])
            metadata.replaceTracks([], from: .queue)
            #expect(metadata.playbackTracks == [enriched])
            metadata.retainTracks(from: .queue, for: [])
            #expect(metadata.playbackTracks == [enriched])
            metadata.replaceTracks([], from: .nowPlaying)
            #expect(metadata.knownTrack(for: provisional.uri) == nil)
            #expect(metadata.playbackTracks.isEmpty)
        }
    }

    @Test func browsingHydratesRetainedMissesWithoutRetainingUnrelatedPageRows() {
        SessionRuntimeActor.sync {
            let metadata = RuntimeCatalogMetadata()
            let queued = track("spotify:track:queued", title: "Queued")
            let unrelated = track("spotify:track:page-only", title: "Other page row")
            metadata.retainTracks(from: .queue, for: [queued.uri])
            metadata.replaceTracks([queued, unrelated], from: .browsing)
            #expect(metadata.playbackTracks == [queued])
            metadata.replaceTracks([], from: .browsing)
            #expect(metadata.knownTrack(for: queued.uri) == queued)
            #expect(metadata.knownTrack(for: unrelated.uri) == nil)
            metadata.reset()
            #expect(metadata.playbackTracks.isEmpty)
        }
    }

    private func track(_ uri: String, title: String) -> CatalogTrack {
        CatalogTrack(
            id: uri, uri: uri, title: title, artist: "Artist", album: "Album", duration: 180,
            artworkURL: nil, addedAt: nil)
    }
}

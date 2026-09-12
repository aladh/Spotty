import Foundation
import SpottyDomain
import Testing

struct CatalogOccurrenceTests {
    @Test func duplicateEntityRowsReceiveIndependentStableDisplayIDs() {
        let tracks = [track(id: "spotify:track:shared"), track(id: "spotify:track:shared"), track(id: "unique")]
        let first = CatalogTrackCollection(tracks: tracks)
        #expect(Set(first.tracks.map(\.id)).count == tracks.count)
        #expect(first.tracks.map(\.uri) == tracks.map(\.uri))
        #expect(first.tracks.map(\.title) == tracks.map(\.title))
        #expect(first.tracks[2] == tracks[2])
        #expect(CatalogTrackCollection(tracks: tracks).tracks == first.tracks)
        #expect(CatalogTrackCollection(tracks: first.tracks).tracks == first.tracks)
        let selected = [first.tracks[1].id, "removed"]
        #expect(TrackTableDisplayCache.prunedSelection(Set(selected), from: first.tracks) == [first.tracks[1].id])
        #expect(PlaylistMutationSelection.orderedTracks(selectedIDs: [first.tracks[1].id], in: first.tracks).count == 1)
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: first.tracks).isEmpty)
    }

    @Test func collectionWideAmbiguityCannotBeHiddenBySelectingOnlyOneRow() {
        let rows = CatalogTrackCollection(tracks: [
            track(id: "display-a", uid: "duplicate-uid"),
            track(id: "display-b", uid: "duplicate-uid"),
            track(id: "display-c", uid: "unique-uid"),
        ]).tracks
        #expect(rows.map(\.id) == ["display-a", "display-b", "display-c"])
        #expect(rows.map(\.occurrenceUID) == [nil, nil, "unique-uid"])
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: [rows[0]]).isEmpty)
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: rows) == ["unique-uid"])
    }

    @Test func uniqueIdentityAndOccurrenceMetadataAreUnchanged() {
        let original = track(id: "display-id", uid: "server-uid")
        let collection = CatalogTrackCollection(tracks: [original])
        #expect(collection.tracks == [original])
        #expect(collection.tracks.first?.addedAt == original.addedAt)
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: collection.tracks) == ["server-uid"])
    }

    private func track(id: String, uid: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: id, uri: "spotify:track:shared", title: id, artist: "Artist", album: "Album",
            duration: 180, artworkURL: nil, addedAt: Date(timeIntervalSince1970: 1_000), occurrenceUID: uid)
    }
}

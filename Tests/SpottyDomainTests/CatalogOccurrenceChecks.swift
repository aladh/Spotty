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

    @Test func generatedDisplayIDsAvoidExistingNamesAndPreserveAllOtherFields() {
        let rows = [
            track(id: "x", uid: "unique-a"), track(id: "x", uid: "unique-b"),
            track(id: "display:1:x:0"), track(id: "display:1:x:0:1"),
            track(id: "display:1:x:1"), track(id: "display:1:x:1:1"),
        ]
        let result = CatalogTrackCollection(tracks: rows).tracks
        #expect(Set(result.map(\.id)).count == rows.count)
        #expect(Array(result.dropFirst(2)) == Array(rows.dropFirst(2)))
        #expect(result.map(\.occurrenceUID) == rows.map(\.occurrenceUID))
        #expect(result.map(\.title) == rows.map(\.title))
        #expect(result.map(\.addedAt) == rows.map(\.addedAt))
        #expect(CatalogTrackCollection(tracks: result).tracks == result)
    }

    @Test func mixedOccurrenceIdentitiesRemainUniqueStableAndSafeForRemoval() {
        var seed: UInt64 = 0x51_07_79
        func next(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        let identities = ["", "x", "é", "👋", "row", "display:1:x:0", "display:1:x:0:1", "display:1:x:1"]
        for _ in 0..<100 {
            let rows = (0..<next(80)).map { _ in
                track(id: identities[next(identities.count)], uid: next(3) == 0 ? nil : "uid-\(next(20))")
            }
            let result = CatalogTrackCollection(tracks: rows).tracks
            #expect(Set(result.map(\.id)).count == rows.count)
            #expect(result.map(\.uri) == rows.map(\.uri))
            #expect(result.map(\.title) == rows.map(\.title))
            #expect(CatalogTrackCollection(tracks: rows).tracks == result)
            #expect(CatalogTrackCollection(tracks: result).tracks == result)
            for (source, normalized) in zip(rows, result) {
                if rows.filter({ $0.id == source.id }).count == 1 { #expect(normalized.id == source.id) }
                let expectedUID = source.occurrenceUID.flatMap { uid in
                    rows.filter { $0.occurrenceUID == uid }.count == 1 ? uid : nil
                }
                #expect(normalized.occurrenceUID == expectedUID)
            }
        }
    }

    private func track(id: String, uid: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: id, uri: "spotify:track:shared", title: id, artist: "Artist", album: "Album",
            duration: 180, artworkURL: nil, addedAt: Date(timeIntervalSince1970: 1_000), occurrenceUID: uid)
    }
}

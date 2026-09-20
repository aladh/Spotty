import SpottyDomain
import Testing

@Suite("Playlist content provenance")
struct CatalogPlaylistContentsChecks {
    @Test func collectionAndAccountMustBothMatchWithoutLosingOccurrences() throws {
        let track = CatalogTrack(
            id: "duplicate", uri: "spotify:track:one", title: "One", artist: "Artist", album: "Album", duration: 180,
            artworkURL: nil, addedAt: nil)
        let collection = CatalogTrackCollection(tracks: [track, track])
        let contents = try #require(
            CatalogPlaylistContents(uri: "spotify:playlist:one", accountEpoch: 7, collection: collection))
        let matching = contents.tracks(for: "spotify:playlist:one", accountEpoch: 7)
        #expect(matching.map(\.uri) == [track.uri, track.uri])
        #expect(Set(matching.map(\.id)).count == 2)
        #expect(matching.allSatisfy { $0.occurrenceUID == nil }, "display identity cannot invent mutation authority")
        #expect(contents.collection.version == collection.version)
        #expect(contents.tracks(for: "spotify:playlist:other", accountEpoch: 7).isEmpty)
        #expect(contents.tracks(for: "spotify:playlist:one", accountEpoch: 8).isEmpty)
        #expect(CatalogPlaylistContents(uri: "spotify:album:one", accountEpoch: 7, collection: collection) == nil)
        #expect(CatalogPlaylistContents(uri: nil, accountEpoch: 7, collection: collection) == nil)
    }
}

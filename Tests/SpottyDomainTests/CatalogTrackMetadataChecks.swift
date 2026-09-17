import Foundation
import SpottyDomain
import Testing

struct CatalogTrackMetadataTests {
    @Test(arguments: ["same", "uri", "artist", "album", "explicit"])
    func missingLinksBorrowOnlyMatchingIdentityWithoutChangingRowAuthority(change: String) {
        let known = track(uri: "spotify:track:one", id: "known")
        let explicitArtist = item("replacement-artist", kind: .artist)
        let explicitAlbum = item("replacement-album", kind: .album)
        let partial = CatalogTrack(
            id: "new-row", uri: change == "uri" ? "spotify:track:other" : known.uri,
            title: "Updated title", artist: change == "artist" ? "Another artist" : known.artist,
            album: change == "album" ? "Another album" : known.album, duration: 200, artworkURL: nil,
            addedAt: Date(timeIntervalSince1970: 5), artists: change == "explicit" ? [explicitArtist] : [],
            albumItem: change == "explicit" ? explicitAlbum : nil, occurrenceUID: "new-occurrence")
        let resolved = partial.fillingMissingLinks(from: known)
        #expect(resolved.id == partial.id && resolved.uri == partial.uri)
        #expect(resolved.occurrenceUID == partial.occurrenceUID && resolved.addedAt == partial.addedAt)
        #expect(resolved.title == partial.title && resolved.duration == partial.duration && resolved.artworkURL == nil)
        #expect(resolved.artist == partial.artist && resolved.album == partial.album)
        #expect(
            resolved.artists
                == (change == "explicit"
                    ? [explicitArtist] : (["uri", "artist"].contains(change) ? [] : known.artists)))
        #expect(
            resolved.albumItem == (change == "explicit" ? explicitAlbum : (change == "same" ? known.albumItem : nil)))
    }

    @Test func partialEntityUpdatesKeepExistingDestinationsWithoutChangingOccurrences() throws {
        let known = track(uri: "spotify:track:one", id: "display", uid: "server", addedAt: 1)
        let partial = CatalogTrack(
            id: "foreign", uri: known.uri, title: "Updated title", artist: known.artist, album: known.album,
            duration: 200, artworkURL: nil, addedAt: nil)
        let original = CatalogTrackCollection(tracks: [known])
        let updated = try #require(
            original.applyingMetadata([
                known.uri: CatalogTrackMetadata(track: partial, requestedURI: known.uri)
            ]))
        let row = try #require(updated.tracks.first)
        #expect(row.title == partial.title && row.duration == partial.duration)
        #expect(row.artists == known.artists && row.albumItem == known.albumItem)
        #expect(row.id == known.id && row.occurrenceUID == known.occurrenceUID && row.addedAt == known.addedAt)
        #expect(
            updated.applyingMetadata([known.uri: CatalogTrackMetadata(track: partial, requestedURI: known.uri)]) == nil)
    }

    @Test func enrichmentPreservesNormalizedOccurrencesAndSourceOrder() throws {
        let requested = "spotify:track:requested"
        let original = CatalogTrackCollection(tracks: [
            track(uri: requested, id: "duplicate", uid: "server-first", addedAt: 1),
            track(uri: requested, id: "duplicate", addedAt: 2),
            track(uri: "spotify:track:unrelated", id: "other"),
        ])
        let source = track(uri: "spotify:track:relinked", id: "foreign-row", uid: "foreign-uid", addedAt: 99)
        let metadata = CatalogTrackMetadata(track: source, requestedURI: requested)
        let updated = try #require(original.applyingMetadata([requested: metadata]))

        #expect(updated.version != original.version)
        #expect(updated.tracks.map(\.uri) == original.tracks.map(\.uri))
        #expect(updated.tracks.map(\.id) == original.tracks.map(\.id))
        #expect(updated.tracks.map(\.occurrenceUID) == ["server-first", nil, nil])
        #expect(updated.tracks.map(\.addedAt) == original.tracks.map(\.addedAt))
        #expect(Set(updated.tracks.map(\.id)).count == 3)
        #expect(updated.tracks[2] == original.tracks[2])
        for row in updated.tracks.prefix(2) {
            #expect(row.title == source.title)
            #expect(row.artist == source.artist)
            #expect(row.album == source.album)
            #expect(row.duration == source.duration)
            #expect(row.artworkURL == source.artworkURL)
            #expect(row.artists == source.artists)
            #expect(row.albumItem == source.albumItem)
        }
        #expect(original.tracks.first?.title == "duplicate")
    }

    @Test func identicalUnrelatedAndMismatchedUpdatesLeaveTheCollectionUnchanged() {
        let row = track(uri: "spotify:track:one", id: "row", uid: "server", addedAt: 1)
        let collection = CatalogTrackCollection(tracks: [row])
        let version = collection.version
        let foreign = track(uri: "spotify:track:other", id: "foreign")
        let sameMetadata = CatalogTrack(
            id: "different-display", uri: row.uri, title: row.title, artist: row.artist,
            album: row.album, duration: row.duration, artworkURL: row.artworkURL, addedAt: nil,
            artists: row.artists, albumItem: row.albumItem, occurrenceUID: "different-server")
        let foreignMetadata = CatalogTrackMetadata(track: foreign, requestedURI: foreign.uri)

        for updates: [String: CatalogTrackMetadata] in [
            [:],
            [foreign.uri: foreignMetadata],
            [row.uri: foreignMetadata],
            [row.uri: CatalogTrackMetadata(track: sameMetadata, requestedURI: row.uri)],
        ] {
            #expect(collection.applyingMetadata(updates) == nil)
            #expect(collection.version == version)
            #expect(collection.tracks == [row])
        }
    }

    @Test func serializedMetadataCannotExportRowAuthority() throws {
        let row = track(uri: "spotify:track:one", id: "display", uid: "server", addedAt: 1)
        let metadata = CatalogTrackMetadata(track: row, requestedURI: row.uri)
        let data = try JSONEncoder().encode(metadata)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(encoded["id"] == nil)
        #expect(encoded["occurrenceUID"] == nil)
        #expect(encoded["addedAt"] == nil)
        #expect(try JSONDecoder().decode(CatalogTrackMetadata.self, from: data) == metadata)
    }

    private func track(uri: String, id: String, uid: String? = nil, addedAt: TimeInterval? = nil) -> CatalogTrack {
        CatalogTrack(
            id: id, uri: uri, title: id, artist: "Artist \(id)", album: "Album \(id)",
            duration: Double(id.count), artworkURL: URL(string: "https://example.invalid/\(id).jpg"),
            addedAt: addedAt.map { Date(timeIntervalSince1970: $0) },
            artists: [item("artist-\(id)", kind: .artist)],
            albumItem: item("album-\(id)", kind: .album), occurrenceUID: uid)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id,
            subtitle: "", artworkURL: nil, kind: kind)
    }
}

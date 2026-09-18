import Testing
import SpottyDomain
@testable import SpottyCore

@Suite("Search metadata")
@MainActor
struct SearchMetadataTests {
    @Test
    func successfulSectionsReplaceMetadataWhilePendingAndFailedSectionsRetainIt() async throws {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let response = HarnessClock.parked()
        let store = SearchStore(provider: provider, metadata: metadata, session: session, clock: HarnessClock.parked())
        let album = item(.album, id: "album", title: "Search album")
        let artist = item(.artist, id: "artist", title: "Search artist")
        let playlist = item(.playlist, id: "playlist", title: "Search playlist")
        let libraryAlbum = item(.album, id: "album", title: "Library album")
        let homeArtist = item(.artist, id: "artist", title: "Home artist")
        let nextArtist = item(.artist, id: "next", title: "Next artist")
        let nextAlbum = item(.album, id: "next", title: "Next album")
        metadata.replaceItems([libraryAlbum], from: .library)
        metadata.replaceItems([homeArtist], from: .home)
        provider.onSearchTracks = { _, _ in [] }
        provider.onSearchAlbums = { _, _ in [album] }
        provider.onSearchArtists = { _, _ in [artist] }
        provider.onSearchPlaylists = { _, _ in [playlist] }
        await store.search("query")
        for original in [album, artist, playlist] { #expect(metadata.knownItem(for: original.uri) == original) }

        provider.onSearchAlbums = { _, _ in [] }
        provider.onSearchArtists = { _, _ in [nextArtist] }
        provider.onSearchPlaylists = { _, _ in
            try await response.sleep(seconds: 1)
            throw HarnessFailure.unavailable
        }
        let retry = Task { await store.search("query") }
        defer { response.releaseAll() }
        try await requireEventually {
            store.albums.isEmpty && store.artists == [nextArtist] && response.waiterCount == 1
        }
        #expect(metadata.knownItem(for: album.uri) == libraryAlbum, "An empty success restores lower-priority labels")
        #expect(metadata.knownItem(for: artist.uri) == homeArtist, "A replacement removes the retired search item")
        #expect(metadata.knownItem(for: nextArtist.uri) == nextArtist)
        #expect(metadata.knownItem(for: playlist.uri) == playlist, "Pending siblings keep their metadata")
        response.releaseAll()
        await retry.value
        #expect(store.playlists == [playlist] && store.errors[.playlists] != nil)
        #expect(metadata.knownItem(for: playlist.uri) == playlist, "Failed siblings keep their retained metadata")

        provider.onSearchAlbums = { _, _ in [nextAlbum] }
        provider.onSearchArtists = { _, _ in [] }
        provider.onSearchPlaylists = { _, _ in [] }
        await store.search("query")
        #expect(store.errors.isEmpty)
        #expect(metadata.knownItem(for: album.uri) == libraryAlbum)
        #expect(metadata.knownItem(for: artist.uri) == homeArtist)
        #expect(metadata.knownItem(for: nextArtist.uri) == nil)
        #expect(metadata.knownItem(for: playlist.uri) == nil)
        #expect(metadata.knownItem(for: nextAlbum.uri) == nextAlbum)
    }

    private func item(_ kind: CatalogItem.Kind, id: String, title: String) -> CatalogItem {
        let uri = "spotify:\(kind.rawValue.lowercased()):\(id)"
        return CatalogItem(id: uri, uri: uri, title: title, subtitle: "", artworkURL: nil, kind: kind)
    }
}

import SpottyRuntimeContracts
@testable import SpottyGateway

extension HarnessFixtures {
    /// Typed fixture providers declare one complete collection, without emulating wire paging.
    /// Live envelope discrimination and pagination use the transport-backed gateway suites.
    static func playlistSnapshot(_ value: PathfinderPlaylistUnion) async throws -> CatalogPlaylistSnapshot {
        let collection = try await CompletePlaylist.collect { _ in
            try ValidatedCatalogPage(
                header: value, typename: "Playlist", expectedType: "Playlist", uri: value.uri,
                requestedURI: value.uri ?? "spotify:playlist:fixture", items: value.content?.items,
                totalCount: value.content?.items?.count)
        }
        return CatalogMapping.playlist(collection)
    }

    static func albumSnapshot(_ value: PathfinderAlbumUnion) async throws -> CatalogAlbumSnapshot {
        let collection = try await CompleteAlbum.collect { _ in
            try ValidatedCatalogPage(
                header: value, typename: "Album", expectedType: "Album", uri: value.uri,
                requestedURI: value.uri ?? "spotify:album:fixture", items: value.tracksV2?.items,
                totalCount: value.tracksV2?.items?.count)
        }
        return CatalogMapping.album(collection)
    }
}

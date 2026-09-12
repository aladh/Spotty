import SpottyRuntimeContracts

nonisolated struct UnavailablePlaylistMutations: PlaylistMutating {
    func addToPlaylist(playlistId _: String, trackUris: [String]) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }

    func removeFromPlaylist(playlistId _: String, uids: [String]) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }
}

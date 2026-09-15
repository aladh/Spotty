import SpottyRuntimeContracts

nonisolated struct UnavailablePlaylistMutations: PlaylistMutating {
    func addToPlaylist(playlistId _: String, trackUris _: [String], context _: PlaylistMutationContext) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }

    func removeFromPlaylist(playlistId _: String, uids _: [String], context _: PlaylistMutationContext) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }
}

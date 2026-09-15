/// Presentation submits the account rendered with an action; the runtime owns admission.
public protocol PlaylistMutating: Sendable {
    func addToPlaylist(playlistId: String, trackUris: [String], context: PlaylistMutationContext) async throws
    func removeFromPlaylist(playlistId: String, uids: [String], context: PlaylistMutationContext) async throws
}

/// The gateway accepts only authorization issued at the runtime's account boundary.
package protocol PlaylistMutationDispatching: Sendable {
    func addToPlaylist(
        playlistId: String, trackUris: [String], authorization: PlaylistMutationAuthorization
    ) async throws
    func removeFromPlaylist(
        playlistId: String, uids: [String], authorization: PlaylistMutationAuthorization
    ) async throws
}

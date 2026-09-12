import Foundation
import SpottyRuntimeContracts

/// The desktop submits the account identity it rendered. The raw Spotify port never accepts
/// an unstamped request from production presentation, including a deferred menu action.
package struct AccountScopedPlaylistMutations: PlaylistMutating {
    private let source: any PlaylistMutating
    private let admission: PlaylistMutationAdmission

    package init(source: any PlaylistMutating, admission: PlaylistMutationAdmission) {
        self.source = source
        self.admission = admission
    }

    package func addToPlaylist(playlistId: String, trackUris: [String]) async throws {
        throw PlaylistMutationFailure.rejected
    }

    package func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        throw PlaylistMutationFailure.rejected
    }

    package func addToPlaylist(
        playlistId: String, trackUris: [String], context: PlaylistMutationContext
    ) async throws {
        let authorized = try admission.authorize(context)
        try await source.addToPlaylist(playlistId: playlistId, trackUris: trackUris, context: authorized)
    }

    package func removeFromPlaylist(
        playlistId: String, uids: [String], context: PlaylistMutationContext
    ) async throws {
        let authorized = try admission.authorize(context)
        try await source.removeFromPlaylist(playlistId: playlistId, uids: uids, context: authorized)
    }
}

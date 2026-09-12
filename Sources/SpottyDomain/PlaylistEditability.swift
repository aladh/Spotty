import Foundation

/// Ownership comparison for playlist writes. Spotty only advertises add/remove when the
/// signed-in profile URI matches the playlist owner; collaborative or stale permission
/// changes stay a typed Spotify rejection rather than a guessed capability.
public enum PlaylistEditability: Sendable {
    /// Canonical `spotify:user:` URI, or `nil` when the input cannot identify a user.
    public static func userURI(uri: String?, username: String?) -> String? {
        if let uri, let normalized = normalizeUserURI(uri) {
            return normalized
        }
        return username.flatMap { normalizeUserURI("spotify:user:\($0)") }
    }

    public static func normalizeUserURI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = SpotifyURI.id(from: trimmed, kind: "user") {
            return "spotify:user:\(id)"
        }
        if !trimmed.contains(":") {
            return "spotify:user:\(trimmed)"
        }
        return nil
    }

    public static func canJustifyEdit(playlistOwnerURI: String?, profileURI: String?) -> Bool {
        guard let owner = playlistOwnerURI.flatMap(normalizeUserURI),
            let profile = profileURI.flatMap(normalizeUserURI)
        else {
            return false
        }
        return owner == profile
    }

    public static func editablePlaylists(_ items: [CatalogItem], profileURI: String?) -> [CatalogItem] {
        items.filter { item in
            item.kind == .playlist
                && canJustifyEdit(playlistOwnerURI: item.ownerURI, profileURI: profileURI)
        }
    }
}

/// Occurrence-safe selection for playlist mutations. Display IDs select rows; only the explicit
/// server occurrence UID can identify a removable playlist occurrence. Track URIs may repeat.
public enum PlaylistMutationSelection: Sendable {
    /// Selected rows in `tracks` order. A `Set` of IDs cannot emit the same occurrence twice.
    public static func orderedTracks(
        selectedIDs: Set<String>,
        in tracks: [CatalogTrack]
    ) -> [CatalogTrack] {
        tracks.filter { selectedIDs.contains($0.id) }
    }

    public static func addURIs(from tracks: [CatalogTrack]) -> [String] {
        tracks.map(\.uri).filter { !$0.isEmpty }
    }

    /// Missing and ambiguous UIDs cannot authorize removal. A generated display ID must never
    /// be promoted to a server occurrence merely because it differs from the requested URI.
    public static func occurrenceIDsForRemoval(from tracks: [CatalogTrack]) -> [String] {
        let counts = Dictionary(tracks.compactMap(\.occurrenceUID).map { ($0, 1) }, uniquingKeysWith: +)
        return tracks.compactMap { track in
            guard let uid = track.occurrenceUID, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                uid != track.uri, counts[uid] == 1
            else { return nil }
            return uid
        }
    }

    public static func canAdd(isTargetEditable: Bool, uris: [String]) -> Bool {
        isTargetEditable && !uris.isEmpty
    }

    public static func canRemove(isPlaylistEditable: Bool, occurrenceIDs: [String]) -> Bool {
        isPlaylistEditable && !occurrenceIDs.isEmpty
    }
}

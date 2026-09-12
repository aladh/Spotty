import Testing
import SpottyDomain
import Foundation

@Suite("Playlist Editability")
struct PlaylistEditabilityTests {
    @Test
    func testPlaylistEditability() {
        func track(id: String, uri: String, occurrenceUID: String? = nil) -> CatalogTrack {
            CatalogTrack(
                id: id,
                uri: uri,
                title: id,
                artist: "",
                album: "",
                duration: 1,
                artworkURL: nil,
                addedAt: nil,
                occurrenceUID: occurrenceUID
            )
        }

        func playlist(uri: String, title: String, ownerURI: String?) -> CatalogItem {
            CatalogItem(
                id: uri,
                uri: uri,
                title: title,
                subtitle: "Owner",
                artworkURL: nil,
                kind: .playlist,
                ownerURI: ownerURI
            )
        }

        do {
            #expect(
                (PlaylistEditability.userURI(uri: "spotify:user:Ada", username: "ignored")) == ("spotify:user:Ada"),
                "profile URI prefers the explicit user URI")
            #expect(
                (PlaylistEditability.userURI(uri: nil, username: "Ada")) == ("spotify:user:Ada"),
                "username synthesizes a user URI without changing identifier case")
            #expect(
                (PlaylistEditability.userURI(uri: "spotify:track:abc", username: nil)) == nil,
                "a track URI is not a user identity")
            #expect((PlaylistEditability.normalizeUserURI("   ")) == nil, "an empty identity is not a user URI")
            #expect(
                (PlaylistEditability.canJustifyEdit(
                    playlistOwnerURI: "spotify:user:me",
                    profileURI: "spotify:user:me"
                )) == true, "matching owner and profile justify a write")
            #expect(
                (PlaylistEditability.canJustifyEdit(
                    playlistOwnerURI: "spotify:user:Ada",
                    profileURI: "spotify:user:Ada"
                )) == true, "identical mixed-case owner and profile remain editable")
            #expect(
                (!PlaylistEditability.canJustifyEdit(
                    playlistOwnerURI: "spotify:user:Ada",
                    profileURI: "spotify:user:ada"
                )) == true, "case-only owner and profile differences are not editable")
            #expect(
                (!PlaylistEditability.canJustifyEdit(
                    playlistOwnerURI: PlaylistEditability.userURI(uri: nil, username: "Ada"),
                    profileURI: "spotify:user:ada"
                )) == true, "synthesized username case must match the profile URI exactly")
            #expect(
                (!PlaylistEditability.canJustifyEdit(
                    playlistOwnerURI: "spotify:user:them",
                    profileURI: "spotify:user:me"
                )) == true, "someone else’s playlist is not advertised as editable")
            #expect(
                (!PlaylistEditability.canJustifyEdit(playlistOwnerURI: nil, profileURI: "spotify:user:me")) == true,
                "missing owner metadata is not treated as editable")
            #expect(
                (!PlaylistEditability.canJustifyEdit(playlistOwnerURI: "spotify:user:me", profileURI: nil)) == true,
                "missing profile metadata is not treated as editable")

            let items = [
                playlist(uri: "spotify:playlist:mine", title: "Mine", ownerURI: "spotify:user:me"),
                playlist(uri: "spotify:playlist:theirs", title: "Theirs", ownerURI: "spotify:user:them"),
                CatalogItem(
                    id: "spotify:album:one",
                    uri: "spotify:album:one",
                    title: "Album",
                    subtitle: "",
                    artworkURL: nil,
                    kind: .album,
                    ownerURI: "spotify:user:me"
                ),
                playlist(uri: "spotify:playlist:unknown", title: "Unknown", ownerURI: nil),
            ]
            #expect(
                (PlaylistEditability.editablePlaylists(items, profileURI: "spotify:user:me").map(\.uri))
                    == (["spotify:playlist:mine"]), "editable targets are owned library playlists only")
            #expect(
                (PlaylistEditability.editablePlaylists(items, profileURI: nil).map(\.uri)) == ([]),
                "no profile means no writable targets")
        }

        do {
            let duplicateURI = "spotify:track:dup"
            let otherURI = "spotify:track:other"
            let rows = [
                track(id: "uid-a", uri: duplicateURI, occurrenceUID: "uid-a"),
                track(id: "uid-b", uri: duplicateURI, occurrenceUID: "uid-b"),
                track(id: "uid-c", uri: otherURI, occurrenceUID: "uid-c"),
                track(id: duplicateURI, uri: duplicateURI),
            ]
            let selected = PlaylistMutationSelection.orderedTracks(
                selectedIDs: ["uid-b", "uid-a", "uid-b", duplicateURI],
                in: rows
            )
            #expect(
                (selected.map(\.id)) == (["uid-a", "uid-b", duplicateURI]),
                "selection follows playlist order and drops repeated IDs")
            #expect(
                (PlaylistMutationSelection.addURIs(from: Array(selected.prefix(2)))) == ([duplicateURI, duplicateURI]),
                "batch add keeps duplicate URIs from distinct occurrences")
            #expect(
                (PlaylistMutationSelection.occurrenceIDsForRemoval(from: Array(selected.prefix(2))))
                    == (["uid-a", "uid-b"]), "removal uses Pathfinder UIDs, never the shared track URI")
            #expect(
                (PlaylistMutationSelection.occurrenceIDsForRemoval(from: [rows[3]])) == ([]),
                "a URI-as-id row is not a removable occurrence")
            #expect(
                (PlaylistMutationSelection.occurrenceIDsForRemoval(from: selected)) == (["uid-a", "uid-b"]),
                "mixed UID and URI-as-id selection removes only occurrence UIDs")
            #expect(
                (PlaylistMutationSelection.canAdd(isTargetEditable: true, uris: [duplicateURI])) == true,
                "add requires an editable target and at least one URI")
            #expect(
                (!PlaylistMutationSelection.canAdd(isTargetEditable: false, uris: [duplicateURI])) == true,
                "add is refused for a read-only target")
            #expect(
                (PlaylistMutationSelection.canRemove(isPlaylistEditable: true, occurrenceIDs: ["uid-a"])) == true,
                "remove requires an editable playlist and occurrence UIDs")
            #expect(
                (!PlaylistMutationSelection.canRemove(isPlaylistEditable: false, occurrenceIDs: ["uid-a"])) == true,
                "read-only playlists cannot route destructive removal")
        }
    }

    @Test func displayIDsNeverSubstituteForUnambiguousServerOccurrences() {
        func track(_ id: String, uid: String?) -> CatalogTrack {
            CatalogTrack(
                id: id, uri: "spotify:track:duplicate", title: "Duplicate", artist: "Artist", album: "Album",
                duration: 1, artworkURL: nil, addedAt: nil, occurrenceUID: uid)
        }
        let rows = [
            track("display-a", uid: "server-a"),
            track("display-b", uid: nil),
            track("display-c", uid: "ambiguous"),
            track("display-d", uid: "ambiguous"),
            track("display-e", uid: "spotify:track:duplicate"),
            track("display-f", uid: "  "),
        ]
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: rows) == ["server-a"])
        #expect(
            PlaylistMutationSelection.orderedTracks(selectedIDs: ["display-b"], in: rows).map(\.id) == ["display-b"])
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: [rows[1]]).isEmpty)
    }
}

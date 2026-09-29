import Testing
import SpottyDomain

@Suite("Spotify URI")
struct SpotifyURITests {
    @Test(arguments: ["track", "album", "artist", "playlist", "user"])
    func emptyURIComponentsAreRejected(kind: String) {
        let valid = "spotify:\(kind):entity"
        #expect(SpotifyURI.id(from: valid) == "entity")
        #expect(SpotifyURI.id(from: valid, kind: kind) == "entity")
        for malformed in [":" + valid, valid + ":", "spotify::\(kind):entity", "spotify:\(kind)::entity"] {
            #expect(SpotifyURI.id(from: malformed) == nil)
            #expect(SpotifyURI.id(from: malformed, kind: kind) == nil)
        }
    }

    @Test
    func legacyURIParsingKeepsCompleteComponents() {
        #expect(SpotifyURI.id(from: "spotify:user:alice:playlist:collection") == "collection")
        #expect(SpotifyURI.id(from: "spotify:user:alice:playlist:collection", kind: "playlist") == nil)
        for malformed in ["spotify:user::playlist:collection", "spotify:user:alice:playlist:"] {
            #expect(SpotifyURI.id(from: malformed) == nil)
        }
    }

    @Test
    func identityMatchesRequestedKind() {
        #expect(
            (SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"))
                == ("37i9dQZF1DXcBWIGoYBM5M"), "kind-matched playlist uri yields its id")
        #expect(
            (SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist")) == nil,
            "folder uris never pass as playlists")
        #expect(
            (SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist")) == nil, "a mismatched kind is refused")
        #expect(
            (SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789")) == ("xyz789"),
            "kind-free parsing takes the last component")
    }
}

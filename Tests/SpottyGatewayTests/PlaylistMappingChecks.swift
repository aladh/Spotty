import Foundation
import Testing
import SpottyDomain
@testable import SpottyGateway

private func decodePlaylist(_ json: String) throws -> PathfinderPlaylist {
    try JSONDecoder().decode(PathfinderPlaylist.self, from: Data(json.utf8))
}

private func decodePlaylistUnion(_ json: String) throws -> PathfinderPlaylistUnion {
    try JSONDecoder().decode(PathfinderPlaylistUnion.self, from: Data(json.utf8))
}

private let ownedLibraryJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
    """
private let foreignLibraryJSON = """
    {"uri":"spotify:playlist:foreign","name":"Foreign Mix","ownerV2":{"data":{"name":"Them","username":"them","uri":"spotify:user:them"}}}
    """
private let ownedContentsJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":2,"items":[{"uid":"uid-a","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """

@Suite("Playlist mapping")
struct PlaylistMappingChecks {
    @Test
    func playlistMappingPreservesOwnershipAndOccurrenceIdentity() throws {
        let owned = try decodePlaylist(ownedLibraryJSON)
        let mapped = CatalogMapping.item(from: owned)
        #expect((mapped?.ownerURI) == ("spotify:user:me"), "library playlist keeps owner URI")
        #expect((mapped?.subtitle) == ("Me"), "library playlist keeps the owner subtitle")

        let foreign = try decodePlaylist(foreignLibraryJSON)
        #expect(
            (CatalogMapping.item(from: foreign)?.ownerURI) == ("spotify:user:them"),
            "foreign playlist owner is preserved")

        let union = try decodePlaylistUnion(ownedContentsJSON)
        #expect(
            (CatalogMapping.ownerURI(from: union)) == ("spotify:user:me"),
            "open playlist owner URI is mapped from ownerV2")
        let tracks = union.content?.items?.compactMap(CatalogMapping.playlistTrack(from:)) ?? []
        #expect(
            (tracks.map(\.id)) == (["uid-a", "uid-b"]),
            "playlist rows use occurrence UIDs as CatalogTrack.id")
        #expect(
            (tracks.map(\.uri)) == (["spotify:track:dup", "spotify:track:dup"]),
            "duplicate rows keep the same track URI")
    }

}

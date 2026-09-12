import Foundation
import SpottyDomain
import Testing
@testable import SpottyGateway

struct CatalogOccurrenceIdentityTests {
    @Test func missingAndAmbiguousUIDsKeepDistinctStableBrowsableRows() throws {
        let entries = try decodeEntries(
            """
            [
              {"uid":"known","itemV2":{"data":{"uri":"spotify:track:duplicate","name":"Known"}}},
              {"itemV2":{"data":{"uri":"spotify:track:duplicate","name":"First unknown"}}},
              {"itemV2":{"data":{"uri":"spotify:track:duplicate","name":"Second unknown"}}},
              {"uid":"ambiguous","itemV2":{"data":{"uri":"spotify:track:duplicate","name":"Ambiguous one"}}},
              {"uid":"ambiguous","itemV2":{"data":{"uri":"spotify:track:duplicate","name":"Ambiguous two"}}}
            ]
            """)
        let tracks = CatalogMapping.playlistTracks(from: entries)
        #expect(tracks.count == 5)
        #expect(Set(tracks.map(\.id)).count == tracks.count)
        #expect(tracks.map(\.title) == ["Known", "First unknown", "Second unknown", "Ambiguous one", "Ambiguous two"])
        #expect(tracks.allSatisfy { $0.uri == "spotify:track:duplicate" })
        #expect(tracks.map(\.occurrenceUID) == ["known", nil, nil, nil, nil])
        #expect(CatalogMapping.playlistTracks(from: entries) == tracks)
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: tracks) == ["known"])
        let selected = PlaylistMutationSelection.orderedTracks(selectedIDs: [tracks[2].id], in: tracks)
        #expect(selected.count == 1)
        #expect(selected.first?.title == "Second unknown")
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: selected).isEmpty)
    }

    @Test func unsupportedDuplicateUIDAndGeneratedIDCollisionDoNotCreateAuthority() throws {
        let uri = "spotify:track:duplicate"
        let generatedID = "catalog:\(uri.utf8.count):\(uri):0"
        let entries = try decodeEntries(
            """
            [
              {"itemV2":{"data":{"uri":"\(uri)","name":"Unknown"}}},
              {"uid":"\(generatedID)","itemV2":{"data":{"uri":"spotify:track:other","name":"Server identity"}}},
              {"uid":"collision","itemV2":{"data":{"uri":"\(uri)","name":"Supported"}}},
              {"uid":"collision","itemV2":{"data":{"name":"Unsupported, no URI"}}}
            ]
            """)
        let tracks = CatalogMapping.playlistTracks(from: entries)
        #expect(tracks.count == 3)
        #expect(Set(tracks.map(\.id)).count == tracks.count)
        #expect(tracks[0].id != generatedID)
        #expect(tracks[0].occurrenceUID == nil)
        #expect(tracks[1].id == generatedID)
        #expect(tracks[1].occurrenceUID == generatedID)
        #expect(tracks[2].occurrenceUID == nil)
        #expect(PlaylistMutationSelection.occurrenceIDsForRemoval(from: [tracks[0], tracks[2]]).isEmpty)
    }

    private func decodeEntries(_ json: String) throws -> [PathfinderPlaylistItem] {
        try JSONDecoder().decode([PathfinderPlaylistItem].self, from: Data(json.utf8))
    }
}

import Foundation
import Testing
import SpottyDomain
@testable import SpottyGateway

@Suite("Catalog destination mapping")
struct CatalogDestinationMappingChecks {
    @Test func preservesArtistAndAlbumDestinations() throws {
        let data = Data(
            #"{"uri":"spotify:track:track","name":"Song","artists":{"items":[{"uri":"spotify:artist:first","profile":{"name":"First"}},{"uri":"spotify:artist:second","profile":{"name":"Second"}}]},"albumOfTrack":{"uri":"spotify:album:album","name":"Album"}}"#
                .utf8)
        let track = try JSONDecoder().decode(PathfinderTrack.self, from: data)
        let mapped = try #require(CatalogMapping.searchTrack(from: track))
        #expect(mapped.artists.map(\.uri) == ["spotify:artist:first", "spotify:artist:second"])
        #expect(mapped.artists.map(\.title) == ["First", "Second"])
        #expect(mapped.albumItem?.uri == "spotify:album:album")
        #expect(mapped.albumItem?.title == "Album")
        let entryData = Data("{\"uid\":\"one\",\"itemV2\":{\"data\":\(String(decoding: data, as: UTF8.self))}}".utf8)
        let entry = try JSONDecoder().decode(PathfinderPlaylistItem.self, from: entryData)
        let playlistTrack = try #require(CatalogMapping.playlistTrack(from: entry))
        #expect(playlistTrack.artists == mapped.artists)
        #expect(playlistTrack.albumItem == mapped.albumItem)
    }

    @Test func incompleteArtistDestinationsPreserveAllCredits() throws {
        let data = Data(
            #"{"uri":"spotify:track:track","name":"Song","artists":{"items":[{"uri":"spotify:artist:first","profile":{"name":"First"}},{"profile":{"name":"Second"}}]},"albumOfTrack":{"name":"Album"}}"#
                .utf8)
        let track = try JSONDecoder().decode(PathfinderTrack.self, from: data)
        let mapped = try #require(CatalogMapping.searchTrack(from: track))
        #expect(mapped.artists.isEmpty)
        #expect(mapped.artist == "First, Second")
    }
    @Test
    func uriLessHomeShelfIdentitiesSurviveInsertionAndEmptyFiltering() throws {
        func section(_ title: String, item: String?) -> String {
            let data =
                item.map { "\"uri\":\"spotify:playlist:\($0)\",\"name\":\"Mix\"" } ?? "\"__typename\":\"NotFound\""
            return """
                {"data":{"title":{"transformedLabel":"\(title)"}},"sectionItems":{"items":[
                {"content":{"__typename":"PlaylistResponseWrapper","data":{\(data)}}}]}}
                """
        }
        func mapped(_ sections: [String]) throws -> [CatalogSection] {
            let data = Data(
                "{\"sectionContainer\":{\"sections\":{\"items\":[\(sections.joined(separator: ","))]}}}".utf8)
            let home = try JSONDecoder().decode(PathfinderHome.self, from: data)
            return CatalogMapping.sections(from: home)
        }
        let first = section("First", item: "first")
        let second = section("Second", item: "second")
        let original = try mapped([first, second])
        let inserted = try mapped([section("New", item: "new"), first, second])
        let filtered = try mapped([section("New", item: nil), first, second])
        try #require(original.count == 2 && inserted.count == 3 && filtered.count == 2)
        #expect(original[0].id != original[1].id)
        #expect(Array(inserted.dropFirst()).map(\.id) == original.map(\.id))
        #expect(filtered.map(\.id) == original.map(\.id))
        #expect(filtered.map(\.title) == ["First", "Second"])
    }
}

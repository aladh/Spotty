import Foundation
import Testing
@testable import SpottyCore

@Suite("Catalog Navigation")
struct CatalogNavigationTests {
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
        #expect(mapped.artist.contains("First"))
        #expect(mapped.artist.contains("Second"))
    }

}

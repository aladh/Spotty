import Foundation
import SpottyDomain
import Testing
@testable import SpottyGateway

struct HomeRecommendationTests {
    @Test func playlistRecommendationsUseDescriptionsWhileLibraryItemsKeepOwnerCredits() throws {
        let source = Data(
            #"""
            {"__typename":"HomeResponsePayload","sectionContainer":{"sections":{"items":[{
              "uri":"spotify:section:recommendations","sectionItems":{"items":[
                {"content":{"__typename":"PlaylistResponseWrapper","data":{
                  "uri":"spotify:playlist:mix","name":"Daily Mix",
                  "description":"<a href=\"spotify:artist:fixture\">First Artist</a>, Friends &amp; Guests",
                  "ownerV2":{"data":{"name":"Spotify","uri":"spotify:user:spotify"}},
                  "images":{"items":[{"sources":[{"url":"https://example.test/mix.jpg"}]}]}}}},
                {"content":{"__typename":"PlaylistResponseWrapper","data":{
                  "uri":"spotify:playlist:blank","name":"Blank Description","description":" <br> &nbsp; ",
                  "ownerV2":{"data":{"name":"Listener"}}}}},
                {"content":{"__typename":"PlaylistResponseWrapper","data":{
                  "uri":"spotify:playlist:missing","name":"Missing Description"}}}
              ]}}]}}}
            """#.utf8)
        let home = try JSONDecoder().decode(PathfinderHome.self, from: source)
        let shelf = try #require(CatalogMapping.sections(from: home).first)
        #expect(shelf.items.map(\.title) == ["Daily Mix", "Blank Description", "Missing Description"])
        #expect(shelf.items.map(\.subtitle) == ["First Artist, Friends & Guests", "Listener", "Playlist"])
        let recommendation = try #require(shelf.items.first)
        #expect(recommendation.uri == "spotify:playlist:mix")
        #expect(recommendation.ownerURI == "spotify:user:spotify")
        #expect(recommendation.artworkURL?.absoluteString == "https://example.test/mix.jpg")
        guard case let .playlist(playlist) = home.sections.first?.items.first?.content else {
            Issue.record("The fixture must contain a playlist wrapper")
            return
        }
        let libraryItem = try #require(CatalogMapping.item(from: playlist))
        #expect(libraryItem.subtitle == "Spotify")
        #expect(libraryItem.id == recommendation.id)
        #expect(libraryItem.ownerURI == recommendation.ownerURI)
    }
}

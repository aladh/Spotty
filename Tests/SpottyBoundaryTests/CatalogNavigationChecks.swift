import Foundation
import Testing
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Catalog Navigation")
struct CatalogNavigationTests {
    @Test @MainActor
    func searchInteractionSurvivesDetailsButRetiresOnNewQueryOrAccount() {
        let navigation = CatalogNavigation()
        navigation.updateSelection(.destination(.search))
        let search = navigation.searchInteraction
        search.prepare(for: "first")
        search.filter = .songs
        search.songs.selection = ["selected"]
        search.songs.scrollOffset = 280
        navigation.updateSelection(.album("spotify:album:detail"))
        navigation.goBack()
        search.prepare(for: " first ")
        #expect(navigation.searchInteraction === search)
        #expect(search.filter == .songs)
        #expect(search.songs.selection == ["selected"])
        #expect(search.songs.scrollOffset == 280)
        search.prepare(for: "second")
        #expect(search.filter == .songs)
        #expect(search.songs.selection.isEmpty)
        #expect(search.songs.scrollOffset == 0)
        search.prepare(for: "")
        #expect(search.filter == .all)
        navigation.reset()
        #expect(navigation.searchInteraction !== search)
        #expect(navigation.searchInteraction.query.isEmpty)
    }

    @Test @MainActor
    func homePositionsSurviveNavigationButRetireWithTheAccount() {
        let navigation = CatalogNavigation()
        let home = navigation.homeInteraction
        let section = HomeInteractionState.SectionID(source: "section", ordinal: 0)
        home.scrollOffset = 320
        home.shelfScroll(for: section).offset = 410
        navigation.updateSelection(.playlist("spotify:playlist:detail"))
        navigation.goBack()
        #expect(navigation.homeInteraction === home)
        #expect(navigation.homeInteraction.scrollOffset == 320)
        #expect(navigation.homeInteraction.shelfScroll(for: section).offset == 410)
        #expect(CatalogNavigation().homeInteraction.scrollOffset == 0)
        navigation.reset()
        #expect(navigation.homeInteraction !== home)
        home.scrollOffset = 700
        home.shelfScroll(for: section).offset = 600
        #expect(navigation.homeInteraction.scrollOffset == 0)
        #expect(navigation.homeInteraction.shelfScroll(for: section).offset == 0)
    }

    @Test @MainActor
    func homeShelvesKeepSeparateRepeatedPositionsAndDiscardRemovedSections() {
        let home = HomeInteractionState()
        let first = HomeInteractionState.SectionID(source: "same", ordinal: 0)
        let repeatID = HomeInteractionState.SectionID(source: "same", ordinal: 1)
        let original = home.shelfScroll(for: first)
        original.offset = 210
        home.shelfScroll(for: repeatID).offset = 420
        home.retainShelves([first, repeatID])
        #expect(home.shelfScroll(for: first) === original)
        #expect(home.shelfScroll(for: repeatID).offset == 420)
        home.retainShelves([first])
        #expect(home.shelfScroll(for: first).offset == 210)
        #expect(home.shelfScroll(for: repeatID).offset == 0)
    }

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

}

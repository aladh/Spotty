import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

@Suite("Catalog Resource Links")
@MainActor
struct CatalogResourceLinkTests {
    @Test func supportedLinksNavigateWithoutPlaybackAndPreserveHistory() throws {
        let navigation = CatalogNavigation()
        #expect(navigation.open(try #require(URL(string: "spotify:playlist:0123AbCd"))))
        #expect(navigation.selection == .playlist("spotify:playlist:0123AbCd"))
        #expect(
            navigation.open(try #require(URL(string: "https://open.spotify.com/intl-en/album/AbCd0123?si=ignored"))))
        #expect(navigation.selection == .album("spotify:album:AbCd0123"))
        navigation.goBack()
        #expect(navigation.selection == .playlist("spotify:playlist:0123AbCd"))
        navigation.goForward()
        #expect(navigation.selection == .album("spotify:album:AbCd0123"))
        #expect(navigation.open(try #require(URL(string: "https://open.spotify.com/artist/aBc123"))))
        #expect(navigation.selection == .artist("spotify:artist:aBc123"))
    }

    @Test func unsupportedAndLookalikeLinksDoNotChangeNavigation() throws {
        let navigation = CatalogNavigation()
        for raw in [
            "https://open.spotify.com.evil.example/playlist/id", "https://user@open.spotify.com/album/id",
            "https://open.spotify.com:443/artist/id", "http://open.spotify.com/playlist/id",
            "spotify:track:AbCd", "spotify:playlist:abc:extra", "spotify:album:abc?command=play",
            "https://open.spotify.com/playlist/id/extra", "https://open.spotify.com/playlist/%2Fbad",
            "file:///playlist/id", "spotify:playlist:",
        ] {
            #expect(!navigation.open(try #require(URL(string: raw))), "\(raw) should be ignored")
            #expect(navigation.selection == .destination(.home))
            #expect(navigation.backHistory.isEmpty)
        }
    }

    @Test func interactionStateSurvivesRevisitsAndIsRetiredWithAccountNavigation() {
        let navigation = CatalogNavigation()
        let first = navigation.interactionState(for: "spotify:playlist:first")
        first.searchText = "needle"
        first.showsSearch = true
        first.selection = ["occurrence-one", "occurrence-two"]
        first.scrollOffset = 245
        first.sortOrder = [KeyPathComparator(\TrackTableRow.title)]
        _ = navigation.interactionState(for: "spotify:playlist:second")
        let revisited = navigation.interactionState(for: "spotify:playlist:first")
        #expect(revisited === first)
        #expect(revisited.searchText == "needle")
        #expect(revisited.showsSearch)
        #expect(revisited.selection == ["occurrence-one", "occurrence-two"])
        #expect(revisited.scrollOffset == 245)
        #expect(revisited.sortOrder.first?.keyPath == \TrackTableRow.title)
        navigation.reset()
        let replacement = navigation.interactionState(for: "spotify:playlist:first")
        #expect(replacement !== first)
        #expect(replacement.searchText.isEmpty)
        #expect(replacement.selection.isEmpty)
        #expect(replacement.scrollOffset == 0)
        #expect(replacement.sortOrder.first?.keyPath == \TrackTableRow.dateAddedSortValue)
        #expect(replacement.sortOrder.first?.order == .reverse)
    }
}

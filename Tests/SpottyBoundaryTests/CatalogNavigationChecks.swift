import Foundation
import Testing
@testable import SpottyCore
import SpottyDomain
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

    @Test @MainActor
    func homeShelfOffsetsSurviveInsertionAndRemoval() {
        func section(_ id: String, title: String) -> CatalogSection {
            CatalogSection(id: id, title: title, items: [])
        }
        let first = section("first", title: "First")
        let second = section("second", title: "Second")
        let state = HomeInteractionState()
        let original = CatalogDisplayOccurrence.identifying([first, second])
        state.shelfScroll(for: original[0].id).offset = 210
        state.shelfScroll(for: original[1].id).offset = 420
        let inserted = CatalogDisplayOccurrence.identifying([section("new", title: "New"), first, second])
        state.retainShelves(inserted.map(\.id))
        #expect(state.shelfScroll(for: inserted[0].id).offset == 0)
        #expect(state.shelfScroll(for: inserted[1].id).offset == 210)
        #expect(state.shelfScroll(for: inserted[2].id).offset == 420)
        let filtered = CatalogDisplayOccurrence.identifying([first, second])
        state.retainShelves(filtered.map(\.id))
        #expect(filtered.map(\.element.title) == ["First", "Second"])
        #expect(state.shelfScroll(for: filtered[0].id).offset == 210)
        #expect(state.shelfScroll(for: filtered[1].id).offset == 420)
    }

}

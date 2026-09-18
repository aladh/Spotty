import SpottyDomain
import Testing
@testable import SpottyCore

@MainActor
struct CatalogDisplayOccurrenceTests {
    @Test func repeatedDestinationsKeepIndependentCardsWithoutChangingTheirContent() {
        let items = [item("same", title: "Original"), item("same", title: "Revisited"), item("same:1")]
        let cards = CatalogDisplayOccurrence.identifying(items)
        #expect(cards.map(\.element) == items)
        #expect(cards.map(\.index) == [0, 1, 2])
        #expect(Set(cards.map(\.id)).count == items.count)
        #expect(cards[0].element.uri == cards[1].element.uri)

        let updated = CatalogDisplayOccurrence.identifying([item("new")] + items)
        #expect(Array(updated.dropFirst().map(\.id)) == cards.map(\.id))
        let renamed = CatalogDisplayOccurrence.identifying([items[0], item("same", title: "Updated"), items[2]])
        #expect(renamed.map(\.id) == cards.map(\.id))
        #expect(renamed[1].element.title == "Updated")
        let single = CatalogDisplayOccurrence.identifying([items[0]])
        #expect(single[0].id == cards[0].id, "adding a repeat must not replace the first card's view state")
    }

    @Test func repeatedSectionsKeepReturnedOrderAndPresentation() {
        let sections = [
            CatalogSection(id: "same", title: "Quick access", items: [item("first")]),
            CatalogSection(id: "same", title: "Shelf", items: [item("second")]),
        ]
        let displayed = CatalogDisplayOccurrence.identifying(sections)
        #expect(Set(displayed.map(\.id)).count == 2)
        #expect(displayed.map(\.element.title) == ["Quick access", "Shelf"])
        #expect(displayed.map { homeSectionPresentation(at: $0.index) } == [.quickAccess, .shelf])
    }

    @Test func searchRetainsAnExactRepeatedCardAnchorAndClearsItAtQueryAndAccountBoundaries() {
        let navigation = CatalogNavigation()
        navigation.updateSelection(.destination(.search))
        let search = navigation.searchInteraction
        search.prepare(for: "first")
        let cards = CatalogDisplayOccurrence.identifying([item("same"), item("same")])
        search.gridAnchors[.playlists] = cards[1].id
        navigation.updateSelection(.playlist("spotify:playlist:same"))
        navigation.goBack()
        search.prepare(for: " first ")
        #expect(search.gridAnchors[.playlists] == cards[1].id)
        #expect(search.gridAnchors[.playlists] != cards[0].id)
        search.prepare(for: "second")
        #expect(search.gridAnchors.isEmpty)
        search.gridAnchors[.playlists] = cards[1].id
        navigation.reset()
        #expect(navigation.searchInteraction.gridAnchors.isEmpty)
    }

    private func item(_ id: String, title: String? = nil) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:playlist:\(id)", title: title ?? id, subtitle: "Listener",
            artworkURL: nil, kind: .playlist)
    }
}

import Foundation
import SpottyDomain

/// Window-local positions survive navigation and retire with the account's navigation state.
/// Scroll updates are deliberately non-observable so they do not rebuild the Home content.
@MainActor
final class HomeInteractionState {
    typealias SectionID = CatalogDisplayOccurrence<CatalogSection>.ID
    var scrollOffset: CGFloat = 0
    private var shelves: [SectionID: NativeListScrollState] = [:]

    func shelfScroll(for section: SectionID) -> NativeListScrollState {
        if let retained = shelves[section] { return retained }
        let state = NativeListScrollState()
        shelves[section] = state
        return state
    }

    func retainShelves(_ sections: [SectionID]) {
        let retained = Set(sections)
        shelves = shelves.filter { retained.contains($0.key) }
    }
}

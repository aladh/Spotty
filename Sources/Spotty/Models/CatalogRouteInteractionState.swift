import Foundation
import Observation
import SpottyDomain

/// Window-local browsing state. The navigation owner retires it on account replacement.
@MainActor
@Observable
final class CatalogRouteInteractionState {
    var searchText = ""
    var showsSearch = false
    var selection: Set<CatalogTrack.ID> = []
    var visibleItemID: CatalogItem.ID?
    var sortOrder: [KeyPathComparator<TrackTableRow>]
    @ObservationIgnored var scrollOffset: CGFloat = 0

    init(isPlaylist: Bool = false) {
        sortOrder = isPlaylist ? [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)] : []
    }
}

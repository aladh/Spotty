import Foundation
import Observation
import SpottyDomain

enum SearchFilter: String, CaseIterable {
    case all = "All"
    case artists = "Artists"
    case songs = "Songs"
    case albums = "Albums"
    case playlists = "Playlists"

    var section: SearchStore.Section? {
        switch self {
        case .all: nil
        case .songs: .tracks
        case .artists: .artists
        case .albums: .albums
        case .playlists: .playlists
        }
    }
}

/// Window-local search interaction survives detail navigation, and retires with the account.
@MainActor
@Observable
final class SearchInteractionState {
    var filter = SearchFilter.all
    private(set) var query = ""
    private(set) var songs = CatalogRouteInteractionState()
    var selection: Set<String> = []
    private(set) var overviewScroll = NativeListScrollState()
    var gridAnchors: [SearchFilter: CatalogDisplayOccurrence<CatalogItem>.ID] = [:]

    func prepare(for term: String) {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != normalized else { return }
        query = normalized
        songs = CatalogRouteInteractionState()
        selection = []
        overviewScroll = NativeListScrollState()
        gridAnchors = [:]
        if normalized.isEmpty { filter = .all }
    }
}

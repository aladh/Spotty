import Foundation
import Observation
import SpottyDomain

/// Window-local navigation shared by sidebar, links, and history actions.
@MainActor
@Observable
final class CatalogNavigation {
    private(set) var model = MediaSelectionModel()
    var rawValue: String { model.rawValue }
    var searchText = ""
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    @ObservationIgnored private var routeInteractions: [String: CatalogRouteInteractionState] = [:]
    @ObservationIgnored private var interactionOrder: [String] = []

    var selection: SidebarSelection { model.selection }

    func interactionState(for uri: String) -> CatalogRouteInteractionState {
        interactionOrder.removeAll { $0 == uri }
        interactionOrder.append(uri)
        if let retained = routeInteractions[uri] { return retained }
        let state = CatalogRouteInteractionState(isPlaylist: uri.hasPrefix("spotify:playlist:"))
        routeInteractions[uri] = state
        if interactionOrder.count > 100 {
            routeInteractions[interactionOrder.removeFirst()] = nil
        }
        return state
    }

    /// Resource links navigate only; receiving a URL never authorizes playback.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let item = SpotifyResourceLink.item(from: url) else { return false }
        _ = select(item)
        return true
    }

    @discardableResult
    func select(_ item: CatalogItem) -> MediaSelectionModel.SelectionResult {
        var next = model
        let result = next.select(item)
        if result == .navigate { navigate(to: next) }
        return result
    }

    func updateSelection(_ selection: SidebarSelection?) {
        var next = model
        next.updateSelection(selection)
        navigate(to: next)
    }

    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(rawValue)
        model = MediaSelectionModel(rawValue: previous) ?? MediaSelectionModel()
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(rawValue)
        model = MediaSelectionModel(rawValue: next) ?? MediaSelectionModel()
    }

    func reset() {
        backHistory.removeAll()
        forwardHistory.removeAll()
        searchText = ""
        routeInteractions.removeAll()
        interactionOrder.removeAll()
        model = MediaSelectionModel()
    }

    private func navigate(to next: MediaSelectionModel) {
        guard next.selection != selection else {
            model = next
            return
        }
        backHistory.append(rawValue)
        if backHistory.count > 100 { backHistory.removeFirst() }
        forwardHistory.removeAll()
        model = next
    }
}

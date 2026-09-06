import Foundation
import Observation
import SpottyDomain

/// Window-local navigation shared by sidebar, links, and history actions.
@MainActor
@Observable
final class CatalogNavigation {
    private(set) var rawValue = MediaSelectionModel().rawValue
    var searchText = ""
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []

    var model: MediaSelectionModel { MediaSelectionModel(rawValue: rawValue) ?? MediaSelectionModel() }
    var selection: SidebarSelection { model.selection }

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
        rawValue = previous
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(rawValue)
        rawValue = next
    }

    func reset() {
        backHistory.removeAll()
        forwardHistory.removeAll()
        searchText = ""
        rawValue = MediaSelectionModel().rawValue
    }

    private func navigate(to next: MediaSelectionModel) {
        guard next.selection != selection else {
            rawValue = next.rawValue
            return
        }
        backHistory.append(rawValue)
        if backHistory.count > 100 { backHistory.removeFirst() }
        forwardHistory.removeAll()
        rawValue = next.rawValue
    }
}

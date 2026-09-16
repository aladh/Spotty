import SpottyDomain
import Foundation

struct MediaSelectionModel: RawRepresentable {
    enum SelectionResult: Equatable {
        case navigate
        case play(String)
    }

    private struct PersistedState: Codable {
        let selection: String
        let rememberedItem: RememberedItem?
    }

    private struct RememberedItem: Codable, Equatable {
        let uri: String
        let title: String
        let subtitle: String
        let artworkURL: String?
        let kind: String

        init(_ item: CatalogItem) {
            uri = item.uri
            title = item.title
            subtitle = item.subtitle
            artworkURL = item.artworkURL?.absoluteString
            kind = item.kind.rawValue
        }

        func catalogItem(matching uri: String, kind expectedKind: CatalogItem.Kind) -> CatalogItem? {
            guard self.uri == uri, kind == expectedKind.rawValue, !title.isEmpty else { return nil }
            return CatalogItem(
                id: SpotifyURI.id(from: uri) ?? uri,
                uri: uri,
                title: title,
                subtitle: subtitle,
                artworkURL: artworkURL.flatMap(URL.init(string:)),
                kind: expectedKind
            )
        }
    }

    private(set) var selection: SidebarSelection
    private var rememberedItem: RememberedItem?

    init(selection: SidebarSelection = .destination(.home)) {
        self.selection = selection
    }

    init?(rawValue: String) {
        if let data = rawValue.data(using: .utf8),
            let persisted = try? JSONDecoder().decode(PersistedState.self, from: data),
            let selection = SidebarSelection(rawValue: persisted.selection)
        {
            self.selection = selection
            rememberedItem = persisted.rememberedItem
        } else {
            selection = .destination(.home)
        }
    }

    var rawValue: String {
        let state = PersistedState(selection: selection.rawValue, rememberedItem: rememberedItem)
        guard let data = try? JSONEncoder().encode(state),
            let value = String(data: data, encoding: .utf8)
        else {
            return SidebarSelection.destination(.home).rawValue
        }
        return value
    }

    var diagnosticLabel: String { selection.diagnosticLabel }

    mutating func select(_ item: CatalogItem) -> SelectionResult {
        switch item.kind {
        case .playlist:
            remember(item, selection: .playlist(item.uri))
            return .navigate
        case .album:
            remember(item, selection: .album(item.uri))
            return .navigate
        case .artist:
            remember(item, selection: .artist(item.uri))
            return .navigate
        case .track, .unknown:
            return .play(item.uri)
        }
    }

    mutating func updateSelection(_ selection: SidebarSelection?) {
        let next = selection ?? .destination(.home)
        if next.mediaURI == nil || next.mediaURI != rememberedItem?.uri {
            rememberedItem = nil
        }
        self.selection = next
    }

    mutating func reset() {
        selection = .destination(.home)
        rememberedItem = nil
    }

    func item(
        uri: String,
        kind: CatalogItem.Kind,
        playlists: [CatalogItem] = [],
        metadataItem: CatalogItem?
    ) -> CatalogItem? {
        if kind == .playlist, let playlist = playlists.first(where: { $0.uri == uri }) {
            return playlist
        }
        if let metadataItem, metadataItem.uri == uri, metadataItem.kind == kind {
            return metadataItem
        }
        return rememberedItem?.catalogItem(matching: uri, kind: kind)
    }

    private mutating func remember(_ item: CatalogItem, selection: SidebarSelection) {
        rememberedItem = RememberedItem(item)
        self.selection = selection
    }
}

private extension SidebarSelection {
    var mediaURI: String? {
        switch self {
        case .destination: nil
        case let .playlist(uri), let .album(uri), let .artist(uri), let .discography(uri): uri
        }
    }
}

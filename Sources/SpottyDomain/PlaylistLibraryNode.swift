/// Server-ordered playlist library, retaining folders separately from playable catalog items.
public struct PlaylistLibraryNode: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let playlist: CatalogItem?
    public let children: [PlaylistLibraryNode]?

    public init(playlist: CatalogItem) {
        id = playlist.uri
        title = playlist.title
        self.playlist = playlist
        children = nil
    }

    public init(folderURI: String, title: String, children: [PlaylistLibraryNode]) {
        id = folderURI
        self.title = title
        playlist = nil
        self.children = children
    }

    public var playlists: [CatalogItem] {
        if let playlist { return [playlist] }
        return (children ?? []).flatMap(\.playlists)
    }

    /// Saved labels are useful for navigation, but historical ownership cannot enable editing.
    public var withoutOwnership: PlaylistLibraryNode {
        if let item = playlist {
            return PlaylistLibraryNode(
                playlist: CatalogItem(
                    id: item.id, uri: item.uri, title: item.title, subtitle: item.subtitle,
                    artworkURL: item.artworkURL, kind: item.kind))
        }
        return PlaylistLibraryNode(
            folderURI: id, title: title, children: (children ?? []).map(\.withoutOwnership))
    }

}

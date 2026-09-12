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

}

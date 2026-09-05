import SpottyDomain

/// Server-ordered playlist library, retaining folders separately from playable catalog items.
struct PlaylistLibraryNode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let playlist: CatalogItem?
    let children: [PlaylistLibraryNode]?

    init(playlist: CatalogItem) {
        id = playlist.uri
        title = playlist.title
        self.playlist = playlist
        children = nil
    }

    init(folderURI: String, title: String, children: [PlaylistLibraryNode]) {
        id = folderURI
        self.title = title
        playlist = nil
        self.children = children
    }

    var playlists: [CatalogItem] {
        if let playlist { return [playlist] }
        return (children ?? []).flatMap(\.playlists)
    }

    var folderSummary: String {
        let playlistCount = children?.filter { $0.playlist != nil }.count ?? 0
        let folderCount = children?.filter { $0.children != nil }.count ?? 0
        let playlists = "\(playlistCount) \(playlistCount == 1 ? "playlist" : "playlists")"
        guard folderCount > 0 else { return playlists }
        return "\(playlists), \(folderCount) \(folderCount == 1 ? "folder" : "folders")"
    }

    struct VisibleRow: Identifiable {
        let node: PlaylistLibraryNode
        let depth: Int
        var id: String { node.id }
    }

    static func visibleRows(_ nodes: [Self], expanded: Set<String>, depth: Int = 0) -> [VisibleRow] {
        nodes.flatMap { node in
            [VisibleRow(node: node, depth: depth)]
                + (expanded.contains(node.id)
                    ? visibleRows(node.children ?? [], expanded: expanded, depth: depth + 1) : [])
        }
    }
}

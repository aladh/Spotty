import SpottyDomain
import Testing
@testable import SpottyCore

@Suite("Playlist library presentation")
@MainActor
struct PlaylistLibraryTests {
    @Test func visibleRowsPreserveServerOrderAndNestedExpansion() {
        func playlist(_ id: String, _ title: String) -> PlaylistLibraryNode {
            PlaylistLibraryNode(
                playlist: CatalogItem(
                    id: id, uri: "spotify:playlist:\(id)", title: title, subtitle: "", artworkURL: nil, kind: .playlist)
            )
        }
        let nested = "spotify:user:fixture:folder:two"
        let tree = [
            playlist("z", "Zulu"),
            PlaylistLibraryNode(
                folderURI: "spotify:user:fixture:folder:one", title: "Quick Lists",
                children: [
                    playlist("child", "Child"),
                    PlaylistLibraryNode(folderURI: nested, title: "Nested", children: [playlist("deep", "Deep")]),
                ]),
            playlist("a", "Alpha"),
        ]
        #expect(tree[1].folderSummary == "1 playlist, 1 folder")
        let collapsed = PlaylistLibraryNode.visibleRows(tree, expanded: [])
        #expect(collapsed.map(\.node.title) == ["Zulu", "Quick Lists", "Alpha"])
        let expanded = PlaylistLibraryNode.visibleRows(tree, expanded: [tree[1].id, nested])
        #expect(expanded.map(\.depth) == [0, 0, 1, 1, 2, 0])
        #expect(expanded.map(\.node.title) == ["Zulu", "Quick Lists", "Child", "Nested", "Deep", "Alpha"])
    }
}

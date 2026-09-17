import Foundation
import SQLite3
import SpottyCatalogStorage
import SpottyDomain
import Testing

struct PlaylistLibraryStorageChecks {
    @Test func completeTreeSurvivesReopenAndOlderOrInvalidWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let record = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await original.replacePlaylistLibrary(record, scope: original.scope)
        try await original.replacePlaylistLibrary(
            CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: Date(timeIntervalSince1970: 99)), scope: original.scope)
        await #expect(throws: CatalogStorageError.invalidInput) {
            try await original.replacePlaylistLibrary(
                CatalogPlaylistLibraryRecord(
                    nodes: [.init(folderURI: "", title: "Invalid", children: [])],
                    fetchedAt: Date(timeIntervalSince1970: 101)), scope: original.scope)
        }
        try await original.close(scope: original.scope)
        let reopened = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        #expect(try await reopened.playlistLibrary(scope: reopened.scope) == record)
        let empty = CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: Date(timeIntervalSince1970: 102))
        try await reopened.replacePlaylistLibrary(empty, scope: reopened.scope)
        #expect(try await reopened.playlistLibrary(scope: reopened.scope) == empty)
        try await reopened.retire(scope: reopened.scope)
        await #expect(throws: CatalogStorageError.retired) { try await reopened.playlistLibrary(scope: reopened.scope) }
        let fresh = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        #expect(try await fresh.playlistLibrary(scope: fresh.scope) == nil)
        try await fresh.retire(scope: fresh.scope)
    }

    @Test func accountAndSizeBoundsPreserveThePreviousCompleteTree() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let record = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await catalog.replacePlaylistLibrary(record, scope: catalog.scope)
        let other = PersistentCatalog(rootDirectory: root, accountID: "other")
        #expect(try await other.playlistLibrary(scope: other.scope) == nil)
        await #expect(throws: CatalogStorageError.staleScope) { try await catalog.playlistLibrary(scope: other.scope) }
        let excessive = Array(repeating: tree()[0], count: CatalogPlaylistLibraryRecord.maximumNodes + 1)
        let huge = [
            PlaylistLibraryNode(
                folderURI: "folder:huge",
                title: String(repeating: "x", count: CatalogPlaylistLibraryRecord.maximumBytes), children: [])
        ]
        var deep = tree()
        for index in 0..<34 { deep = [.init(folderURI: "folder:\(index)", title: "Folder", children: deep)] }
        for nodes in [excessive, huge, deep] {
            await #expect(throws: CatalogStorageError.invalidInput) {
                try await catalog.replacePlaylistLibrary(
                    CatalogPlaylistLibraryRecord(nodes: nodes, fetchedAt: Date(timeIntervalSince1970: 101)),
                    scope: catalog.scope)
            }
            #expect(try await catalog.playlistLibrary(scope: catalog.scope) == record)
        }
        try await other.retire(scope: other.scope)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func versionOneUpgradeKeepsExistingCollectionsAndRejectsCorruptLibrary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        _ = try await original.replaceCollection(
            CatalogCollectionWrite(
                key: "album", occurrences: [], completeness: .complete,
                fetchedAt: Date(timeIntervalSince1970: 100)), scope: original.scope)
        try await original.close(scope: original.scope)
        let directory = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.count == 64 })
        let file = directory.appendingPathComponent("catalog.sqlite")
        try executeSQL("DROP TABLE playlist_library; PRAGMA user_version=1", file: file)
        let upgraded = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        #expect(try await upgraded.collection(key: "album", scope: upgraded.scope)?.completeness == .complete)
        #expect(try await upgraded.playlistLibrary(scope: upgraded.scope) == nil)
        try await upgraded.replacePlaylistLibrary(
            CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100)),
            scope: upgraded.scope)
        try await upgraded.close(scope: upgraded.scope)
        try executeSQL("UPDATE playlist_library SET data=x'00'", file: file)
        let corrupt = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        await #expect(throws: CatalogStorageError.invalidStoredData) {
            try await corrupt.playlistLibrary(scope: corrupt.scope)
        }
        #expect(try await corrupt.collection(key: "album", scope: corrupt.scope)?.completeness == .complete)
        try await corrupt.retire(scope: corrupt.scope)
    }

    private func tree() -> [PlaylistLibraryNode] {
        let playlist = PlaylistLibraryNode(
            playlist: CatalogItem(
                id: "mix", uri: "spotify:playlist:mix",
                title: "Mix", subtitle: "Fixture", artworkURL: nil, kind: .playlist, ownerURI: "spotify:user:synthetic")
        )
        return [
            playlist,
            .init(
                folderURI: "folder:one", title: "Folder",
                children: [
                    .init(folderURI: "folder:empty", title: "Empty", children: []), playlist,
                ]),
        ]
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spotty-library-storage-\(UUID().uuidString)")
    }

    private func executeSQL(_ sql: String, file: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CatalogStorageError.filesystem }
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
    }
}

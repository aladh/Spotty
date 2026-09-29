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

    @Test(arguments: [false, true])
    func repeatedFolderIdentityIsRejectedAndStoredDamageCanBeRepaired(persisted: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let original = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await catalog.replacePlaylistLibrary(original, scope: catalog.scope)
        let folder = PlaylistLibraryNode(folderURI: "folder:duplicate", title: "Repeated", children: [])
        let invalid = CatalogPlaylistLibraryRecord(
            nodes: [folder, folder], fetchedAt: Date(timeIntervalSince1970: 101))
        if persisted {
            try await catalog.close(scope: catalog.scope)
            let directory = try #require(
                FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.count == 64 })
            let bytes = try JSONEncoder().encode(invalid).map { String(format: "%02x", $0) }.joined()
            try executeSQL(
                "UPDATE playlist_library SET data=x'\(bytes)'", file: directory.appendingPathComponent("catalog.sqlite")
            )
            catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
            await #expect(throws: CatalogStorageError.invalidStoredData) {
                try await catalog.playlistLibrary(scope: catalog.scope)
            }
            try await catalog.replacePlaylistLibrary(original, scope: catalog.scope)
        } else {
            await #expect(throws: CatalogStorageError.invalidInput) {
                try await catalog.replacePlaylistLibrary(invalid, scope: catalog.scope)
            }
        }
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == original)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func versionOneUpgradeKeepsCollectionsAndLiveRefreshRepairsCorruptLibrary() async throws {
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
        #expect(try await upgraded.completeCollection(key: "album", scope: upgraded.scope)?.occurrences.isEmpty == true)
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
        #expect(try await corrupt.completeCollection(key: "album", scope: corrupt.scope)?.occurrences.isEmpty == true)
        let repaired = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 101))
        try await corrupt.replacePlaylistLibrary(repaired, scope: corrupt.scope)
        #expect(try await corrupt.playlistLibrary(scope: corrupt.scope) == repaired)
        try await corrupt.close(scope: corrupt.scope)
        let reopened = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        #expect(try await reopened.playlistLibrary(scope: reopened.scope) == repaired)
        #expect(try await reopened.completeCollection(key: "album", scope: reopened.scope)?.occurrences.isEmpty == true)
        try await reopened.retire(scope: reopened.scope)
    }

    @Test(arguments: [false, true])
    func equalDatesKeepTheNewerAdmissionInEitherDeliveryOrder(newerFirst: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let older = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        let newer = CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: older.fetchedAt)
        var writes: [(CatalogPlaylistLibraryRecord, UInt64)] = [(older, 1), (newer, 2)]
        if newerFirst { writes.reverse() }
        for (record, ordinal) in writes {
            try await catalog.replacePlaylistLibrary(record, scope: catalog.scope, admissionOrdinal: ordinal)
        }
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == newer)
        // Repeating an already accepted ordinal cannot change the tree either.
        try await catalog.replacePlaylistLibrary(older, scope: catalog.scope, admissionOrdinal: 2)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == newer)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func identicalTreeAdvancesReadAdmissionOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let record = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await catalog.replacePlaylistLibrary(record, scope: catalog.scope, admissionOrdinal: 1)
        try await catalog.replacePlaylistLibrary(record, scope: catalog.scope, admissionOrdinal: 3)
        try await catalog.replacePlaylistLibrary(
            CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: record.fetchedAt), scope: catalog.scope,
            admissionOrdinal: 2)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == record)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func datesStillTakePrecedenceAndRejectedWritesDoNotAdvanceOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let current = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await catalog.replacePlaylistLibrary(current, scope: catalog.scope, admissionOrdinal: 10)
        try await catalog.replacePlaylistLibrary(
            CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: Date(timeIntervalSince1970: 99)),
            scope: catalog.scope, admissionOrdinal: 100)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == current)
        let equalDate = CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: current.fetchedAt)
        try await catalog.replacePlaylistLibrary(equalDate, scope: catalog.scope, admissionOrdinal: 11)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == equalDate)
        let laterDate = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 101))
        try await catalog.replacePlaylistLibrary(laterDate, scope: catalog.scope, admissionOrdinal: 1)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == laterDate)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test(arguments: [false, true])
    func failedWritesCannotReserveALaterAdmission(databaseFailure: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let record = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        try await catalog.replacePlaylistLibrary(record, scope: catalog.scope, admissionOrdinal: 1)
        if databaseFailure {
            let directory = try #require(
                FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.count == 64 })
            let file = directory.appendingPathComponent("catalog.sqlite")
            // The update succeeds, but its deferred constraint fails COMMIT. This distinguishes
            // committed ordering authority from merely completing the INSERT/UPDATE statement.
            try executeSQL(
                "CREATE TABLE library_parent(id INTEGER PRIMARY KEY); "
                    + "CREATE TABLE library_child(parent_id INTEGER REFERENCES library_parent(id) DEFERRABLE INITIALLY DEFERRED); "
                    + "CREATE TRIGGER reject_library AFTER UPDATE ON playlist_library BEGIN INSERT INTO library_child VALUES(1); END",
                file: file)
            defer { try? executeSQL("DROP TRIGGER IF EXISTS reject_library", file: file) }
            await #expect(throws: CatalogStorageError.database(SQLITE_CONSTRAINT)) {
                try await catalog.replacePlaylistLibrary(
                    CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: record.fetchedAt),
                    scope: catalog.scope, admissionOrdinal: 3)
            }
            try executeSQL("DROP TRIGGER reject_library", file: file)
        } else {
            await #expect(throws: CatalogStorageError.invalidInput) {
                try await catalog.replacePlaylistLibrary(
                    CatalogPlaylistLibraryRecord(
                        nodes: [.init(folderURI: "", title: "Invalid", children: [])], fetchedAt: record.fetchedAt),
                    scope: catalog.scope, admissionOrdinal: 3)
            }
        }
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == record)
        let accepted = CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: record.fetchedAt)
        try await catalog.replacePlaylistLibrary(accepted, scope: catalog.scope, admissionOrdinal: 2)
        #expect(try await catalog.playlistLibrary(scope: catalog.scope) == accepted)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func unversionedWritesAndNewOwnersStartWithoutPriorAdmissionOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        let record = CatalogPlaylistLibraryRecord(nodes: tree(), fetchedAt: Date(timeIntervalSince1970: 100))
        let empty = CatalogPlaylistLibraryRecord(nodes: [], fetchedAt: record.fetchedAt)
        try await original.replacePlaylistLibrary(record, scope: original.scope, admissionOrdinal: 100)
        try await original.replacePlaylistLibrary(empty, scope: original.scope)
        #expect(try await original.playlistLibrary(scope: original.scope) == empty)
        try await original.replacePlaylistLibrary(record, scope: original.scope, admissionOrdinal: 20)
        #expect(try await original.playlistLibrary(scope: original.scope) == record)
        try await original.close(scope: original.scope)
        let reopened = PersistentCatalog(rootDirectory: root, accountID: "synthetic")
        try await reopened.replacePlaylistLibrary(empty, scope: reopened.scope, admissionOrdinal: 1)
        #expect(try await reopened.playlistLibrary(scope: reopened.scope) == empty)
        try await reopened.retire(scope: reopened.scope)
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

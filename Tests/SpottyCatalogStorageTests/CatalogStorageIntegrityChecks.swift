import Foundation
import SQLite3
import SpottyCatalogStorage
import SpottyDomain
import Testing

struct CatalogStorageIntegrityChecks {
    @Test(arguments: [
        CatalogRetentionLimits(entities: 1),
        CatalogRetentionLimits(collections: 1),
        CatalogRetentionLimits(occurrencesPerCollection: 1),
        CatalogRetentionLimits(recordBytes: 256),
    ])
    func tighterLogicalLimitsRejectReopenWithoutDeletingAccountData(_ limits: CatalogRetentionLimits) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = write("a", tracks: [track("one"), track("two")])
        _ = try await initial.replaceCollection(original, scope: initial.scope)
        _ = try await initial.replaceCollection(write("b", tracks: [track("one")]), scope: initial.scope)
        try await initial.close(scope: initial.scope)
        let database = try databaseFile(directory)
        let before = try Data(contentsOf: database)

        let restricted = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account", limits: limits)
        await #expect(throws: CatalogStorageError.invalidStoredData) {
            try await restricted.open(scope: restricted.scope)
        }
        #expect(try Data(contentsOf: database) == before)
        let compatible = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        #expect(try await compatible.collection(key: "a", scope: compatible.scope)?.occurrences == original.occurrences)
        try await compatible.close(scope: compatible.scope)
        try await restricted.retire(scope: restricted.scope)
        #expect(!FileManager.default.fileExists(atPath: database.path))
    }

    @Test func tighterByteLimitCannotSilentlyAcceptLargerExistingDatabase() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalLimits = CatalogRetentionLimits(recordBytes: 1_048_576, databaseBytes: 4_194_304)
        let initial = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: originalLimits)
        let tracks = [
            track("one", title: String(repeating: "x", count: 700_000)),
            track("two", title: String(repeating: "y", count: 700_000)),
        ]
        _ = try await initial.upsertTracks(tracks, scope: initial.scope)
        try await initial.close(scope: initial.scope)
        let database = try databaseFile(directory)
        let before = try Data(contentsOf: database)
        #expect(before.count > 1_048_576)

        let restricted = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account",
            limits: CatalogRetentionLimits(recordBytes: 1_048_576, databaseBytes: 1_048_576)
        )
        await #expect(throws: CatalogStorageError.invalidStoredData) {
            try await restricted.open(scope: restricted.scope)
        }
        #expect(try Data(contentsOf: database) == before)
        let compatible = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: originalLimits)
        #expect(try await compatible.tracks(for: [tracks[0].uri], scope: compatible.scope)[tracks[0].uri] == tracks[0])
        try await compatible.close(scope: compatible.scope)
        try await restricted.retire(scope: restricted.scope)
        #expect(!FileManager.default.fileExists(atPath: database.path))
    }

    @Test(arguments: ["entities", "collections", "occurrences"])
    func malformedSQLStorageClassIsRejectedInsteadOfBecomingMissingData(_ table: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = write("a", tracks: [track("one")])
        _ = try await initial.replaceCollection(original, scope: initial.scope)
        try await initial.close(scope: initial.scope)
        try executeSQL("UPDATE \(table) SET data='invalid storage class'", file: databaseFile(directory))
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        try await catalog.open(scope: catalog.scope)

        if table == "entities" {
            await #expect(throws: CatalogStorageError.invalidStoredData) {
                try await catalog.tracks(for: [track("one").uri], scope: catalog.scope)
            }
            await #expect(throws: CatalogStorageError.invalidStoredData) {
                try await catalog.upsertTracks([track("one", title: "Replacement")], scope: catalog.scope)
            }
        } else {
            await #expect(throws: CatalogStorageError.invalidStoredData) {
                try await catalog.collection(key: "a", scope: catalog.scope)
            }
            await #expect(throws: CatalogStorageError.invalidStoredData) {
                try await catalog.replaceCollection(
                    write("a", tracks: [track("one", title: "Replacement")]), scope: catalog.scope)
            }
            // An invalid occurrence must roll back the entity update earlier in the transaction.
            #expect(
                try await catalog.tracks(for: [track("one").uri], scope: catalog.scope)[track("one").uri]
                    == track("one"))
        }
        try await catalog.retire(scope: catalog.scope)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spotty-catalog-integrity-\(UUID().uuidString)")
    }

    private func databaseFile(_ root: URL) throws -> URL {
        let directory = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.count == 64 })
        return directory.appendingPathComponent("catalog.sqlite")
    }

    private func track(_ id: String, title: String = String(repeating: "Synthetic track ", count: 40)) -> CatalogTrack {
        CatalogTrack(
            id: "spotify:track:\(id)", uri: "spotify:track:\(id)", title: title,
            artist: "Synthetic artist", album: "Synthetic album", duration: 180, artworkURL: nil, addedAt: nil
        )
    }

    private func write(_ key: String, tracks: [CatalogTrack]) -> CatalogCollectionWrite {
        CatalogCollectionWrite(
            key: key, occurrences: CatalogOccurrence.browsingRows(tracks), completeness: .complete,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func executeSQL(_ sql: String, file: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CatalogStorageError.filesystem }
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
    }
}

import CryptoKit
import Foundation
import SpottyDomain

/// One account's serialized disk worker. No actor method suspends inside a transaction.
/// It provides browsing metadata only, never queue, playback, or playlist-write authority.
public actor PersistentCatalog {
    /// Sign-out can purge retained accounts before a fresh profile has bound the current account.
    /// A dedicated worker and an exclusive root lock keep filesystem work off the caller's actor
    /// and prevent any account owner opening during the enumeration. Missing roots are a no-op.
    public static func purgeRetainedAccounts(rootDirectory: URL) async throws {
        try await CatalogRootPurger.shared.purge(rootDirectory: rootDirectory)
    }

    public nonisolated let scope: CatalogStorageScope
    private let rootDirectory: URL
    private let directory: URL
    private let limits: CatalogRetentionLimits
    private let validAccountID: Bool
    private var database: CatalogSQLiteDatabase?
    private var isRetired = false
    private var isFinished = false

    public init(
        rootDirectory: URL,
        accountID: String,
        scope: CatalogStorageScope = CatalogStorageScope(),
        limits: CatalogRetentionLimits = CatalogRetentionLimits()
    ) {
        self.rootDirectory = rootDirectory
        self.scope = scope
        self.limits = limits
        validAccountID = !accountID.isEmpty && accountID.utf8.count <= 1_024
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = rootDirectory.appendingPathComponent(digest, isDirectory: true)
    }

    /// Explicit open lets admission distinguish an unavailable cache from an empty one.
    public func open(scope: CatalogStorageScope) throws {
        _ = try connection(scope)
    }

    /// Ends this lifetime, retaining browsing data for the next process. Later retirement is a no-op.
    public func close(scope: CatalogStorageScope) throws {
        try validateScope(scope)
        guard !isFinished else { return }
        // A failed purge must be retried as retirement, not silently converted into retention.
        guard !isRetired else { throw CatalogStorageError.retired }
        isRetired = true
        database?.close()
        database = nil
        isFinished = true
    }

    /// Fences new work first, then removes content and SQLite sidecars while owning the account lock.
    /// This is logical deletion, not forensic erasure. A failed purge keeps its lock for a retry.
    public func retire(scope: CatalogStorageScope) throws {
        try validateScope(scope)
        guard !isFinished else { return }
        isRetired = true
        if database == nil {
            try validateConfiguration()
            database = try CatalogSQLiteDatabase(
                directory: directory, rootDirectory: rootDirectory, openDatabase: false)
        }
        try database?.purge()
        database = nil
        isFinished = true
    }

    public func tracks(for requestedURIs: [String], scope: CatalogStorageScope) throws -> [String: CatalogTrack] {
        let db = try connection(scope)
        guard requestedURIs.count <= limits.pageSize else { throw CatalogStorageError.invalidInput }
        var tracks: [String: CatalogTrack] = [:]
        for uri in Set(requestedURIs) {
            try validateKey(uri)
            if let data = try entityData(kind: 0, uri: uri, db: db) {
                tracks[uri] = try decode(StoredTrack.self, data).value(id: uri)
            }
        }
        return tracks
    }

    public func items(for uris: [String], scope: CatalogStorageScope) throws -> [String: CatalogItem] {
        let db = try connection(scope)
        guard uris.count <= limits.pageSize else { throw CatalogStorageError.invalidInput }
        var items: [String: CatalogItem] = [:]
        for uri in Set(uris) {
            try validateKey(uri)
            if let data = try entityData(kind: 1, uri: uri, db: db) {
                items[uri] = try decode(StoredItem.self, data).value
            }
        }
        return items
    }

    public func upsertTracks(_ tracks: [CatalogTrack], scope: CatalogStorageScope) throws -> CatalogStorageChanges {
        let db = try connection(scope)
        guard tracks.count <= limits.entities else { throw CatalogStorageError.invalidInput }
        var writes: [String: Data] = [:]
        for track in tracks {
            try validateKey(track.uri)
            writes[track.uri] = try encode(StoredTrack(track))
        }
        return try db.transaction {
            var changes = CatalogStorageChanges()
            try upsert(writes, kind: 0, db: db, changes: &changes)
            try trim(db, changes: &changes)
            return changes
        }
    }

    public func upsertItems(_ items: [CatalogItem], scope: CatalogStorageScope) throws -> CatalogStorageChanges {
        let db = try connection(scope)
        guard items.count <= limits.entities else { throw CatalogStorageError.invalidInput }
        var writes: [String: Data] = [:]
        for item in items {
            try validateKey(item.uri)
            writes[item.uri] = try encode(StoredItem(item))
        }
        return try db.transaction {
            var changes = CatalogStorageChanges()
            try upsert(writes, kind: 1, db: db, changes: &changes)
            try trim(db, changes: &changes)
            return changes
        }
    }

    public func replaceCollection(
        _ write: CatalogCollectionWrite,
        scope: CatalogStorageScope
    ) throws -> CatalogStorageChanges {
        let db = try connection(scope)
        try validateKey(write.key)
        guard write.occurrences.count <= limits.occurrencesPerCollection,
            Set(write.occurrences.map(\.id)).count == write.occurrences.count,
            write.fetchedAt.timeIntervalSince1970.isFinite
        else { throw CatalogStorageError.invalidInput }
        let header = StoredCollection(write)
        let headerData = try encode(header)
        var tracks: [String: Data] = [:]
        var rows: [Data] = []
        for occurrence in write.occurrences {
            try validateKey(occurrence.id)
            try validateKey(occurrence.requestedURI)
            try validateKey(occurrence.track.uri)
            if let uid = occurrence.serverUID { try validateKey(uid) }
            tracks[occurrence.requestedURI] = try encode(StoredTrack(occurrence.track))
            rows.append(try encode(StoredOccurrence(occurrence)))
        }
        guard tracks.count <= limits.entities else { throw CatalogStorageError.invalidInput }
        return try db.transaction {
            var changes = CatalogStorageChanges()
            let oldHeader = try collectionData(write.key, db: db)
            if let oldHeader {
                let previous = try decode(StoredCollection.self, oldHeader)
                // Neither an older refresh nor partial pagination can downgrade an accepted result.
                guard header.fetchedAt >= previous.fetchedAt,
                    !(previous.completeness == .complete && header.completeness == .partial)
                else {
                    changes.collectionWriteRejected = true
                    return changes
                }
            }
            try upsert(tracks, kind: 0, db: db, changes: &changes)
            let oldRows = try db.rows(
                "SELECT data FROM occurrences WHERE collection_key=? ORDER BY position", [.text(write.key)]
            ).map { try storedData($0) }
            let touched = try nextTouch(db)
            try db.execute(
                "INSERT INTO collections(key,data,touched) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET data=excluded.data,touched=excluded.touched",
                [.text(write.key), .blob(headerData), .integer(touched)]
            )
            if oldHeader != headerData || oldRows != rows { changes.collectionKeys.insert(write.key) }
            if oldRows != rows {
                try db.execute("DELETE FROM occurrences WHERE collection_key=?", [.text(write.key)])
                for (position, occurrence) in write.occurrences.enumerated() {
                    try db.execute(
                        "INSERT INTO occurrences(collection_key,position,requested_uri,data) VALUES(?,?,?,?)",
                        [
                            .text(write.key), .integer(Int64(position)), .text(occurrence.requestedURI),
                            .blob(rows[position]),
                        ]
                    )
                }
            }
            try trim(db, changes: &changes)
            return changes
        }
    }

    public func collection(
        key: String,
        offset: Int = 0,
        limit: Int = 500,
        scope: CatalogStorageScope
    ) throws -> CatalogCollectionPage? {
        let db = try connection(scope)
        try validateKey(key)
        guard offset >= 0, limit > 0, limit <= limits.pageSize else { throw CatalogStorageError.invalidInput }
        guard let data = try collectionData(key, db: db) else { return nil }
        let header = try decode(StoredCollection.self, data)
        let total =
            try db.rows("SELECT COUNT(*) FROM occurrences WHERE collection_key=?", [.text(key)])
            .first?.first?.integer ?? 0
        let rows = try db.rows(
            "SELECT o.data,e.data FROM occurrences o LEFT JOIN entities e ON e.kind=0 AND e.uri=o.requested_uri WHERE o.collection_key=? ORDER BY o.position LIMIT ? OFFSET ?",
            [.text(key), .integer(Int64(limit)), .integer(Int64(offset))]
        )
        let occurrences = try rows.map { row -> CatalogOccurrence in
            guard let occurrenceData = row[0].blob, let trackData = row[1].blob else {
                throw CatalogStorageError.invalidStoredData
            }
            let occurrence = try decode(StoredOccurrence.self, occurrenceData)
            let track = try decode(StoredTrack.self, trackData)
            return CatalogOccurrence(
                id: occurrence.id, requestedURI: occurrence.requestedURI, serverUID: occurrence.serverUID,
                track: track.value(
                    id: occurrence.trackID, addedAt: occurrence.addedAt, occurrenceUID: occurrence.serverUID)
            )
        }
        try db.execute("UPDATE collections SET touched=? WHERE key=?", [.integer(try nextTouch(db)), .text(key)])
        return CatalogCollectionPage(
            key: key, occurrences: occurrences, offset: offset, totalCount: Int(total),
            completeness: header.completeness, revision: header.revision, fetchedAt: header.fetchedAt,
            metadata: header.metadata
        )
    }

    private func upsert(
        _ writes: [String: Data], kind: Int64, db: CatalogSQLiteDatabase, changes: inout CatalogStorageChanges
    ) throws {
        let touched = try nextTouch(db)
        for uri in writes.keys.sorted() {
            guard let data = writes[uri] else { continue }
            if try entityData(kind: kind, uri: uri, db: db) != data {
                if kind == 0 {
                    changes.trackURIs.insert(uri)
                    let references = try db.rows(
                        "SELECT DISTINCT collection_key FROM occurrences WHERE requested_uri=?", [.text(uri)]
                    )
                    changes.collectionKeys.formUnion(references.compactMap { $0.first?.text })
                } else {
                    changes.itemURIs.insert(uri)
                }
            }
            try db.execute(
                "INSERT INTO entities(kind,uri,data,touched) VALUES(?,?,?,?) ON CONFLICT(kind,uri) DO UPDATE SET data=excluded.data,touched=excluded.touched",
                [.integer(kind), .text(uri), .blob(data), .integer(touched)]
            )
        }
    }

    private func trim(_ db: CatalogSQLiteDatabase, changes: inout CatalogStorageChanges) throws {
        let collectionVictims = try db.rows(
            "SELECT key FROM collections ORDER BY touched DESC,key LIMIT -1 OFFSET ?",
            [.integer(Int64(limits.collections))]
        ).compactMap { $0.first?.text }
        for key in collectionVictims { try evictCollection(key, db: db, changes: &changes) }
        let count = try db.rows("SELECT COUNT(*) FROM entities").first?.first?.integer ?? 0
        let excess = count - Int64(limits.entities)
        guard excess > 0 else { return }
        let victims = try db.rows(
            "SELECT kind,uri FROM entities ORDER BY touched,kind,uri LIMIT ?", [.integer(excess)]
        )
        for victim in victims {
            guard let kind = victim[0].integer, let uri = victim[1].text else {
                throw CatalogStorageError.invalidStoredData
            }
            if kind == 0 {
                // Retire entire results before their entities; no cached page silently loses rows.
                let references = try db.rows(
                    "SELECT DISTINCT collection_key FROM occurrences WHERE requested_uri=?", [.text(uri)]
                ).compactMap { $0.first?.text }
                for key in references { try evictCollection(key, db: db, changes: &changes) }
                changes.trackURIs.insert(uri)
            } else {
                changes.itemURIs.insert(uri)
            }
            try db.execute("DELETE FROM entities WHERE kind=? AND uri=?", [.integer(kind), .text(uri)])
        }
    }

    private func evictCollection(_ key: String, db: CatalogSQLiteDatabase, changes: inout CatalogStorageChanges) throws
    {
        try db.execute("DELETE FROM collections WHERE key=?", [.text(key)])
        changes.collectionKeys.insert(key)
    }

    private func entityData(kind: Int64, uri: String, db: CatalogSQLiteDatabase) throws -> Data? {
        guard
            let row = try db.rows(
                "SELECT data FROM entities WHERE kind=? AND uri=?", [.integer(kind), .text(uri)]
            ).first
        else { return nil }
        return try storedData(row)
    }

    private func collectionData(_ key: String, db: CatalogSQLiteDatabase) throws -> Data? {
        guard let row = try db.rows("SELECT data FROM collections WHERE key=?", [.text(key)]).first else { return nil }
        return try storedData(row)
    }

    private func storedData(_ row: [CatalogSQLiteValue]) throws -> Data {
        guard let data = row.first?.blob else { throw CatalogStorageError.invalidStoredData }
        return data
    }

    private func nextTouch(_ db: CatalogSQLiteDatabase) throws -> Int64 {
        let current =
            try db.rows(
                "SELECT MAX(touched) FROM (SELECT touched FROM entities UNION ALL SELECT touched FROM collections)"
            )
            .first?.first?.integer ?? 0
        guard current < Int64.max else { throw CatalogStorageError.invalidStoredData }
        return current + 1
    }

    private func connection(_ scope: CatalogStorageScope) throws -> CatalogSQLiteDatabase {
        try validateScope(scope)
        guard !isRetired else { throw CatalogStorageError.retired }
        if let database { return database }
        try validateConfiguration()
        let opened = try CatalogSQLiteDatabase(directory: directory, rootDirectory: rootDirectory)
        try validateStoredBounds(opened)
        database = opened
        return opened
    }

    private func validateStoredBounds(_ db: CatalogSQLiteDatabase) throws {
        let pageSize = try storedInteger("PRAGMA page_size", db: db)
        guard pageSize > 0 else { throw CatalogStorageError.invalidStoredData }
        let pageLimit = Int64(limits.databaseBytes) / pageSize
        // SQLite cannot lower its page cap below the existing file size. Reject an oversized
        // cache without deleting content; retirement remains able to purge this account.
        guard try storedInteger("PRAGMA page_count", db: db) <= pageLimit else {
            throw CatalogStorageError.invalidStoredData
        }
        guard try storedInteger("SELECT COUNT(*) FROM entities", db: db) <= Int64(limits.entities),
            try storedInteger("SELECT COUNT(*) FROM collections", db: db) <= Int64(limits.collections),
            try storedInteger(
                "SELECT COALESCE(MAX(row_count),0) FROM (SELECT COUNT(*) AS row_count FROM occurrences GROUP BY collection_key)",
                db: db
            ) <= Int64(limits.occurrencesPerCollection),
            try storedInteger(
                "SELECT COALESCE(MAX(record_bytes),0) FROM (SELECT length(data) AS record_bytes FROM entities UNION ALL SELECT length(data) FROM collections UNION ALL SELECT length(data) FROM occurrences)",
                db: db
            ) <= Int64(limits.recordBytes)
        else { throw CatalogStorageError.invalidStoredData }
        guard try storedInteger("PRAGMA max_page_count=\(pageLimit)", db: db) == pageLimit else {
            throw CatalogStorageError.invalidStoredData
        }
    }

    private func storedInteger(_ sql: String, db: CatalogSQLiteDatabase) throws -> Int64 {
        guard let value = try db.rows(sql).first?.first?.integer else {
            throw CatalogStorageError.invalidStoredData
        }
        return value
    }

    private func validateScope(_ candidate: CatalogStorageScope) throws {
        guard scope == candidate else { throw CatalogStorageError.staleScope }
    }

    private func validateConfiguration() throws {
        guard validAccountID, rootDirectory.isFileURL,
            (1...50_000).contains(limits.entities), (1...256).contains(limits.collections),
            (1...50_000).contains(limits.occurrencesPerCollection), (1...1_000).contains(limits.pageSize),
            (256...1_048_576).contains(limits.recordBytes),
            (1_048_576...1_073_741_824).contains(limits.databaseBytes)
        else { throw CatalogStorageError.invalidInput }
    }

    private func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 8_192, !key.contains("\0") else { throw CatalogStorageError.invalidInput }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(value) } catch { throw CatalogStorageError.invalidInput }
        guard data.count <= limits.recordBytes else { throw CatalogStorageError.invalidInput }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= limits.recordBytes else { throw CatalogStorageError.invalidStoredData }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CatalogStorageError.invalidStoredData }
    }
}

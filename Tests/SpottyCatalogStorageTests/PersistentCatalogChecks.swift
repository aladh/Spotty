import Foundation
import SQLite3
import SpottyCatalogStorage
import SpottyDomain
import Testing

@Suite("Persistent account catalog")
struct PersistentCatalogChecks {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [1, 63, 64, 65, 129, 500])
    func entityPagesBindOpaqueURIsAndDeduplicateAcrossBatchBoundaries(pageSize: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: CatalogRetentionLimits(pageSize: pageSize)
        )
        let rows = (0..<pageSize).map { track($0 == 0 ? "quoted:'雪,)" : "\($0)", title: "Track \($0)") }
        let retained = rows.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        _ = try await catalog.replaceCollection(write("batch", tracks: retained), scope: catalog.scope)
        var requested = rows.map(\.uri)
        if requested.count > 1 { requested[requested.count - 1] = requested[0] }
        let result = try await catalog.tracks(for: requested, scope: catalog.scope)
        let expected = retained.filter { requested.contains($0.uri) }
        #expect(result == Dictionary(uniqueKeysWithValues: expected.map { ($0.uri, $0) }))
        #expect(try await catalog.tracks(for: [], scope: catalog.scope).isEmpty)
        await #expect(throws: CatalogStorageError.invalidInput) {
            try await catalog.tracks(for: requested + [requested[0]], scope: catalog.scope)
        }
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func persistsMetadataAndDuplicateOccurrencesAcrossLifetimes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = CatalogStorageScope()
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account", scope: scope)
        let requested = "spotify:track:requested"
        let playable = track("playable", id: "server-one", addedAt: epoch, occurrenceUID: "server-one")
        let duplicate = track(
            "playable", id: "server-two", addedAt: epoch.addingTimeInterval(60), occurrenceUID: "server-two")
        let occurrences = [
            CatalogOccurrence(id: "one", requestedURI: requested, serverUID: "server-one", track: playable),
            CatalogOccurrence(id: "two", requestedURI: requested, serverUID: "server-two", track: duplicate),
        ]
        let metadata = CatalogCollectionMetadata(
            description: "Synthetic description", ownerURI: "spotify:user:fixture", releaseDate: "2026")
        _ = try await catalog.replaceCollection(
            CatalogCollectionWrite(
                key: "playlist:synthetic", occurrences: occurrences, completeness: .complete,
                revision: "revision-one", fetchedAt: epoch, metadata: metadata
            ), scope: scope)
        try await catalog.close(scope: scope)

        let reopened = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let page = try #require(await reopened.completeCollection(key: "playlist:synthetic", scope: reopened.scope))
        #expect(page.occurrences == occurrences)
        #expect(page.occurrences.count == 2)
        #expect(page.revision == "revision-one")
        #expect(page.metadata == metadata)
        #expect(page.fetchedAt == epoch)
        let entity = try #require(await reopened.tracks(for: [requested], scope: reopened.scope)[requested])
        #expect(entity.uri == playable.uri)
        #expect(entity.id == requested)
        #expect(entity.addedAt == nil)
        try await reopened.retire(scope: reopened.scope)
    }

    @Test func browsingOccurrencesKeepExplicitUIDsAndDisambiguateOnlyDisplayIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let known = track("known", id: "display-known", occurrenceUID: "server-known")
        let repeated = track("duplicate", id: "repeated-display")
        let rows = CatalogOccurrence.browsingRows([known, repeated, repeated])
        #expect(rows[0].id == known.id)
        #expect(rows[0].serverUID == "server-known")
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.map(\.track.id) == rows.map(\.id))
        #expect(rows[1].serverUID == nil && rows[2].serverUID == nil)
        _ = try await catalog.replaceCollection(
            CatalogCollectionWrite(key: "duplicates", occurrences: rows, completeness: .complete, fetchedAt: epoch),
            scope: catalog.scope
        )
        let retained = try #require(await catalog.completeCollection(key: "duplicates", scope: catalog.scope))
        #expect(retained.occurrences == rows)
        #expect(retained.occurrences[0].track.occurrenceUID == "server-known")
        #expect(retained.occurrences[1].track.occurrenceUID == nil)
        let entity = try #require(await catalog.tracks(for: [known.uri], scope: catalog.scope)[known.uri])
        #expect(entity.occurrenceUID == nil)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func partialAndOlderRefreshesCannotReplaceCompleteCollection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = write("a", tracks: [track("one"), track("two")])
        _ = try await catalog.replaceCollection(original, scope: catalog.scope)
        let partial = write(
            "a", tracks: [track("three")], completeness: .partial, fetchedAt: epoch.addingTimeInterval(1))
        let partialChanges = try await catalog.replaceCollection(partial, scope: catalog.scope)
        #expect(partialChanges.isEmpty)
        #expect(partialChanges.collectionWriteRejected)
        let older = write("a", tracks: [track("four")], fetchedAt: epoch.addingTimeInterval(-1))
        #expect(try await catalog.replaceCollection(older, scope: catalog.scope).isEmpty)
        #expect(
            try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences == original.occurrences)
        #expect(try await catalog.tracks(for: [track("three").uri, track("four").uri], scope: catalog.scope).isEmpty)
        let empty = write("a", tracks: [], fetchedAt: epoch.addingTimeInterval(2))
        _ = try await catalog.replaceCollection(empty, scope: catalog.scope)
        #expect(try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences.count == 0)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func publishesOnlyEffectiveEntityChangesAndRelevantQueries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = write("a", tracks: [track("one"), track("one")])
        _ = try await catalog.replaceCollection(original, scope: catalog.scope)
        _ = try await catalog.replaceCollection(write("b", tracks: [track("two")]), scope: catalog.scope)
        #expect(try await catalog.replaceCollection(original, scope: catalog.scope).isEmpty)
        // Occurrence identity and added date do not change the shared entity's effective metadata.
        let newCollection = try await catalog.replaceCollection(
            write("c", tracks: [track("one", id: "other-row", addedAt: epoch)]), scope: catalog.scope)
        #expect(newCollection.trackURIs.isEmpty)
        #expect(newCollection.collectionKeys == ["c"])
        let changes = try await catalog.replaceCollection(
            write("c", tracks: [track("one", title: "New title")]), scope: catalog.scope)
        #expect(changes.trackURIs == [track("one").uri])
        #expect(changes.collectionKeys == ["a", "c"])
        let page = try #require(await catalog.completeCollection(key: "a", scope: catalog.scope))
        #expect(page.occurrences.map(\.track.title) == ["New title", "New title"])
        #expect(page.occurrences.map(\.id) == original.occurrences.map(\.id))
        let duplicateWrite = write(
            "c", tracks: [track("one", title: "Intermediate"), track("one", title: "New title")])
        let duplicateChanges = try await catalog.replaceCollection(duplicateWrite, scope: catalog.scope)
        #expect(duplicateChanges.trackURIs.isEmpty)
        #expect(duplicateChanges.collectionKeys == ["c"])
        #expect(try await catalog.replaceCollection(duplicateWrite, scope: catalog.scope).isEmpty)
        #expect(
            try await catalog.completeCollection(key: "c", scope: catalog.scope)?.occurrences.map(\.track.title)
                == ["New title", "New title"])
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func sharedEntitiesKeepNewestMetadataAcrossCollectionsAndLifetimes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let current = track("shared", title: "Current title")
        _ = try await catalog.replaceCollection(
            write("album", tracks: [current], fetchedAt: epoch.addingTimeInterval(2)), scope: catalog.scope)
        let older = track("shared", title: "Old title", id: "playlist-row", addedAt: epoch, occurrenceUID: "uid")
        let changes = try await catalog.replaceCollection(
            write("playlist", tracks: [older, track("unique")], fetchedAt: epoch.addingTimeInterval(1)),
            scope: catalog.scope)
        #expect(!changes.collectionWriteRejected, "Older metadata must not discard new collection membership")
        #expect(changes.trackURIs == [track("unique").uri])
        #expect(changes.collectionKeys == ["playlist"])
        let page = try #require(await catalog.completeCollection(key: "playlist", scope: catalog.scope))
        #expect(page.occurrences.map(\.track.title) == [current.title, "Synthetic track"])
        #expect(page.occurrences.first?.track.id == older.id)
        #expect(page.occurrences.first?.track.addedAt == older.addedAt)
        #expect(page.occurrences.first?.serverUID == older.occurrenceUID)
        // An identical observation still advances freshness without publishing a metadata change.
        let refreshed = try await catalog.replaceCollection(
            write("album", tracks: [current], fetchedAt: epoch.addingTimeInterval(4)), scope: catalog.scope)
        #expect(refreshed.trackURIs.isEmpty)
        try await catalog.close(scope: catalog.scope)

        let reopened = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let late = try await reopened.replaceCollection(
            write("other", tracks: [older], fetchedAt: epoch.addingTimeInterval(3)), scope: reopened.scope)
        #expect(late.trackURIs.isEmpty)
        #expect(late.collectionKeys == ["other"])
        #expect(try await reopened.tracks(for: [current.uri], scope: reopened.scope)[current.uri] == current)
        let newest = try await reopened.replaceCollection(
            write("other", tracks: [track("shared", title: "Newest title")], fetchedAt: epoch.addingTimeInterval(5)),
            scope: reopened.scope)
        #expect(newest.trackURIs == [current.uri])
        #expect(newest.collectionKeys == ["album", "playlist", "other"])
        try await reopened.retire(scope: reopened.scope)
    }

    @Test func identicalMetadataAdvancesOrderingBeyondCollectionEviction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account",
            limits: CatalogRetentionLimits(entities: 10, collections: 1))
        let current = track("shared", title: "Current")
        _ = try await catalog.replaceCollection(
            write("album", tracks: [current], admissionOrdinal: 1), scope: catalog.scope)
        let unchanged = try await catalog.replaceCollection(
            write("album", tracks: [current], admissionOrdinal: 3), scope: catalog.scope)
        #expect(unchanged.isEmpty, "An identical observation advances ordering without notifying subscribers")
        _ = try await catalog.replaceCollection(write("other", tracks: [track("other")]), scope: catalog.scope)
        #expect(try await catalog.completeCollection(key: "album", scope: catalog.scope) == nil)

        let older = track("shared", title: "Older", id: "playlist-row", occurrenceUID: "server-row")
        let changes = try await catalog.replaceCollection(
            write("playlist", tracks: [older], admissionOrdinal: 2), scope: catalog.scope)
        #expect(changes.trackURIs.isEmpty, "Evicting a collection must not weaken its retained entity's ordering")
        let retained = try #require(await catalog.completeCollection(key: "playlist", scope: catalog.scope))
        #expect(retained.occurrences.map(\.track.title) == [current.title])
        #expect(retained.occurrences.map(\.track.id) == [older.id])
        #expect(retained.occurrences.map(\.serverUID) == [older.occurrenceUID])
        #expect(retained.fetchedAt == epoch)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test(arguments: [-1.0, 1.0])
    func metadataDatesTakePrecedenceOverReadAdmissionOrder(dateChange: Double) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = track("shared", title: "Original")
        let incoming = track("shared", title: "Incoming")
        _ = try await catalog.replaceCollection(
            write("album", tracks: [original], admissionOrdinal: 2), scope: catalog.scope)
        let changes = try await catalog.replaceCollection(
            write(
                "playlist", tracks: [incoming], fetchedAt: epoch.addingTimeInterval(dateChange),
                admissionOrdinal: dateChange < 0 ? 3 : 1), scope: catalog.scope)
        let expected = dateChange < 0 ? original : incoming
        #expect(try await catalog.tracks(for: [original.uri], scope: catalog.scope)[original.uri] == expected)
        #expect(changes.trackURIs.isEmpty == (dateChange < 0))
        #expect(!changes.collectionWriteRejected)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func unrankedWritesRetainDateOnlySemantics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        _ = try await catalog.replaceCollection(
            write("album", tracks: [track("shared", title: "Ranked")], admissionOrdinal: 3), scope: catalog.scope)
        let unranked = track("shared", title: "Unranked")
        _ = try await catalog.replaceCollection(write("playlist", tracks: [unranked]), scope: catalog.scope)
        #expect(try await catalog.tracks(for: [unranked.uri], scope: catalog.scope)[unranked.uri] == unranked)
        let restoredOrder = track("shared", title: "Restored order")
        _ = try await catalog.replaceCollection(
            write("other", tracks: [restoredOrder], admissionOrdinal: 2), scope: catalog.scope)
        #expect(try await catalog.tracks(for: [unranked.uri], scope: catalog.scope)[unranked.uri] == restoredOrder)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func accountPartitionAndScopeFenceEveryReadAndWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-first")
        let second = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-second")
        _ = try await first.replaceCollection(write("a", tracks: [track("one")]), scope: first.scope)
        #expect(try await second.completeCollection(key: "a", scope: second.scope) == nil)
        await #expect(throws: CatalogStorageError.staleScope) {
            try await first.completeCollection(key: "a", scope: second.scope)
        }
        await #expect(throws: CatalogStorageError.staleScope) {
            try await first.replaceCollection(write("b", tracks: [track("two")]), scope: second.scope)
        }
        await #expect(throws: CatalogStorageError.staleScope) { try await first.retire(scope: second.scope) }
        #expect(try await first.completeCollection(key: "a", scope: first.scope)?.occurrences.count == 1)
        try await first.retire(scope: first.scope)
        await #expect(throws: CatalogStorageError.retired) {
            try await first.replaceCollection(write("late", tracks: [track("late")]), scope: first.scope)
        }
        try await second.retire(scope: second.scope)
    }

    @Test func exclusiveOwnershipAndIdempotentRetirementProtectReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        try await old.open(scope: old.scope)
        let replacement = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        await #expect(throws: CatalogStorageError.accountInUse) { try await replacement.open(scope: replacement.scope) }
        try await old.retire(scope: old.scope)
        _ = try await replacement.replaceCollection(write("new", tracks: [track("new")]), scope: replacement.scope)
        try await old.retire(scope: old.scope)
        #expect(try await replacement.completeCollection(key: "new", scope: replacement.scope)?.occurrences.count == 1)
        try await replacement.close(scope: replacement.scope)
        let third = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        try await third.open(scope: third.scope)
        try await replacement.retire(scope: replacement.scope)
        #expect(try await third.completeCollection(key: "new", scope: third.scope)?.occurrences.count == 1)
        try await third.retire(scope: third.scope)
    }

    @Test func retirementPurgesDatabaseAndSidecarsWithPrivatePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        _ = try await catalog.replaceCollection(write("a", tracks: [track("one")]), scope: catalog.scope)
        let accountDirectory = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: {
                $0.lastPathComponent.count == 64
            }))
        let database = accountDirectory.appendingPathComponent("catalog.sqlite")
        let fileMode = try FileManager.default.attributesOfItem(atPath: database.path)[.posixPermissions] as? NSNumber
        let directoryMode =
            try FileManager.default.attributesOfItem(atPath: accountDirectory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(directoryMode?.intValue == 0o700)
        #expect(!accountDirectory.lastPathComponent.contains("synthetic"))
        try Data("synthetic journal".utf8).write(to: accountDirectory.appendingPathComponent("catalog.sqlite-journal"))
        try await catalog.retire(scope: catalog.scope)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: accountDirectory.path)
        #expect(remaining == ["ownership.lock"])
        #expect(try Data(contentsOf: accountDirectory.appendingPathComponent("ownership.lock")).isEmpty)
    }

    @Test func queryRetentionUsesRevisitsAndEvictsWholeResults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = CatalogRetentionLimits(entities: 10, collections: 2)
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account", limits: limits)
        _ = try await catalog.replaceCollection(write("a", tracks: [track("one")]), scope: catalog.scope)
        _ = try await catalog.replaceCollection(write("b", tracks: [track("two")]), scope: catalog.scope)
        _ = try await catalog.completeCollection(key: "a", scope: catalog.scope)
        try await catalog.close(scope: catalog.scope)
        let reopened = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account", limits: limits)
        let changes = try await reopened.replaceCollection(write("c", tracks: [track("three")]), scope: reopened.scope)
        #expect(changes.collectionKeys == ["b", "c"])
        #expect(try await reopened.completeCollection(key: "b", scope: reopened.scope) == nil)
        #expect(try await reopened.completeCollection(key: "a", scope: reopened.scope)?.occurrences.count == 1)
        try await reopened.retire(scope: reopened.scope)
    }

    @Test func entityRetentionNeverReturnsIncompleteMembership() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: CatalogRetentionLimits(entities: 2))
        _ = try await catalog.replaceCollection(write("a", tracks: [track("one"), track("two")]), scope: catalog.scope)
        let changes = try await catalog.replaceCollection(write("b", tracks: [track("three")]), scope: catalog.scope)
        #expect(changes.trackURIs == [track("one").uri, track("three").uri])
        #expect(changes.collectionKeys == ["a", "b"])
        #expect(try await catalog.completeCollection(key: "a", scope: catalog.scope) == nil)
        let remaining = try await catalog.tracks(
            for: [track("one").uri, track("two").uri, track("three").uri], scope: catalog.scope)
        #expect(Set(remaining.keys) == [track("two").uri, track("three").uri])
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func completeSnapshotsKeepStableOrderAndRejectAmbiguousDisplayIDs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: CatalogRetentionLimits(pageSize: 2))
        let original = write("a", tracks: [track("one"), track("one"), track("two")])
        _ = try await catalog.replaceCollection(original, scope: catalog.scope)
        let snapshot = try #require(await catalog.completeCollection(key: "a", scope: catalog.scope))
        #expect(snapshot.occurrences == original.occurrences)
        let ambiguous = CatalogCollectionWrite(
            key: "a", occurrences: [original.occurrences[0], original.occurrences[0]], completeness: .complete,
            fetchedAt: epoch)
        await #expect(throws: CatalogStorageError.invalidInput) {
            try await catalog.replaceCollection(ambiguous, scope: catalog.scope)
        }
        #expect(try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences.count == 3)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func completeReadsCannotSpliceEqualDateAndSizeReplacements() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let first = write("a", tracks: (0..<1_001).map { track("\($0)", title: "First \($0)") })
        let second = write("a", tracks: (0..<1_001).map { track("\($0)", title: "Second \($0)") })
        _ = try await catalog.replaceCollection(first, scope: catalog.scope)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<6 {
                    _ = try await catalog.replaceCollection(
                        index.isMultiple(of: 2) ? second : first, scope: catalog.scope)
                }
            }
            group.addTask {
                for _ in 0..<12 {
                    let snapshot = try #require(await catalog.completeCollection(key: "a", scope: catalog.scope))
                    let coherent =
                        snapshot.occurrences == first.occurrences || snapshot.occurrences == second.occurrences
                    #expect(
                        coherent, "A complete read has one revision's ordered rows even when dates and counts match")
                }
            }
            try await group.waitForAll()
        }
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func partialCollectionsAreUnavailableAndCancelledReadsCanRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        _ = try await catalog.replaceCollection(
            write("partial", tracks: [track("one")], completeness: .partial), scope: catalog.scope)
        #expect(try await catalog.completeCollection(key: "partial", scope: catalog.scope) == nil)
        let complete = write("a", tracks: (0..<501).map { track("\($0)") })
        _ = try await catalog.replaceCollection(complete, scope: catalog.scope)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.completeCollection(key: "a", scope: catalog.scope)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(
            try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences == complete.occurrences)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func unsupportedMigrationPreservesDataAndCanBePurged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        _ = try await initial.replaceCollection(write("a", tracks: [track("one")]), scope: initial.scope)
        try await initial.close(scope: initial.scope)
        let accountDirectory = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: {
                $0.lastPathComponent.count == 64
            }))
        let file = accountDirectory.appendingPathComponent("catalog.sqlite")
        try executeSQL("PRAGMA user_version=999", file: file)
        let before = try Data(contentsOf: file)
        let reopened = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        await #expect(throws: CatalogStorageError.unsupportedSchema(999)) {
            try await reopened.open(scope: reopened.scope)
        }
        #expect(try Data(contentsOf: file) == before)
        try await reopened.retire(scope: reopened.scope)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func failedTransactionDoesNotReplaceExistingCollection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        let original = write("a", tracks: [track("one")])
        _ = try await initial.replaceCollection(original, scope: initial.scope)
        try await initial.close(scope: initial.scope)
        let accountDirectory = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: {
                $0.lastPathComponent.count == 64
            }))
        try executeSQL(
            "CREATE TRIGGER reject_fixture BEFORE INSERT ON occurrences WHEN NEW.requested_uri='spotify:track:rejected' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
            file: accountDirectory.appendingPathComponent("catalog.sqlite"))
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        await #expect(throws: CatalogStorageError.database(SQLITE_CONSTRAINT)) {
            try await catalog.replaceCollection(write("a", tracks: [track("rejected")]), scope: catalog.scope)
        }
        #expect(
            try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences == original.occurrences)
        #expect(try await catalog.tracks(for: [track("rejected").uri], scope: catalog.scope).isEmpty)
        let replacement = write("a", tracks: [track("accepted")])
        _ = try await catalog.replaceCollection(replacement, scope: catalog.scope)
        #expect(
            try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences == replacement.occurrences
        )
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func rejectsSymlinkStorageWithoutTouchingDestination() async throws {
        let directory = temporaryDirectory()
        let destination = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
        let catalog = PersistentCatalog(rootDirectory: directory, accountID: "synthetic-account")
        await #expect(throws: CatalogStorageError.unsafeStorageLocation) {
            try await catalog.open(scope: catalog.scope)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func boundedCollectionWritesDoNotPartiallyPublishInvalidBatches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account", limits: CatalogRetentionLimits(recordBytes: 512)
        )
        let item = CatalogItem(
            id: "album", uri: "spotify:album:fixture", title: "Synthetic album", subtitle: "Synthetic artist",
            artworkURL: nil, kind: .album
        )
        let original = CatalogCollectionWrite(
            key: "a", occurrences: [], completeness: .complete, fetchedAt: epoch,
            metadata: CatalogCollectionMetadata(item: item))
        let changes = try await catalog.replaceCollection(original, scope: catalog.scope)
        #expect(changes.trackURIs.isEmpty)
        #expect(changes.collectionKeys == ["a"])
        #expect(try await catalog.replaceCollection(original, scope: catalog.scope).isEmpty)
        #expect(try await catalog.completeCollection(key: "a", scope: catalog.scope)?.metadata.item == item)
        await #expect(throws: CatalogStorageError.invalidInput) {
            try await catalog.replaceCollection(
                write("b", tracks: [track("valid"), track("oversized", title: String(repeating: "x", count: 1_024))]),
                scope: catalog.scope)
        }
        #expect(try await catalog.tracks(for: [track("valid").uri], scope: catalog.scope).isEmpty)
        #expect(try await catalog.completeCollection(key: "b", scope: catalog.scope) == nil)
        #expect(try await catalog.completeCollection(key: "a", scope: catalog.scope)?.metadata.item == item)
        try await catalog.retire(scope: catalog.scope)
    }

    @Test func databaseSizeFailureRollsBackAllMetadataChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = PersistentCatalog(
            rootDirectory: directory, accountID: "synthetic-account",
            limits: CatalogRetentionLimits(recordBytes: 1_048_576, databaseBytes: 1_048_576)
        )
        let original = write("a", tracks: [track("one")], admissionOrdinal: 1)
        _ = try await catalog.replaceCollection(original, scope: catalog.scope)
        let largeTitle = String(repeating: "x", count: 800_000)
        await #expect(throws: CatalogStorageError.database(SQLITE_FULL)) {
            try await catalog.replaceCollection(
                write(
                    "b", tracks: [track("one", title: largeTitle), track("two", title: largeTitle)], admissionOrdinal: 3
                ),
                scope: catalog.scope)
        }
        #expect(
            try await catalog.completeCollection(key: "a", scope: catalog.scope)?.occurrences == original.occurrences)
        #expect(try await catalog.tracks(for: [track("two").uri], scope: catalog.scope).isEmpty)
        let recovered = track("one", title: "Recovered")
        #expect(try await catalog.completeCollection(key: "b", scope: catalog.scope) == nil)
        _ = try await catalog.replaceCollection(
            write("b", tracks: [recovered], admissionOrdinal: 2), scope: catalog.scope)
        #expect(try await catalog.tracks(for: [recovered.uri], scope: catalog.scope)[recovered.uri] == recovered)
        try await catalog.retire(scope: catalog.scope)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "spotty-catalog-\(UUID().uuidString)", isDirectory: true)
    }

    private func track(
        _ id: String, title: String = "Synthetic track", id rowID: String? = nil, addedAt: Date? = nil,
        occurrenceUID: String? = nil
    )
        -> CatalogTrack
    {
        CatalogTrack(
            id: rowID ?? "spotify:track:\(id)", uri: "spotify:track:\(id)", title: title,
            artist: "Synthetic artist", album: "Synthetic album", duration: 180, artworkURL: nil, addedAt: addedAt,
            occurrenceUID: occurrenceUID
        )
    }

    private func write(
        _ key: String, tracks: [CatalogTrack], completeness: CatalogCollectionCompleteness = .complete,
        fetchedAt: Date? = nil, admissionOrdinal: UInt64? = nil
    ) -> CatalogCollectionWrite {
        CatalogCollectionWrite(
            key: key, occurrences: CatalogOccurrence.browsingRows(tracks), completeness: completeness,
            fetchedAt: fetchedAt ?? epoch, admissionOrdinal: admissionOrdinal)
    }

    private func executeSQL(_ sql: String, file: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CatalogStorageError.filesystem }
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
    }
}

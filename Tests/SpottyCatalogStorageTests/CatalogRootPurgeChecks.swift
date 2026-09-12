import Foundation
import SpottyCatalogStorage
import SpottyDomain
import Testing

@Suite("Retained catalog logout purge")
struct CatalogRootPurgeChecks {
    @Test func coldLogoutPurgesEveryRetainedAccountAndPreservesUnrelatedFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for accountID in ["synthetic-first", "synthetic-second"] {
            let catalog = PersistentCatalog(rootDirectory: root, accountID: accountID)
            _ = try await catalog.upsertTracks([track], scope: catalog.scope)
            try await catalog.close(scope: catalog.scope)
        }
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("preserve this fixture".utf8).write(to: unrelated)
        let unknownDirectory = root.appendingPathComponent("unrelated-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: false)
        try Data("preserve this fixture".utf8).write(to: unknownDirectory.appendingPathComponent("catalog.sqlite"))

        try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: root)

        for accountID in ["synthetic-first", "synthetic-second"] {
            let catalog = PersistentCatalog(rootDirectory: root, accountID: accountID)
            #expect(try await catalog.tracks(for: [track.uri], scope: catalog.scope).isEmpty)
            try await catalog.retire(scope: catalog.scope)
        }
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserve this fixture")
        #expect(FileManager.default.fileExists(atPath: unknownDirectory.appendingPathComponent("catalog.sqlite").path))
    }

    @Test func liveOwnerBlocksRootPurgeBeforeAnyAccountIsDeleted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = PersistentCatalog(rootDirectory: root, accountID: "synthetic-retained")
        _ = try await retained.upsertTracks([track], scope: retained.scope)
        try await retained.close(scope: retained.scope)
        let live = PersistentCatalog(rootDirectory: root, accountID: "synthetic-live")
        try await live.open(scope: live.scope)
        await #expect(throws: CatalogStorageError.accountInUse) {
            try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: root)
        }
        let reopened = PersistentCatalog(rootDirectory: root, accountID: "synthetic-retained")
        #expect(try await reopened.tracks(for: [track.uri], scope: reopened.scope)[track.uri]?.title == track.title)
        try await reopened.close(scope: reopened.scope)
        try await live.close(scope: live.scope)
        try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: root)
    }

    @Test func missingRootIsNoOpAndAccountDirectoryLinksAreRejected() async throws {
        let root = temporaryDirectory()
        let destination = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationFile = destination.appendingPathComponent("catalog.sqlite")
        try Data("preserve destination".utf8).write(to: destinationFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(String(repeating: "a", count: 64)), withDestinationURL: destination
        )
        await #expect(throws: CatalogStorageError.unsafeStorageLocation) {
            try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: root)
        }
        #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "preserve destination")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "spotty-catalog-purge-\(UUID().uuidString)", isDirectory: true)
    }

    private var track: CatalogTrack {
        CatalogTrack(
            id: "fixture", uri: "spotify:track:fixture", title: "Synthetic track", artist: "Synthetic artist",
            album: "Synthetic album", duration: 120, artworkURL: nil, addedAt: nil
        )
    }
}

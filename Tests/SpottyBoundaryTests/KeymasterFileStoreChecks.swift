import Darwin
import Foundation
import Testing
import Synchronization
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("File-backed Spotify session")
struct KeymasterFileStoreChecks {
    private func temporaryDirectory() -> URL {
        // Foundation deliberately retains /var's alias even in resolvingSymlinksInPath.
        // Canonicalize only this trusted test root, never the store's supplied path.
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent("spotty-session-test-\(UUID().uuidString)")
    }

    @Test func grantSurvivesNewSessionAndLogoutRemovesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeymasterFileStore(directory: directory)
        #expect(store.loadResult() == .absent)
        let grant = KeymasterTokens(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(3_600), username: "synthetic-listener")
        let first = KeymasterSession(store: store, cookieCleanup: {})
        try await first.adopt(grant)
        let relaunched = KeymasterSession(store: KeymasterFileStore(directory: directory), cookieCleanup: {})
        #expect(await relaunched.grantState == .available)
        #expect(store.loadResult() == .found(grant))
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        let file = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("session.json").path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await relaunched.clear())
        let afterLogout = KeymasterSession(store: store, cookieCleanup: {})
        #expect(await afterLogout.grantState == .absent)
    }

    @Test func rotationIsDurableAndFailedReplacementPreservesPreviousGrant() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeymasterFileStore(directory: directory)
        var grant = KeymasterTokens(
            accessToken: "first", refreshToken: "first-refresh", expiresAt: Date(), username: "synthetic")
        try store.save(grant)
        grant = KeymasterTokens(
            accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: Date(), username: "synthetic")
        try store.save(grant)
        #expect(KeymasterFileStore(directory: directory).loadResult() == .found(grant))
        let oversized = KeymasterTokens(
            accessToken: String(repeating: "x", count: 70_000), refreshToken: "oversized",
            expiresAt: Date(), username: "synthetic")
        #expect(throws: (any Error).self) { try store.save(oversized) }
        #expect(store.loadResult() == .found(grant))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["session.json"])
    }

    @Test(arguments: [false, true]) @MainActor
    func failedRemovalStaysVisibleAndRetryDoesNotRestoreTheOldGrant(revoked: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeymasterFileStore(directory: directory)
        let cookies = Mutex(0)
        let session = KeymasterSession(
            store: store, refresher: { _ in throw KeymasterAuthError.grantRevoked },
            cookieCleanup: { cookies.withLock { $0 += 1 } })
        let grant = HarnessFixtures.tokens()
        try await session.adopt(grant)
        let stream = session.grantRevocations()
        var announcements = 0
        let listener = Task {
            for await _ in stream { announcements += 1 }
        }
        defer { listener.cancel() }
        // A directory at the staging name makes the store reject cleanup deterministically.
        let obstacle = directory.appendingPathComponent(".session.pending")
        try FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: false)

        if revoked {
            await #expect(throws: KeymasterSessionError.grantRevoked) {
                try await session.refreshIgnoringExpiry(rejected: grant.accessToken)
            }
            #expect(await waitUntil { announcements == 1 })
        } else {
            #expect(await session.clear() == false)
        }

        #expect(await session.grantState == .removalFailed)
        #expect(await session.hasGrant == false)
        #expect(cookies.withLock { $0 } == 1)
        await #expect(throws: KeymasterSessionError.noGrant) { try await session.accessToken() }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))

        try FileManager.default.removeItem(at: obstacle)
        #expect(await session.retryGrantState() == .absent)
        #expect(store.loadResult() == .absent, "retry finishes logout instead of restoring the retained grant")
    }

    @Test func schemaVersionPreservesLegacyGrantsAndRejectsFutureFormats() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeymasterFileStore(directory: directory)
        let grant = HarnessFixtures.tokens()
        try store.save(grant)
        let file = directory.appendingPathComponent("session.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        json.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(store.loadResult() == .found(grant))
        json["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(store.loadResult() == .failed)
    }

    @Test func symlinkedAncestorCannotRedirectSessionWritesOrCleanup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = KeymasterFileStore(directory: link.appendingPathComponent("Session"))
        let grant = KeymasterTokens(
            accessToken: "synthetic", refreshToken: "synthetic",
            expiresAt: Date(), username: "synthetic")
        #expect(throws: (any Error).self) { try store.save(grant) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let targetSession = target.appendingPathComponent("Session")
        try FileManager.default.createDirectory(at: targetSession, withIntermediateDirectories: true)
        let marker = Data("must survive cleanup through a symlink".utf8)
        let protectedFiles = ["session.json", ".session.pending"]
        for name in protectedFiles {
            try marker.write(to: targetSession.appendingPathComponent(name))
        }
        #expect(throws: (any Error).self) { try store.clear() }
        for name in protectedFiles {
            #expect(try Data(contentsOf: targetSession.appendingPathComponent(name)) == marker)
        }
    }

    @Test func restrictiveUmaskAndOrphanedStageDoNotBreakRestoration() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = KeymasterFileStore(directory: directory)
        let grant = KeymasterTokens(
            accessToken: "synthetic", refreshToken: "synthetic",
            expiresAt: Date(), username: "synthetic")
        // Boundary tests run serially; restore the process-wide mask before any await.
        let previous = umask(0o777)
        do {
            defer { umask(previous) }
            try store.save(grant)
        }
        let stage = directory.appendingPathComponent(".session.pending")
        try Data("interrupted replacement".utf8).write(to: stage)
        #expect(store.loadResult() == .found(grant))
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        try Data("interrupted replacement".utf8).write(to: stage)
        try store.clear()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func corruptOversizedAndSymlinkFilesFailClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        let store = KeymasterFileStore(directory: directory)
        for data in [Data("not json".utf8), Data(repeating: 0, count: 70_000)] {
            try data.write(to: file)
            #expect(store.loadResult() == .failed)
        }
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("untouched")
        let marker = Data("synthetic marker".utf8)
        try marker.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(store.loadResult() == .failed)
        try store.clear()
        #expect(try Data(contentsOf: target) == marker)
    }
}

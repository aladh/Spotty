import Foundation
import Testing
@testable import SpottyCore

@Suite("File-backed Spotify session")
struct KeymasterFileStoreChecks {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spotty-session-test-\(UUID().uuidString)")
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
        await relaunched.clear()
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
        store.clear()
        #expect(try Data(contentsOf: target) == marker)
    }
}

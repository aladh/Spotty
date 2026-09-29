import Darwin
import Foundation
import Testing
@testable import SpottyGateway

@Suite("Credential process environment")
struct CredentialProcessEnvironmentChecks {
    private func temporaryDirectory() -> URL {
        // Foundation deliberately retains /var's alias even in resolvingSymlinksInPath.
        // Canonicalize only this trusted test root, never the store's supplied path.
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent("spotty-session-test-\(UUID().uuidString)")
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

}

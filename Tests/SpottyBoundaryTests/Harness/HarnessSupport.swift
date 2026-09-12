import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

/// Fixed instants shared by every boundary fake. A single epoch keeps anchored timings comparable
/// across checks that mix a store, a feedback presenter, and a clock.
enum HarnessDates {
    /// The instant every sticky harness clock reports.
    static let fixed = Date(timeIntervalSince1970: 1_800_000_000)
}

/// The single failure boundary fakes throw when a dependency is deliberately unavailable.
enum HarnessFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Small value builders reused by fakes and by checks that need a realistic payload.
enum HarnessFixtures {
    static func metadata(
        uri: String,
        title: String = "Metadata",
        artist: String = "Artist",
        artworkURL: URL? = nil,
        duration: TimeInterval = 180
    ) -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            duration: duration
        )
    }

    static func track(
        uri: String,
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        duration: TimeInterval = 180
    ) -> CatalogTrack {
        CatalogTrack(
            id: uri,
            uri: uri,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: nil,
            addedAt: nil
        )
    }

    static func tokens(
        accessToken: String = "fixture-access",
        refreshToken: String = "fixture-refresh",
        expiresAt: Date = .distantFuture,
        username: String = "fixture-user"
    ) -> KeymasterTokens {
        KeymasterTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            username: username
        )
    }
}

/// Lock-protected counters shared by the harness fakes. Boundary checks read these from the
/// MainActor while the fake is being driven from a coordinator actor or a blocking engine thread.
final class HarnessCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func record(_ name: String) {
        lock.lock()
        storage[name, default: 0] += 1
        lock.unlock()
    }

    func adjust(_ name: String, by delta: Int) {
        lock.lock()
        storage[name, default: 0] += delta
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage[name, default: 0]
    }
}

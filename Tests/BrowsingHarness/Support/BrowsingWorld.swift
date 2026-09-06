import Foundation
import SpottyDomain
@testable import SpottyCore

/// One lock owns every mutable port value, including the synchronous engine boundary.
/// This world is deliberately read-only: unsupported commands fail rather than simulate success.
final class BrowsingWorld: AccountSession, CatalogProviding, PlaylistMutating, TrackAttributesProviding,
    RemotePlaybackClient, LocalPlaybackEngine, WebQueueClient, AudioOutputPreparing,
    PlaybackPreferences, SystemLifecycleEvents, PlaybackClock, @unchecked Sendable
{
    let scenario: BrowsingScenario
    let fixtures: BrowsingFixtures
    private let lock = NSLock()
    private var trace: [String] = []
    private var requestCounts: [String: Int] = [:]
    private var mutationAttempts = 0
    private var shuffle = false
    private var lastDevice: String?
    private var history: [String: TimeInterval] = [:]
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    struct Snapshot: Codable, Equatable, Sendable {
        let requests: [String: Int]
        let mutationAttempts: Int
        let trace: [String]
    }

    init(scenario: BrowsingScenario, artworkDirectory: URL) throws {
        self.scenario = scenario
        fixtures = try BrowsingFixtures(scenario: scenario, artworkDirectory: artworkDirectory)
    }

    var environment: PlaybackEnvironment {
        PlaybackEnvironment(
            remote: self, local: self, webQueue: self, account: self, audioOutput: self,
            preferences: self, lifecycle: self, clock: self, catalog: self,
            playlistMutations: self, trackAttributes: self
        )
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                requests: requestCounts, mutationAttempts: mutationAttempts,
                trace: trace)
        }
    }

    private func record(_ name: String) {
        lock.withLock {
            requestCounts[name, default: 0] += 1
            if trace.count < 256 { trace.append(name) }
        }
    }

    private func rejectMutation() -> BrowsingFailure {
        lock.withLock { mutationAttempts += 1 }
        return .unsupportedAction
    }

    func hasGrant() async -> Bool { record("account.has-grant"); return scenario.mode == .browsing }
    func authorizeInteractively() async throws -> KeymasterTokens { throw rejectMutation() }
    func accessToken() async throws -> String { throw BrowsingFailure.unsupportedAction }
    func adopt(_: KeymasterTokens) async throws { throw rejectMutation() }
    func clear() async { _ = rejectMutation() }
    func revocations() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func prepareForPlayback() throws { record("audio.no-device") }
    func events() -> AsyncStream<RustPlaybackEventEnvelope> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<SystemLifecycleEvent> { AsyncStream { $0.finish() } }
    func initialize() -> PlaybackEngineResult { record("engine.synthetic-initialize"); return .ok }
    func authorizeStreaming(with _: String) -> Int32 { _ = rejectMutation(); return -1 }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { _ = rejectMutation(); return .error }
    func positionMilliseconds() -> UInt32 { 0 }
    func shutdown() -> PlaybackEngineResult { record("engine.synthetic-shutdown"); return .ok }
    func cleanup() {}
    func clearStreamingCredentials() { _ = rejectMutation() }
    func disconnect() -> PlaybackEngineResult { _ = rejectMutation(); return .error }
    func forceReconnect() -> Int32 { _ = rejectMutation(); return -1 }
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws { throw rejectMutation() }
    func trackMetadata(for _: String) async throws -> SpotifyConnectTrackMetadata {
        throw BrowsingFailure.unsupportedAction
    }
    func queue() async throws -> [CatalogTrack] { [] }
    func shuffleEnabled() async -> Bool { lock.withLock { shuffle } }
    func setShuffleEnabled(_ value: Bool) async { lock.withLock { shuffle = value } }
    func lastRemoteDeviceID() async -> String? { lock.withLock { lastDevice } }
    func setLastRemoteDeviceID(_ value: String?) async { lock.withLock { lastDevice = value } }
    func shuffleHistory() async -> [String: TimeInterval] { lock.withLock { history } }
    func setShuffleHistory(_ value: [String: TimeInterval]) async { lock.withLock { history = value } }
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    /// Browsing has no playback time events. Park background timers until their owner cancels.
    func sleep(seconds _: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func home() async throws -> PathfinderHome { record("home"); return fixtures.home }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { record("library"); return fixtures.playlists }
    func profile() async throws -> PathfinderProfile {
        PathfinderProfile(username: "synthetic", name: "Synthetic Listener", uri: "spotify:user:synthetic", avatar: nil)
    }
    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        record("playlist.\(id)")
        guard let result = fixtures.details[id] else { throw BrowsingFailure.unsupportedAction }
        return result
    }
    func libraryAlbums() async throws -> [PathfinderAlbum] { [] }
    func libraryArtists() async throws -> [PathfinderArtist] { [] }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { [] }
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { [] }
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
    func addToPlaylist(playlistId _: String, trackUris _: [String]) async throws { throw rejectMutation() }
    func removeFromPlaylist(playlistId _: String, uids _: [String]) async throws { throw rejectMutation() }
}

import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

@Suite("Account Reauthentication Persistence")
struct AccountReauthenticationPersistenceTests {
    @Test @MainActor
    func testRestoreRecoversFromTransientStartupFailuresWithoutBrowserAuthorization() async {
        let account = ReauthenticationAccount(marker: false)
        let engine = ReauthenticationEngine(results: [.error, .error, .ok])
        let remote = ReauthenticationRemote()
        let environment = ReauthenticationEnvironment.make(account: account, engine: engine, remote: remote)
        let store = AccountStore(
            environment: environment, coordinator: PlaybackCoordinator(local: engine, remote: remote))

        await store.restore()

        #expect(store.phase == .ready)
        #expect(engine.initializeCount == 3)
        #expect(account.authorizeCount == 0)
        #expect(!account.marker)
        #expect(account.clearCount == 0)
    }

    @Test @MainActor
    func testRestoreRetryBudgetExhaustsWithoutDiscardingSavedGrant() async {
        let account = ReauthenticationAccount(marker: false)
        let engine = ReauthenticationEngine(results: Array(repeating: .error, count: 6))
        let remote = ReauthenticationRemote()
        let environment = ReauthenticationEnvironment.make(account: account, engine: engine, remote: remote)
        let store = AccountStore(
            environment: environment, coordinator: PlaybackCoordinator(local: engine, remote: remote))

        await store.restore()

        #expect(store.phase == .failed("Spotty Connect could not start (-1)"))
        #expect(engine.initializeCount == 6)
        #expect(account.authorizeCount == 0)
        #expect(!account.marker)
        #expect(account.clearCount == 0)
    }

    @Test @MainActor
    func testLogoutCancelsPendingRestoreRetry() async {
        let account = ReauthenticationAccount(marker: false)
        let engine = ReauthenticationEngine(results: [.error, .ok])
        let remote = ReauthenticationRemote()
        let clock = CooperativeParkedClock()
        let environment = ReauthenticationEnvironment.make(
            account: account, engine: engine, remote: remote, clock: clock)
        let store = AccountStore(
            environment: environment, coordinator: PlaybackCoordinator(local: engine, remote: remote))
        let restoration = Task { await store.restore() }
        #expect(await waitUntil { clock.waiterCount == 1 })

        await store.logout()
        await restoration.value

        #expect(store.phase == .signedOut)
        #expect(engine.initializeCount == 1)
        #expect(clock.waiterCount == 0)
        #expect(account.clearCount == 1)
    }

    @Test @MainActor
    func testMarkerRoundTripsAndFreshAdoptionClearsIt() async {
        let store = ReauthenticationGrantStore()
        let initial = reauthenticationTokens(access: "access-a", refresh: "refresh-a")
        let session = KeymasterSession(store: store, cookieCleanup: {})

        try? await session.adopt(initial)
        #expect((await session.reauthenticationRequired()) == false, "a fresh grant starts usable")

        await session.markReauthenticationRequired()
        #expect((store.stored?.requiresReauthentication) == true, "rejection marker is durable")
        #expect((await session.reauthenticationRequired()) == true, "the live session retains the marker")
        if let persisted = store.stored,
            let encoded = try? JSONEncoder().encode(persisted),
            let decoded = try? JSONDecoder().decode(KeymasterTokens.self, from: encoded)
        {
            #expect((decoded.requiresReauthentication) == true, "the persisted codec retains the marker")
        } else {
            Issue.record("the persisted grant marker must round-trip through Codable")
        }

        do {
            let data = try JSONEncoder().encode(initial)
            var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "requiresReauthentication")
            let decoded = try JSONDecoder().decode(
                KeymasterTokens.self, from: JSONSerialization.data(withJSONObject: legacy)
            )
            #expect(!decoded.requiresReauthentication, "older saved grants remain readable")
        } catch {
            Issue.record("legacy grant decoding failed: \(error)")
        }

        let restored = KeymasterSession(store: store, cookieCleanup: {})
        #expect((await restored.reauthenticationRequired()) == true, "a new session restores the marker")

        try? await restored.adopt(reauthenticationTokens(access: "access-b", refresh: "refresh-b"))
        #expect((store.stored?.requiresReauthentication) == false, "a successful fresh adoption clears it")
        #expect((await restored.reauthenticationRequired()) == false, "the live replacement is usable")

        await restored.markReauthenticationRequired()
        await restored.clear()
        #expect((store.stored) == nil, "explicit grant clear removes the marker with the grant")
    }

    @Test @MainActor
    func testMarkerSurvivesRotatingRefresh() async throws {
        let store = ReauthenticationGrantStore()
        let session = KeymasterSession(
            store: store,
            refresher: { refreshToken in
                reauthenticationTokens(
                    access: "rotated-access",
                    refresh: "rotated-\(refreshToken)"
                )
            },
            cookieCleanup: {}
        )
        var initial = reauthenticationTokens(access: "access-a", refresh: "refresh-a")
        initial.expiresAt = Date(timeIntervalSince1970: 1)

        try await session.adopt(initial)
        await session.markReauthenticationRequired()

        #expect((try await session.accessToken(now: Date(timeIntervalSince1970: 1_000))) == "rotated-access")
        #expect((store.stored?.refreshToken) == "rotated-refresh-a", "refresh rotation is durable")
        #expect((store.stored?.requiresReauthentication) == true, "refresh preserves the rejection marker")
    }

    @Test @MainActor
    func testMarkerAbortsWhenFreshAdoptionCommitsDuringInitialLoad() async {
        let initial = reauthenticationTokens(access: "access-old", refresh: "refresh-old")
        let replacement = reauthenticationTokens(access: "access-new", refresh: "refresh-new")
        let store = GatedReauthenticationGrantStore(initial: initial)
        let session = KeymasterSession(store: store, cookieCleanup: {})

        let marker = Task { await session.markReauthenticationRequired() }
        await store.waitUntilLoadEntered()

        let adoption = Task { try? await session.adopt(replacement) }
        store.releaseLoad()

        await marker.value
        await adoption.value

        #expect((store.stored?.accessToken) == (replacement.accessToken))
        #expect((store.stored?.refreshToken) == (replacement.refreshToken))
        #expect((store.stored?.requiresReauthentication) == false, "a stale marker must not overwrite a fresh grant")
        #expect((await session.reauthenticationRequired()) == false, "the live replacement remains usable")
    }

    @Test @MainActor
    func testFailedMarkerSaveRetriesAndFailedAdoptionRetainsMarker() async {
        let initial = reauthenticationTokens(access: "access-a", refresh: "refresh-a")
        let store = ReauthenticationGrantStore(initial: initial, saveFailures: 1)
        let session = KeymasterSession(store: store, cookieCleanup: {})

        await session.markReauthenticationRequired()
        #expect(
            (await session.reauthenticationRequired()) == true, "a failed marker save still blocks the live session")
        #expect((store.stored?.requiresReauthentication) == false, "a failed save does not claim durable state")

        await session.markReauthenticationRequired()
        #expect((store.stored?.requiresReauthentication) == true, "a later marker call retries persistence")
        #expect((store.saveCount) == (2), "the marker was attempted again")

        store.failNextSave()
        try? await session.adopt(reauthenticationTokens(access: "access-b", refresh: "refresh-b"))
        #expect((store.stored?.accessToken) == (initial.accessToken), "a failed adoption preserves the durable grant")
        #expect((store.stored?.requiresReauthentication) == true, "a failed adoption preserves the durable marker")
        #expect((await session.reauthenticationRequired()) == true, "a failed adoption preserves the live marker")
        #expect((store.saveCount) == (3), "the failed adoption attempted its save")
    }

    @Test @MainActor
    func testRestoreStopsOnTypedInitializationRejectionAndRestartHonorsMarker() async {
        let account = ReauthenticationAccount(marker: false)
        let engine = ReauthenticationEngine(results: [.credentialsRejected, .ok])
        let remote = ReauthenticationRemote()
        let environment = ReauthenticationEnvironment.make(account: account, engine: engine, remote: remote)
        let firstCoordinator = PlaybackCoordinator(local: engine, remote: remote)
        let firstStore = AccountStore(environment: environment, coordinator: firstCoordinator)

        await firstStore.restore()
        #expect(
            (firstStore.phase) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
            "typed initialization rejection has stable actionable presentation"
        )
        #expect((firstStore.requiresReauthentication) == true, "typed rejection sets the account marker")
        #expect((account.marker) == true, "typed rejection persists the account marker")
        #expect((account.markCount) == (1), "typed rejection is persisted once")
        #expect((account.authorizeCount) == (0), "restore never opens a browser for a retained grant")
        #expect((engine.initializeCount) == (1), "restore performs one typed failing initialization")

        let secondCoordinator = PlaybackCoordinator(local: engine, remote: remote)
        let secondStore = AccountStore(environment: environment, coordinator: secondCoordinator)
        await secondStore.restore()
        #expect((secondStore.requiresReauthentication) == true, "restart restores the durable marker")
        #expect(
            (secondStore.phase) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
            "restart does not retry the rejected streaming credential"
        )
        #expect((engine.initializeCount) == (1), "restart does not initialize a known-rejected session")
        #expect((account.authorizeCount) == (0), "restart does not authorize implicitly")

        secondStore.connect()
        #expect(
            (await waitUntil { secondStore.phase == .ready }) == true,
            "explicit connect completes a fresh authorization"
        )
        #expect((account.authorizeCount) == (1), "explicit connect opens the browser")
        #expect((account.marker) == false, "successful adoption clears the durable marker")
        #expect((secondStore.requiresReauthentication) == false, "successful adoption clears the local marker")
        #expect((engine.initializeCount) == (2), "the replacement initializes once")

        await secondStore.logout()
        #expect((account.clearCount) == (1), "explicit logout clears the retained grant")
        #expect((account.marker) == false, "explicit logout leaves no reauthentication marker")
    }
}

private func reauthenticationTokens(access: String, refresh: String) -> KeymasterTokens {
    KeymasterTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: Date().addingTimeInterval(3_600),
        username: "listener"
    )
}

private final class ReauthenticationGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var saveFailuresRemaining: Int
    private var saveStorage = 0

    init(initial: KeymasterTokens? = nil, saveFailures: Int = 0) {
        value = initial
        saveFailuresRemaining = saveFailures
    }

    var stored: KeymasterTokens? { lock.withLock { value } }
    var saveCount: Int { lock.withLock { saveStorage } }

    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        try lock.withLock {
            saveStorage += 1
            if saveFailuresRemaining > 0 {
                saveFailuresRemaining -= 1
                throw ReauthenticationPersistenceFailure.saveRejected
            }
            value = tokens
        }
    }

    func failNextSave() {
        lock.withLock { saveFailuresRemaining += 1 }
    }

    func clear() { lock.withLock { value = nil } }
}

private final class GatedReauthenticationGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadGate = DispatchSemaphore(value: 0)
    private var value: KeymasterTokens?
    private var loadEntered = false
    private var loadWaiter: CheckedContinuation<Void, Never>?

    init(initial: KeymasterTokens) {
        value = initial
    }

    var stored: KeymasterTokens? { lock.withLock { value } }

    func loadResult() -> KeymasterGrantLoadResult {
        let (snapshot, waiter) = lock.withLock {
            let waiter = loadWaiter
            loadWaiter = nil
            loadEntered = true
            return (value, waiter)
        }
        waiter?.resume()
        loadGate.wait()
        return snapshot.map(KeymasterGrantLoadResult.found) ?? .absent
    }

    func waitUntilLoadEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if loadEntered {
                    return true
                }
                loadWaiter = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func releaseLoad() {
        loadGate.signal()
    }

    func save(_ tokens: KeymasterTokens) throws { lock.withLock { value = tokens } }
    func clear() { lock.withLock { value = nil } }
}

private final class ReauthenticationAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var markerStorage: Bool
    private var authorizeStorage = 0
    private var clearStorage = 0
    private var markStorage = 0

    init(marker: Bool) {
        markerStorage = marker
    }

    var marker: Bool { lock.withLock { markerStorage } }
    var authorizeCount: Int { lock.withLock { authorizeStorage } }
    var clearCount: Int { lock.withLock { clearStorage } }
    var markCount: Int { lock.withLock { markStorage } }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.withLock { authorizeStorage += 1 }
        return reauthenticationTokens(access: "fresh-access", refresh: "fresh-refresh")
    }

    func hasGrant() async -> Bool { true }
    func grantState() async -> KeymasterGrantState { .available }
    func reauthenticationRequired() async -> Bool { marker }
    func markReauthenticationRequired() async {
        lock.withLock {
            markerStorage = true
            markStorage += 1
        }
    }
    func accessToken() async throws -> String { "existing-access" }
    func adopt(_: KeymasterTokens) async throws { lock.withLock { markerStorage = false } }
    func clear() async {
        lock.withLock {
            clearStorage += 1
            markerStorage = false
        }
    }
    func revocations() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class ReauthenticationEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PlaybackEngineResult]
    private var initializeStorage = 0

    init(results: [PlaybackEngineResult]) {
        self.results = results
    }

    var initializeCount: Int { lock.withLock { initializeStorage } }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> { AsyncStream { $0.finish() } }
    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult {
        lock.withLock {
            initializeStorage += 1
            return results.isEmpty ? .ok : results.removeFirst()
        }
    }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private struct ReauthenticationRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(uri: uri, title: "Track", artist: "Artist", artworkURL: nil, duration: 180)
    }
}

private struct ReauthenticationWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] { [] }
}

private struct ReauthenticationAudio: AudioOutputPreparing {
    func prepareForPlayback() throws {}
}

private actor ReauthenticationPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct ReauthenticationLifecycle: SystemLifecycleEvents {
    func events() -> AsyncStream<SystemLifecycleEvent> { AsyncStream { $0.finish() } }
}

private struct ReauthenticationClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}

private struct ReauthenticationCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw TestUnavailable.error }
    func home() async throws -> PathfinderHome { throw TestUnavailable.error }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw TestUnavailable.error }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw TestUnavailable.error }
    func libraryArtists() async throws -> [PathfinderArtist] { throw TestUnavailable.error }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw TestUnavailable.error }
    func profile() async throws -> PathfinderProfile { throw TestUnavailable.error }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw TestUnavailable.error }
}

private struct ReauthenticationAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum TestUnavailable: Error {
    case error
}

private enum ReauthenticationPersistenceFailure: Error {
    case saveRejected
}

private enum ReauthenticationEnvironment {
    static func make(
        account: any AccountSession,
        engine: any LocalPlaybackEngine,
        remote: any RemotePlaybackClient,
        clock: any PlaybackClock = ReauthenticationClock()
    ) -> PlaybackEnvironment {
        PlaybackEnvironment(
            remote: remote,
            local: engine,
            webQueue: ReauthenticationWebQueue(),
            account: account,
            audioOutput: ReauthenticationAudio(),
            preferences: ReauthenticationPreferences(),
            lifecycle: ReauthenticationLifecycle(),
            clock: clock,
            catalog: ReauthenticationCatalog(),
            playlistMutations: UnavailablePlaylistMutations(),
            trackAttributes: ReauthenticationAttributes()
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

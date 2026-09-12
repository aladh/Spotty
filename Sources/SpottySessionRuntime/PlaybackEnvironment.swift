import SpottyDomain
import SpottyEngineAdapter
import SpottyGateway
import SpottyRuntimeContracts
import Foundation

/// Account-scoped metadata requests are shared by Now Playing and queue hydration. The actor
/// coalesces identical in-flight requests and retains only a bounded cache for the current account.
actor TrackMetadataService {
    private struct InFlightRequest {
        let generation: UInt64
        let id: UInt64
        let task: Task<SpotifyConnectTrackMetadata, any Error>
    }

    private static let cacheLimit = 512

    private let remote: any RemotePlaybackClient
    private var cache: [String: SpotifyConnectTrackMetadata] = [:]
    private var generation: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var inFlight: [String: InFlightRequest] = [:]

    init(remote: any RemotePlaybackClient) {
        self.remote = remote
    }

    func metadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        if let cached = cache[uri] { return cached }
        if let request = inFlight[uri] { return try await request.task.value }

        let task = Task { [remote] in try await remote.trackMetadata(for: uri) }
        nextRequestID &+= 1
        let request = InFlightRequest(generation: generation, id: nextRequestID, task: task)
        inFlight[uri] = request
        do {
            let value = try await task.value
            if let current = inFlight[uri],
                current.id == request.id,
                current.generation == request.generation
            {
                inFlight[uri] = nil
                cache[uri] = value
                trimCache(preserving: uri)
            }
            return value
        } catch {
            if let current = inFlight[uri],
                current.id == request.id,
                current.generation == request.generation
            {
                inFlight[uri] = nil
            }
            throw error
        }
    }

    func reset() {
        generation &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
    }

    private func trimCache(preserving uri: String) {
        guard cache.count > Self.cacheLimit else { return }
        for key in cache.keys where key != uri {
            cache[key] = nil
            if cache.count <= Self.cacheLimit { break }
        }
    }
}

package nonisolated protocol AudioOutputPreparing: Sendable {
    func prepareForPlayback() throws
}

package nonisolated struct LiveAudioOutput: AudioOutputPreparing {
    package func prepareForPlayback() throws {
        try spottyAudioRendererResult.get().setVolume(1)
    }
}

package nonisolated protocol PlaybackPreferences: Sendable {
    func shuffleEnabled() async -> Bool
    func setShuffleEnabled(_ enabled: Bool) async
    func lastRemoteDeviceID() async -> String?
    func setLastRemoteDeviceID(_ id: String?) async
    func shuffleHistory() async -> [String: TimeInterval]
    func setShuffleHistory(_ history: [String: TimeInterval]) async
}

package nonisolated final class UserDefaultsPlaybackPreferences: PlaybackPreferences, @unchecked Sendable {
    package static let shared = UserDefaultsPlaybackPreferences()

    private enum Key {
        static let shuffle = "playback.shuffle.fewer-repeats"
        static let remoteDevice = "playback.last-remote-device-id"
        static let history = "playback.fewer-repeats.history"
    }

    package static let persistedKeys = [Key.shuffle, Key.remoteDevice, Key.history]

    private let defaults: UserDefaults
    private let lock = NSLock()

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func shuffleEnabled() -> Bool { lock.withLock { defaults.bool(forKey: Key.shuffle) } }

    package func setShuffleEnabled(_ enabled: Bool) {
        lock.withLock { defaults.set(enabled, forKey: Key.shuffle) }
    }

    package func lastRemoteDeviceID() -> String? {
        lock.withLock { defaults.string(forKey: Key.remoteDevice) }
    }

    package func setLastRemoteDeviceID(_ id: String?) {
        if let id {
            lock.withLock { defaults.set(id, forKey: Key.remoteDevice) }
        } else {
            lock.withLock { defaults.removeObject(forKey: Key.remoteDevice) }
        }
    }

    package func shuffleHistory() -> [String: TimeInterval] {
        guard
            let data = lock.withLock({ defaults.data(forKey: Key.history) }),
            let history = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return history
    }

    package func setShuffleHistory(_ history: [String: TimeInterval]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        lock.withLock { defaults.set(data, forKey: Key.history) }
    }
}

package nonisolated enum SystemLifecycleEvent: Sendable {
    case willSleep
    case didWake
}

package nonisolated protocol SystemLifecycleEvents: Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent>
}

package nonisolated struct PlaybackEnvironment: Sendable {
    let remote: any RemotePlaybackClient
    let local: any LocalPlaybackEngine
    let webQueue: any WebQueueClient
    let account: any AccountSession
    let audioOutput: any AudioOutputPreparing
    package let artwork: any ArtworkProviding
    let preferences: any PlaybackPreferences
    package let lifecycle: any SystemLifecycleEvents
    package let clock: any PlaybackClock
    package let catalog: any CatalogProviding
    package let playlistMutations: any PlaylistMutating
    let playlistMutationAdmission: PlaylistMutationAdmission
    package let trackAttributes: any TrackAttributesProviding
    let queueServiceHook: (any QueueServiceHook)?
    let catalogCacheLifecycle: (any CatalogCacheLifecycle)?

    /// Hand-written so checks can pass a hook. A defaulted stored property is
    /// dropped from the synthesized memberwise initializer, which then rejects
    /// `queueServiceHook:` as an extra argument.
    init(
        remote: any RemotePlaybackClient,
        local: any LocalPlaybackEngine,
        webQueue: any WebQueueClient,
        account: any AccountSession,
        audioOutput: any AudioOutputPreparing,
        preferences: any PlaybackPreferences,
        lifecycle: any SystemLifecycleEvents,
        clock: any PlaybackClock,
        catalog: any CatalogProviding,
        playlistMutations: any PlaylistMutating,
        trackAttributes: any TrackAttributesProviding,
        queueServiceHook: (any QueueServiceHook)? = nil,
        catalogCacheLifecycle: (any CatalogCacheLifecycle)? = nil,
        artwork: any ArtworkProviding = UnavailableArtworkProvider()
    ) {
        self.remote = remote
        self.local = local
        self.webQueue = webQueue
        self.account = account
        self.audioOutput = audioOutput
        self.artwork = artwork
        self.preferences = preferences
        self.lifecycle = lifecycle
        self.clock = clock
        self.catalog = catalog
        let mutationAdmission = PlaylistMutationAdmission()
        playlistMutationAdmission = mutationAdmission
        self.playlistMutations = AccountScopedPlaylistMutations(source: playlistMutations, admission: mutationAdmission)
        self.trackAttributes = trackAttributes
        self.queueServiceHook = queueServiceHook
        self.catalogCacheLifecycle = catalogCacheLifecycle
    }

    package static func live(
        openAuthorizationURL: @escaping @Sendable (URL) async -> Bool,
        lifecycle: any SystemLifecycleEvents
    ) -> PlaybackEnvironment {
        let services = SpotifyGatewayServices(openAuthorizationURL: openAuthorizationURL)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotty/Catalog", isDirectory: true)
        let catalog = PersistentCatalogProvider(source: services.catalog, rootDirectory: root)
        return PlaybackEnvironment(
            remote: services.remote,
            local: RustPlaybackEngine.shared,
            webQueue: services.webQueue,
            account: services.account,
            audioOutput: LiveAudioOutput(),
            preferences: UserDefaultsPlaybackPreferences.shared,
            lifecycle: lifecycle,
            clock: SystemPlaybackClock(),
            catalog: catalog,
            playlistMutations: services.playlistMutations,
            trackAttributes: services.trackAttributes,
            catalogCacheLifecycle: catalog,
            artwork: ArtworkPipeline()
        )
    }

}

/// Serial owner for local blocking commands and remote network commands. The runtime receives
/// command outcomes; blocking engine work stays off the transition executor and MainActor.
actor PlaybackCoordinator {
    private let local: any LocalPlaybackEngine
    private let remote: any RemotePlaybackClient
    private let metadataService: TrackMetadataService

    func prepareAudioOutput(_ output: any AudioOutputPreparing) throws {
        try output.prepareForPlayback()
    }

    init(
        local: any LocalPlaybackEngine,
        remote: any RemotePlaybackClient,
        metadataService: TrackMetadataService? = nil
    ) {
        self.local = local
        self.remote = remote
        self.metadataService = metadataService ?? TrackMetadataService(remote: remote)
    }

    func performLocal(_ operation: LocalPlaybackOperation) async -> PlaybackEngineResult {
        local.execute(operation)
    }

    /// Executes only if the operation is still wanted once this actor actually reaches it.
    ///
    /// A queued operation can wait behind another local command; by then the runtime may have
    /// changed engine generation or the condition that requested it may have lapsed.
    /// `isStillWanted` is evaluated on SessionRuntimeActor immediately before execution and is an
    /// early-out, not the guarantee: nothing serializes the hop back with `execute`, so
    /// operations that must not run late also carry a token the engine enforces (see
    /// `.rehydrate`). Returns nil when the operation was skipped.
    func performLocalIfStillWanted(
        _ operation: LocalPlaybackOperation,
        isStillWanted: @SessionRuntimeActor @Sendable () -> Bool
    ) async -> PlaybackEngineResult? {
        if Task.isCancelled { return nil }
        guard await isStillWanted() else { return nil }
        return local.execute(operation)
    }

    /// Maps a local engine integer into a typed command outcome. Throws only if this task
    /// was cancelled; operational failures are `Result` values.
    func performLocalCommand(
        _ operation: LocalPlaybackOperation
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure> {
        if Task.isCancelled { throw CancellationError() }
        let outcome = PlaybackCommandFailure.from(engineResult: local.execute(operation))
        if Task.isCancelled { throw CancellationError() }
        return outcome
    }

    /// Claims a lock-linearized dispatch permit immediately before entering local C work. A
    /// failed claim means the store invalidated this queued command before it reached the engine.
    func performLocalCommand(
        _ operation: LocalPlaybackOperation,
        permit: PlaybackDispatchPermit
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure>? {
        if Task.isCancelled { throw CancellationError() }
        guard permit.claim() else { return nil }
        let outcome = PlaybackCommandFailure.from(engineResult: local.execute(operation))
        if Task.isCancelled { throw CancellationError() }
        return outcome
    }

    func authorizeStreaming(with token: String) async -> Int32 {
        local.authorizeStreaming(with: token)
    }

    func initializeEngine() async -> PlaybackEngineResult {
        local.initialize()
    }

    func shutdownEngine() async -> PlaybackEngineResult {
        local.shutdown()
    }

    func cleanupEngine() { local.cleanup() }
    func clearStreamingCredentials() { local.clearStreamingCredentials() }
    func positionMilliseconds() -> UInt32 { local.positionMilliseconds() }
    func resumePositionMilliseconds() -> UInt32 { local.resumePositionMilliseconds() }
    func queueSnapshot() -> RustQueueState? { local.queueSnapshot() }
    func disconnect() async -> PlaybackEngineResult {
        local.disconnect()
    }
    func forceReconnect() async -> Int32 {
        // A replaced or account-cancelled recovery task must not reach the engine once it
        // finally gets its turn on this actor.
        guard !Task.isCancelled else { return PlaybackEngineResult.error.rawValue }
        return local.forceReconnect()
    }

    func performRemote(
        _ command: SpotifyConnectCommand,
        from sourceID: String,
        to targetID: String
    ) async throws {
        try await remote.send(command, from: sourceID, to: targetID)
    }

    func metadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        try await metadataService.metadata(for: uri)
    }

    /// Maps an arbitrary remote `Error` into a typed command outcome. `CancellationError`
    /// (including cancellation surfaced as another error while `Task.isCancelled`) is rethrown
    /// and is never an operational failure.
    func performRemoteCommand(
        _ operation: @escaping @Sendable (any RemotePlaybackClient) async throws -> Void
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure> {
        if Task.isCancelled { throw CancellationError() }
        do {
            try await operation(remote)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.remoteRejected)
        }
        if Task.isCancelled { throw CancellationError() }
        return .success(())
    }

    /// Claims a dispatch permit immediately before entering the remote client. After the claim,
    /// the request may be in flight and later route invalidation cannot revoke it.
    func performRemoteCommand(
        _ operation: @escaping @Sendable (any RemotePlaybackClient) async throws -> Void,
        permit: PlaybackDispatchPermit
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure>? {
        if Task.isCancelled { throw CancellationError() }
        guard permit.claim() else { return nil }
        do {
            try await operation(remote)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.remoteRejected)
        }
        if Task.isCancelled { throw CancellationError() }
        return .success(())
    }
}

/// A lock-linearized commitment shared by the transition owner and the coordinator actor. Before
/// `claim` succeeds, a lifecycle or route publication can invalidate queued work. Once `claim`
/// succeeds, the operation has crossed the point where it may be sent to the engine or Spotify;
/// later invalidation cannot revoke that already-started work.
final class PlaybackDispatchPermit: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case invalidated
        case claimed
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var receipt: Date?
    private let clock: any PlaybackClock

    init(clock: any PlaybackClock = SystemPlaybackClock()) { self.clock = clock }

    func takeDispatchReceipt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        defer { receipt = nil }
        return receipt
    }

    func invalidate() {
        lock.lock()
        if state == .pending {
            state = .invalidated
        }
        lock.unlock()
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else { return false }
        state = .claimed
        receipt = clock.now()
        return true
    }

    var canDiscard: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .pending && receipt == nil
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .pending
    }
}

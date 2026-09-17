import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyGateway
import SpottyRuntimeContracts

// MARK: - Remote playback

/// The default Connect client for boundary checks. Sends succeed and are recorded; metadata
/// resolves immediately. A check overrides the one behavior it is about.
final class HarnessRemote: RemotePlaybackClient, @unchecked Sendable {
    /// What `send` does once the command has been recorded.
    enum SendBehavior: Sendable {
        case succeed
        case fail
        /// Fails every send after the first `limit` sends.
        case failAfter(Int)
        /// Suspends until `completePark(success:)`; cancellation throws `CancellationError`.
        case park
        /// Suspends for a minute, so only cancellation ends it.
        case sleepUntilCancelled
    }

    /// What `trackMetadata` does once the request has been recorded.
    enum MetadataBehavior: Sendable {
        case immediate
        /// Suspends until `completeMetadata(title:)`.
        case park
    }

    private struct Storage {
        struct MetadataPark {
            let id: UInt64
            let continuation: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>
        }

        var commands: [SpotifyConnectCommand] = []
        var requestedURIs: [String] = []
        var sendBehavior = SendBehavior.succeed
        var metadataBehavior = MetadataBehavior.immediate
        var metadataTitle = "Metadata"
        var sendParks: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var metadataParks: [String: MetadataPark] = [:]
        var nextParkID: UInt64 = 0
        var activeMetadataRequests = 0
        var maximumActiveMetadataRequests = 0
        var onSend: (@Sendable (SpotifyConnectCommand, String, String) async throws -> Void)?
        var onMetadata: (@Sendable (String) async throws -> SpotifyConnectTrackMetadata)?
    }

    private let lock = NSLock()
    private var storage = Storage()

    init(
        send: SendBehavior = .succeed,
        metadata: MetadataBehavior = .immediate,
        metadataTitle: String = "Metadata"
    ) {
        storage.sendBehavior = send
        storage.metadataBehavior = metadata
        storage.metadataTitle = metadataTitle
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    var sendBehavior: SendBehavior {
        get { withStorage { $0.sendBehavior } }
        set { withStorage { $0.sendBehavior = newValue } }
    }

    var metadataBehavior: MetadataBehavior {
        get { withStorage { $0.metadataBehavior } }
        set { withStorage { $0.metadataBehavior = newValue } }
    }

    var onSend: (@Sendable (SpotifyConnectCommand, String, String) async throws -> Void)? {
        get { withStorage { $0.onSend } }
        set { withStorage { $0.onSend = newValue } }
    }

    var onMetadata: (@Sendable (String) async throws -> SpotifyConnectTrackMetadata)? {
        get { withStorage { $0.onMetadata } }
        set { withStorage { $0.onMetadata = newValue } }
    }

    // MARK: Observation

    var commands: [SpotifyConnectCommand] { withStorage { $0.commands } }
    var sendCount: Int { withStorage { $0.commands.count } }
    var endpoints: [SpotifyConnectCommand.Kind] { commands.map(\.endpoint) }
    var requestedURIs: [String] { withStorage { $0.requestedURIs } }
    var requestedURI: String? { requestedURIs.last }
    var activeMetadataRequests: Int { withStorage { $0.activeMetadataRequests } }
    var maximumActiveMetadataRequests: Int { withStorage { $0.maximumActiveMetadataRequests } }
    var parkedMetadataRequestCount: Int { withStorage { $0.metadataParks.count } }
    var parkedMetadataURIs: Set<String> { withStorage { Set($0.metadataParks.keys) } }
    var parkedSendCount: Int { withStorage { $0.sendParks.count } }

    /// Releases the oldest parked send.
    @discardableResult
    func completePark(success: Bool) -> Bool {
        let parked = withStorage { storage -> CheckedContinuation<Void, any Error>? in
            guard let id = storage.sendParks.keys.min() else { return nil }
            return storage.sendParks.removeValue(forKey: id)
        }
        guard let parked else { return false }
        if success {
            parked.resume()
        } else {
            parked.resume(throwing: HarnessFailure.unavailable)
        }
        return true
    }

    /// Releases the parked metadata request for `uri`, or the only parked request when omitted.
    @discardableResult
    func completeMetadata(for uri: String? = nil, title: String? = nil) -> Bool {
        let resolved = withStorage { storage -> (String, Storage.MetadataPark)? in
            let key = uri ?? storage.metadataParks.keys.sorted().first
            guard let key, let parked = storage.metadataParks.removeValue(forKey: key) else { return nil }
            storage.activeMetadataRequests -= 1
            return (key, parked)
        }
        guard let resolved else { return false }
        let resolvedTitle = title ?? withStorage { $0.metadataTitle }
        resolved.1.continuation.resume(
            returning: HarnessFixtures.metadata(uri: resolved.0, title: resolvedTitle))
        return true
    }

    @discardableResult
    func failMetadata(for uri: String? = nil, error: any Error = HarnessFailure.unavailable) -> Bool {
        let parked = withStorage { storage -> Storage.MetadataPark? in
            let key = uri ?? storage.metadataParks.keys.sorted().first
            guard let key, let parked = storage.metadataParks.removeValue(forKey: key) else { return nil }
            storage.activeMetadataRequests -= 1
            return parked
        }
        guard let parked else { return false }
        parked.continuation.resume(throwing: error)
        return true
    }

    private func cancelMetadata(_ uri: String, id: UInt64) {
        let parked = withStorage { storage -> Storage.MetadataPark? in
            guard storage.metadataParks[uri]?.id == id else { return nil }
            let parked = storage.metadataParks.removeValue(forKey: uri)
            storage.activeMetadataRequests -= 1
            return parked
        }
        parked?.continuation.resume(throwing: CancellationError())
    }

    private func cancelSend(_ id: UInt64) {
        let parked = withStorage { $0.sendParks.removeValue(forKey: id) }
        parked?.resume(throwing: CancellationError())
    }

    // MARK: RemotePlaybackClient

    func send(_ command: SpotifyConnectCommand, from sourceID: String, to targetID: String) async throws {
        let behavior = withStorage { storage -> SendBehavior in
            storage.commands.append(command)
            return storage.sendBehavior
        }
        if let override = onSend {
            try await override(command, sourceID, targetID)
            return
        }
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw HarnessFailure.unavailable
        case let .failAfter(limit):
            if sendCount > limit { throw HarnessFailure.unavailable }
        case .sleepUntilCancelled:
            try await HarnessClock.parked().sleep(seconds: 60)
        case .park:
            let id = withStorage { storage -> UInt64 in
                storage.nextParkID &+= 1
                return storage.nextParkID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let cancelled = withStorage { storage -> Bool in
                        if Task.isCancelled { return true }
                        storage.sendParks[id] = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                self.cancelSend(id)
            }
        }
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        let behavior = withStorage { storage -> MetadataBehavior in
            storage.requestedURIs.append(uri)
            return storage.metadataBehavior
        }
        if let override = onMetadata { return try await override(uri) }
        switch behavior {
        case .immediate:
            return HarnessFixtures.metadata(uri: uri, title: withStorage { $0.metadataTitle })
        case .park:
            let id = withStorage { storage -> UInt64 in
                storage.nextParkID &+= 1
                return storage.nextParkID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>) in
                    enum Registration {
                        case parked
                        case cancelled
                        case duplicate
                    }
                    let registration = withStorage { storage -> Registration in
                        if Task.isCancelled { return .cancelled }
                        guard storage.metadataParks[uri] == nil else { return .duplicate }
                        storage.metadataParks[uri] = Storage.MetadataPark(id: id, continuation: continuation)
                        storage.activeMetadataRequests += 1
                        storage.maximumActiveMetadataRequests = max(
                            storage.maximumActiveMetadataRequests,
                            storage.activeMetadataRequests
                        )
                        return .parked
                    }
                    switch registration {
                    case .parked:
                        break
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .duplicate:
                        continuation.resume(throwing: HarnessFailure.unavailable)
                    }
                }
            } onCancel: {
                self.cancelMetadata(uri, id: id)
            }
        }
    }
}

// MARK: - Web queue

/// The default Web Player queue client. Unavailable by default, which is what a boundary check
/// that is not about the web fallback wants.
final class HarnessWebQueue: WebQueueClient, @unchecked Sendable {
    enum Behavior: Sendable {
        /// Throws `URLError(.badServerResponse)`.
        case unavailable
        /// Returns a fixed list.
        case tracks([CatalogTrack])
        /// Throws `SpotifyWebPlayerAPIError.requestFailed(429)`.
        case rateLimited
        /// Suspends until `complete(with:)` or `fail()`.
        case park
    }

    private struct Storage {
        var behavior = Behavior.unavailable
        var requestCount = 0
        var continuation: CheckedContinuation<[CatalogTrack], any Error>?
        var onQueue: (@Sendable () async throws -> [CatalogTrack])?
    }

    private let lock = NSLock()
    private var storage = Storage()

    init(_ behavior: Behavior = .unavailable) {
        storage.behavior = behavior
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var behavior: Behavior {
        get { withStorage { $0.behavior } }
        set { withStorage { $0.behavior = newValue } }
    }

    var onQueue: (@Sendable () async throws -> [CatalogTrack])? {
        get { withStorage { $0.onQueue } }
        set { withStorage { $0.onQueue = newValue } }
    }

    var requestCount: Int { withStorage { $0.requestCount } }
    var isParked: Bool { withStorage { $0.continuation != nil } }

    func complete(with tracks: [CatalogTrack]) {
        let parked = withStorage { storage -> CheckedContinuation<[CatalogTrack], any Error>? in
            let parked = storage.continuation
            storage.continuation = nil
            return parked
        }
        parked?.resume(returning: tracks)
    }

    func fail(_ error: (any Error)? = nil) {
        let parked = withStorage { storage -> CheckedContinuation<[CatalogTrack], any Error>? in
            let parked = storage.continuation
            storage.continuation = nil
            return parked
        }
        parked?.resume(throwing: error ?? SpotifyWebPlayerAPIError.requestFailed(429))
    }

    private func cancelPark() {
        let parked = withStorage { storage -> CheckedContinuation<[CatalogTrack], any Error>? in
            let parked = storage.continuation
            storage.continuation = nil
            return parked
        }
        parked?.resume(throwing: CancellationError())
    }

    func queue() async throws -> [CatalogTrack] {
        let behavior = withStorage { storage -> Behavior in
            storage.requestCount += 1
            return storage.behavior
        }
        if let override = onQueue { return try await override() }
        switch behavior {
        case .unavailable:
            throw URLError(.badServerResponse)
        case let .tracks(tracks):
            return tracks
        case .rateLimited:
            throw SpotifyWebPlayerAPIError.requestFailed(429)
        case .park:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[CatalogTrack], any Error>) in
                    let cancelled = withStorage { storage -> Bool in
                        if Task.isCancelled { return true }
                        storage.continuation = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                self.cancelPark()
            }
        }
    }
}

// MARK: - Account

/// The default account. No stored grant and a cancelled interactive authorization, so a store
/// reaches its unauthenticated states without a check scripting anything.
final class HarnessAccount: AccountSession, @unchecked Sendable {
    /// What `authorizeInteractively` does.
    enum Authorization: Sendable {
        /// Throws `CancellationError`, the interactive flow the user dismissed.
        case cancelled
        /// Returns `HarnessFixtures.tokens()`.
        case succeed
    }

    /// Whether `revocations()` publishes.
    enum Revocations: Sendable {
        case finished
        case live
    }

    private struct Storage {
        var hasStoredGrant = false
        var grantState: KeymasterGrantState?
        var reauthenticationRequired = false
        var authorization = Authorization.cancelled
        var authorizeCount = 0
        var clearCount = 0
        var clearSucceeds = true
        var markCount = 0
        var parkGrantRead = false
        var grantReadPark: CheckedContinuation<Void, Never>?
        var parkClear = false
        var clearPark: CheckedContinuation<Void, Never>?
        var continuation: AsyncStream<Void>.Continuation?
        var subscriptions = 0
        var activeSubscriptions = 0
    }

    private let lock = NSLock()
    private var storage = Storage()
    private let revocationsBehavior: Revocations

    init(
        hasGrant: Bool = false,
        authorization: Authorization = .cancelled,
        grantState: KeymasterGrantState? = nil,
        reauthenticationRequired: Bool = false,
        clearSucceeds: Bool = true,
        revocations: Revocations = .finished
    ) {
        storage.hasStoredGrant = hasGrant
        storage.authorization = authorization
        storage.grantState = grantState
        storage.reauthenticationRequired = reauthenticationRequired
        storage.clearSucceeds = clearSucceeds
        revocationsBehavior = revocations
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    var hasStoredGrant: Bool {
        get { withStorage { $0.hasStoredGrant } }
        set { withStorage { $0.hasStoredGrant = newValue } }
    }

    var parkGrantRead: Bool {
        get { withStorage { $0.parkGrantRead } }
        set { withStorage { $0.parkGrantRead = newValue } }
    }

    var isGrantReadParked: Bool { withStorage { $0.grantReadPark != nil } }

    func completeGrantRead() {
        let parked = withStorage { storage -> CheckedContinuation<Void, Never>? in
            storage.parkGrantRead = false
            let parked = storage.grantReadPark
            storage.grantReadPark = nil
            return parked
        }
        parked?.resume()
    }

    /// While true, `clear()` suspends until `completeClear()`.
    var parkClear: Bool {
        get { withStorage { $0.parkClear } }
        set { withStorage { $0.parkClear = newValue } }
    }

    // MARK: Observation

    var authorizeCount: Int { withStorage { $0.authorizeCount } }
    var clearCount: Int { withStorage { $0.clearCount } }
    var markReauthenticationCount: Int { withStorage { $0.markCount } }
    var subscriptionCount: Int { withStorage { $0.subscriptions } }
    var activeSubscriptionCount: Int { withStorage { $0.activeSubscriptions } }
    var isClearParked: Bool { withStorage { $0.clearPark != nil } }

    func completeClear() {
        let parked = withStorage { storage -> CheckedContinuation<Void, Never>? in
            let parked = storage.clearPark
            storage.clearPark = nil
            return parked
        }
        parked?.resume()
    }

    /// Publishes a revocation to a `.live` stream.
    func revoke() {
        withStorage { $0.continuation }?.yield(())
    }

    // MARK: AccountSession

    func authorizeInteractively() async throws -> KeymasterTokens {
        let authorization = withStorage { storage -> Authorization in
            storage.authorizeCount += 1
            return storage.authorization
        }
        switch authorization {
        case .cancelled:
            throw CancellationError()
        case .succeed:
            return HarnessFixtures.tokens()
        }
    }

    func hasGrant() async -> Bool { await grantState() == .available }

    func grantState() async -> KeymasterGrantState {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = withStorage { storage in
                guard storage.parkGrantRead else { return false }
                storage.grantReadPark = continuation
                return true
            }
            if !parked { continuation.resume() }
        }
        if let state = withStorage({ $0.grantState }) { return state }
        return hasStoredGrant ? .available : .absent
    }

    func reauthenticationRequired() async -> Bool {
        withStorage { $0.reauthenticationRequired }
    }

    func markReauthenticationRequired() async {
        withStorage { storage in
            storage.markCount += 1
            storage.reauthenticationRequired = true
        }
    }

    func accessToken() async throws -> String {
        guard await hasGrant() else { throw KeymasterSessionError.noGrant }
        return "fixture-access"
    }

    func adopt(_: KeymasterTokens) async throws {
        withStorage {
            $0.hasStoredGrant = true
            $0.grantState = .available
        }
    }

    func clear() async -> Bool {
        // Fence immediately. Parking controls completion of teardown, not grant availability.
        let succeeds = withStorage { storage in
            storage.grantState = storage.clearSucceeds ? .absent : .removalFailed
            if storage.clearSucceeds { storage.hasStoredGrant = false }
            return storage.clearSucceeds
        }
        if parkClear {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withStorage { $0.clearPark = continuation }
            }
        }
        withStorage { $0.clearCount += 1 }
        return succeeds
    }

    func revocations() -> AsyncStream<Void> {
        switch revocationsBehavior {
        case .finished:
            return AsyncStream { $0.finish() }
        case .live:
            return AsyncStream { continuation in
                self.withStorage { storage in
                    storage.subscriptions += 1
                    storage.activeSubscriptions += 1
                    storage.continuation = continuation
                }
                continuation.onTermination = { [weak self] _ in
                    self?.withStorage { $0.activeSubscriptions -= 1 }
                }
            }
        }
    }
}

// MARK: - Preferences

/// In-memory playback preferences that record every write.
final class HarnessPreferences: PlaybackPreferences, @unchecked Sendable {
    private struct Storage {
        var shuffle = false
        var remoteID: String?
        var history: [String: TimeInterval] = [:]
        var shuffleWrites: [Bool] = []
        var remoteDeviceWrites: [String?] = []
        var historyWrites: [[String: TimeInterval]] = []
        var parkShuffleReads = false
        var shuffleReadStarted = false
        var shufflePark: CheckedContinuation<Bool, Never>?
    }

    private let lock = NSLock()
    private var storage = Storage()

    init(
        shuffle: Bool = false,
        lastRemoteDeviceID: String? = nil,
        shuffleHistory: [String: TimeInterval] = [:],
        parkShuffleReads: Bool = false
    ) {
        storage.shuffle = shuffle
        storage.remoteID = lastRemoteDeviceID
        storage.history = shuffleHistory
        storage.parkShuffleReads = parkShuffleReads
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Observation

    var shuffleWrites: [Bool] { withStorage { $0.shuffleWrites } }
    var remoteDeviceWrites: [String?] { withStorage { $0.remoteDeviceWrites } }
    var historyWrites: [[String: TimeInterval]] { withStorage { $0.historyWrites } }
    var storedRemoteDeviceID: String? { withStorage { $0.remoteID } }
    var storedShuffle: Bool { withStorage { $0.shuffle } }
    var storedHistory: [String: TimeInterval] { withStorage { $0.history } }

    func seed(lastRemoteDeviceID id: String?) {
        withStorage { $0.remoteID = id }
    }

    /// True once a parked `shuffleEnabled()` read is suspended.
    func shuffleIsParked() -> Bool {
        withStorage { $0.shuffleReadStarted && $0.shufflePark != nil }
    }

    func resumeShuffle(returning value: Bool = true) {
        let parked = withStorage { storage -> CheckedContinuation<Bool, Never>? in
            let parked = storage.shufflePark
            storage.shufflePark = nil
            return parked
        }
        parked?.resume(returning: value)
    }

    // MARK: PlaybackPreferences

    func shuffleEnabled() async -> Bool {
        let parked = withStorage { storage -> Bool in
            storage.shuffleReadStarted = true
            return storage.parkShuffleReads
        }
        if parked {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                withStorage { $0.shufflePark = continuation }
            }
        }
        return withStorage { $0.shuffle }
    }

    func setShuffleEnabled(_ enabled: Bool) async {
        withStorage { storage in
            storage.shuffle = enabled
            storage.shuffleWrites.append(enabled)
        }
    }

    func lastRemoteDeviceID() async -> String? { withStorage { $0.remoteID } }

    func setLastRemoteDeviceID(_ id: String?) async {
        withStorage { storage in
            storage.remoteID = id
            storage.remoteDeviceWrites.append(id)
        }
    }

    func shuffleHistory() async -> [String: TimeInterval] { withStorage { $0.history } }

    func setShuffleHistory(_ history: [String: TimeInterval]) async {
        withStorage { storage in
            storage.history = history
            storage.historyWrites.append(history)
        }
    }
}

// MARK: - Lifecycle and audio

/// System sleep and wake events. Silent by default; `.live` lets a check `emit`.
final class HarnessLifecycleEvents: SystemLifecycleEvents, @unchecked Sendable {
    enum Behavior: Sendable {
        case finished
        case live
    }

    private struct Storage {
        var continuation: AsyncStream<SystemLifecycleEvent>.Continuation?
        var subscriptions = 0
        var activeSubscriptions = 0
    }

    private let lock = NSLock()
    private var storage = Storage()
    private let behavior: Behavior

    init(_ behavior: Behavior = .finished) {
        self.behavior = behavior
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var subscriptionCount: Int { withStorage { $0.subscriptions } }
    var activeSubscriptionCount: Int { withStorage { $0.activeSubscriptions } }

    func emit(_ event: SystemLifecycleEvent) {
        withStorage { $0.continuation }?.yield(event)
    }

    func events() -> AsyncStream<SystemLifecycleEvent> {
        switch behavior {
        case .finished:
            return AsyncStream { $0.finish() }
        case .live:
            return AsyncStream { continuation in
                self.withStorage { storage in
                    storage.subscriptions += 1
                    storage.activeSubscriptions += 1
                    storage.continuation = continuation
                }
                continuation.onTermination = { [weak self] _ in
                    self?.withStorage { $0.activeSubscriptions -= 1 }
                }
            }
        }
    }
}

/// Audio output preparation that succeeds and counts.
final class HarnessAudioOutput: AudioOutputPreparing, @unchecked Sendable {
    private let counters = HarnessCounters()
    private let lock = NSLock()
    private var storedOnPrepare: (@Sendable () throws -> Void)?

    init(onPrepare: (@Sendable () throws -> Void)? = nil) {
        storedOnPrepare = onPrepare
    }

    var onPrepare: (@Sendable () throws -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnPrepare
        }
        set {
            lock.lock()
            storedOnPrepare = newValue
            lock.unlock()
        }
    }

    var prepareCount: Int { counters.count("prepare") }

    func prepareForPlayback() throws {
        counters.record("prepare")
        try onPrepare?()
    }
}

// MARK: - Catalog

/// The default catalog. Every read is unavailable, which is what a check that is not about the
/// catalog wants; the capability-gated reads keep throwing `CatalogProviderCapabilityError` so a
/// harness catalog is indistinguishable from a provider without those capabilities.
final class HarnessCatalog: CatalogProviding, CatalogEntityQueryProviding, @unchecked Sendable {
    private struct Storage {
        var entityQueries: (any CatalogEntityQueryProviding)?
        var onSearchTracks: (@Sendable (String, Int) async throws -> [CatalogTrack])?
        var onSearchAlbums: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onSearchArtists: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onSearchPlaylists: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onHome: (@Sendable () async throws -> PathfinderHome)?
        var onLibraryPlaylists: (@Sendable () async throws -> [PathfinderPlaylist])?
        var onPlaylistLibrary: (@Sendable () async throws -> [PlaylistLibraryNode])?
        var onCachedPlaylistLibrary: (@Sendable () async throws -> CatalogPlaylistLibrarySnapshot?)?
        var onLibraryAlbums: (@Sendable () async throws -> [PathfinderAlbum])?
        var onLibraryArtists: (@Sendable () async throws -> [PathfinderArtist])?
        var onLibraryTracks: (@Sendable () async throws -> [PathfinderLibraryTrackItem])?
        var onProfile: (@Sendable () async throws -> PathfinderProfile)?
        var onCachedPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot?)?
        var onPlaylistSnapshot: (@Sendable (String) async throws -> CatalogPlaylistSnapshot)?
        var onPlaylist: (@Sendable (String) async throws -> PathfinderPlaylistUnion)?
        var onCachedAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot?)?
        var onAlbumSnapshot: (@Sendable (String) async throws -> CatalogAlbumSnapshot)?
        var onAlbum: (@Sendable (String) async throws -> PathfinderAlbumUnion)?
        var onArtistSnapshot: (@Sendable (String) async throws -> CatalogArtistSnapshot)?
        var onArtist: (@Sendable (String) async throws -> PathfinderArtistUnion)?
        var onArtistDiscographySnapshot: (@Sendable (String) async throws -> CatalogArtistSnapshot)?
        var onArtistDiscography: (@Sendable (String) async throws -> PathfinderArtistUnion)?
    }

    private let lock = NSLock()
    private var storage = Storage()
    private let counters = HarnessCounters()

    init() {}

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    /// Inert by default, preserving callers that do not opt into retained entity queries.
    var entityQueries: (any CatalogEntityQueryProviding)? {
        get { withStorage { $0.entityQueries } }
        set { withStorage { $0.entityQueries = newValue } }
    }

    var onSearchTracks: (@Sendable (String, Int) async throws -> [CatalogTrack])? {
        get { withStorage { $0.onSearchTracks } }
        set { withStorage { $0.onSearchTracks = newValue } }
    }

    var onSearchAlbums: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchAlbums } }
        set { withStorage { $0.onSearchAlbums = newValue } }
    }

    var onSearchArtists: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchArtists } }
        set { withStorage { $0.onSearchArtists = newValue } }
    }

    var onSearchPlaylists: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchPlaylists } }
        set { withStorage { $0.onSearchPlaylists = newValue } }
    }

    var onHome: (@Sendable () async throws -> PathfinderHome)? {
        get { withStorage { $0.onHome } }
        set { withStorage { $0.onHome = newValue } }
    }

    var onLibraryPlaylists: (@Sendable () async throws -> [PathfinderPlaylist])? {
        get { withStorage { $0.onLibraryPlaylists } }
        set { withStorage { $0.onLibraryPlaylists = newValue } }
    }

    var onPlaylistLibrary: (@Sendable () async throws -> [PlaylistLibraryNode])? {
        get { withStorage { $0.onPlaylistLibrary } }
        set { withStorage { $0.onPlaylistLibrary = newValue } }
    }

    var onCachedPlaylistLibrary: (@Sendable () async throws -> CatalogPlaylistLibrarySnapshot?)? {
        get { withStorage { $0.onCachedPlaylistLibrary } }
        set { withStorage { $0.onCachedPlaylistLibrary = newValue } }
    }

    var onLibraryAlbums: (@Sendable () async throws -> [PathfinderAlbum])? {
        get { withStorage { $0.onLibraryAlbums } }
        set { withStorage { $0.onLibraryAlbums = newValue } }
    }

    var onLibraryArtists: (@Sendable () async throws -> [PathfinderArtist])? {
        get { withStorage { $0.onLibraryArtists } }
        set { withStorage { $0.onLibraryArtists = newValue } }
    }

    var onLibraryTracks: (@Sendable () async throws -> [PathfinderLibraryTrackItem])? {
        get { withStorage { $0.onLibraryTracks } }
        set { withStorage { $0.onLibraryTracks = newValue } }
    }

    var onProfile: (@Sendable () async throws -> PathfinderProfile)? {
        get { withStorage { $0.onProfile } }
        set { withStorage { $0.onProfile = newValue } }
    }

    /// Supplies a domain snapshot directly; older wire fixture overrides remain supported.
    var onCachedPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot?)? {
        get { withStorage { $0.onCachedPlaylist } }
        set { withStorage { $0.onCachedPlaylist = newValue } }
    }

    var onPlaylistSnapshot: (@Sendable (String) async throws -> CatalogPlaylistSnapshot)? {
        get { withStorage { $0.onPlaylistSnapshot } }
        set { withStorage { $0.onPlaylistSnapshot = newValue } }
    }

    var onPlaylist: (@Sendable (String) async throws -> PathfinderPlaylistUnion)? {
        get { withStorage { $0.onPlaylist } }
        set { withStorage { $0.onPlaylist = newValue } }
    }

    /// Supplies a domain snapshot directly; older wire fixture overrides remain supported.
    var onCachedAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot?)? {
        get { withStorage { $0.onCachedAlbum } }
        set { withStorage { $0.onCachedAlbum = newValue } }
    }

    var onAlbumSnapshot: (@Sendable (String) async throws -> CatalogAlbumSnapshot)? {
        get { withStorage { $0.onAlbumSnapshot } }
        set { withStorage { $0.onAlbumSnapshot = newValue } }
    }

    var onAlbum: (@Sendable (String) async throws -> PathfinderAlbumUnion)? {
        get { withStorage { $0.onAlbum } }
        set { withStorage { $0.onAlbum = newValue } }
    }

    /// Supplies a domain snapshot directly; older wire fixture overrides remain supported.
    var onArtistSnapshot: (@Sendable (String) async throws -> CatalogArtistSnapshot)? {
        get { withStorage { $0.onArtistSnapshot } }
        set { withStorage { $0.onArtistSnapshot = newValue } }
    }

    var onArtist: (@Sendable (String) async throws -> PathfinderArtistUnion)? {
        get { withStorage { $0.onArtist } }
        set { withStorage { $0.onArtist = newValue } }
    }

    /// Supplies a domain snapshot directly; older wire fixture overrides remain supported.
    var onArtistDiscographySnapshot: (@Sendable (String) async throws -> CatalogArtistSnapshot)? {
        get { withStorage { $0.onArtistDiscographySnapshot } }
        set { withStorage { $0.onArtistDiscographySnapshot = newValue } }
    }

    var onArtistDiscography: (@Sendable (String) async throws -> PathfinderArtistUnion)? {
        get { withStorage { $0.onArtistDiscography } }
        set { withStorage { $0.onArtistDiscography = newValue } }
    }

    // MARK: Observation

    func count(_ name: String) -> Int { counters.count(name) }

    var searchTrackRequestCount: Int { counters.count("searchTracks") }
    var homeRequestCount: Int { counters.count("home") }
    var libraryPlaylistRequestCount: Int { counters.count("libraryPlaylists") }
    var playlistLibraryRequestCount: Int { counters.count("playlistLibrary") }
    var libraryAlbumRequestCount: Int { counters.count("libraryAlbums") }
    var libraryArtistRequestCount: Int { counters.count("libraryArtists") }
    var libraryTrackRequestCount: Int { counters.count("libraryTracks") }
    var profileRequestCount: Int { counters.count("profile") }
    var playlistRequestCount: Int { counters.count("playlist") }
    var albumRequestCount: Int { counters.count("album") }
    var artistRequestCount: Int { counters.count("artist") }
    var discographyRequestCount: Int { counters.count("artistDiscography") }

    // MARK: CatalogProviding

    func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack] {
        counters.record("searchTracks")
        guard let override = onSearchTracks else { throw HarnessFailure.unavailable }
        return try await override(term, limit)
    }

    func searchAlbums(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchAlbums")
        guard let override = onSearchAlbums else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchArtists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchArtists")
        guard let override = onSearchArtists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchPlaylists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchPlaylists")
        guard let override = onSearchPlaylists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func home() async throws -> CatalogHomeSnapshot {
        counters.record("home")
        guard let override = onHome else { throw HarnessFailure.unavailable }
        return CatalogMapping.home(try await override())
    }

    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        counters.record("libraryPlaylists")
        guard let override = onLibraryPlaylists else { throw HarnessFailure.unavailable }
        return try await override()
    }

    /// Mirrors the protocol's flat fallback when no folder hierarchy is scripted.
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        counters.record("playlistLibrary")
        if let override = onPlaylistLibrary { return try await override() }
        return try await libraryPlaylists()
            .compactMap(CatalogMapping.item(from:))
            .map(PlaylistLibraryNode.init(playlist:))
    }

    func cachedPlaylistLibrary() async throws -> CatalogPlaylistLibrarySnapshot? {
        try await onCachedPlaylistLibrary?()
    }

    func libraryAlbums() async throws -> [CatalogItem] {
        counters.record("libraryAlbums")
        guard let override = onLibraryAlbums else { throw HarnessFailure.unavailable }
        return try await override().compactMap(CatalogMapping.item(from:))
    }

    func libraryArtists() async throws -> [CatalogItem] {
        counters.record("libraryArtists")
        guard let override = onLibraryArtists else { throw HarnessFailure.unavailable }
        return try await override().compactMap(CatalogMapping.item(from:))
    }

    func libraryTracks() async throws -> [CatalogTrack] {
        counters.record("libraryTracks")
        guard let override = onLibraryTracks else { throw HarnessFailure.unavailable }
        return try await override().compactMap(CatalogMapping.track(from:))
    }

    func profile() async throws -> CatalogProfileSnapshot {
        counters.record("profile")
        guard let override = onProfile else { throw HarnessFailure.unavailable }
        return CatalogMapping.profile(try await override())
    }

    func cachedPlaylist(id: String) async throws -> CatalogPlaylistSnapshot? {
        counters.record("cachedPlaylist")
        return try await onCachedPlaylist?(id)
    }

    func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        counters.record("playlist")
        if let override = onPlaylistSnapshot { return try await override(id) }
        guard let override = onPlaylist else { throw HarnessFailure.unavailable }
        return CatalogMapping.playlist(try await override(id))
    }

    func cachedAlbum(id: String) async throws -> CatalogAlbumSnapshot? {
        counters.record("cachedAlbum")
        return try await onCachedAlbum?(id)
    }

    func album(id: String) async throws -> CatalogAlbumSnapshot {
        counters.record("album")
        if let override = onAlbumSnapshot { return try await override(id) }
        guard let override = onAlbum else { throw CatalogProviderCapabilityError.unsupported }
        return CatalogMapping.album(try await override(id))
    }

    func artist(id: String) async throws -> CatalogArtistSnapshot {
        counters.record("artist")
        if let override = onArtistSnapshot { return try await override(id) }
        guard let override = onArtist else { throw CatalogProviderCapabilityError.unsupported }
        return CatalogMapping.artist(try await override(id))
    }

    func artistDiscography(id: String) async throws -> CatalogArtistSnapshot {
        counters.record("artistDiscography")
        if let override = onArtistDiscographySnapshot { return try await override(id) }
        guard let override = onArtistDiscography else { throw CatalogProviderCapabilityError.unsupported }
        return CatalogMapping.artist(try await override(id))
    }
    func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        guard let entityQueries else { throw CatalogEntityQueryFailure.unavailable }
        return try await entityQueries.subscribeCatalogEntities(uris)
    }

    func catalogEntityPage(
        _ token: CatalogEntitySubscriptionToken, revision: UInt64, offset: Int, limit: Int
    ) async throws -> CatalogEntityPage {
        guard let entityQueries else { throw CatalogEntityQueryFailure.unavailable }
        return try await entityQueries.catalogEntityPage(token, revision: revision, offset: offset, limit: limit)
    }

    func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async {
        await entityQueries?.acknowledgeCatalogEntities(token, revision: revision)
    }

    func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async {
        await entityQueries?.unsubscribeCatalogEntities(token)
    }

}

/// Playlist writes that are unavailable unless a check scripts them, and that record every call.
final class HarnessPlaylistMutations: PlaylistMutationDispatching, @unchecked Sendable {
    struct AddCall: Sendable, Equatable {
        let playlistId: String
        let trackUris: [String]
    }

    struct RemoveCall: Sendable, Equatable {
        let playlistId: String
        let uids: [String]
    }

    private struct Storage {
        var addCalls: [AddCall] = []
        var removeCalls: [RemoveCall] = []
        var onAdd: (@Sendable (String, [String]) async throws -> Void)?
        var onRemove: (@Sendable (String, [String]) async throws -> Void)?
    }

    private let lock = NSLock()
    private var storage = Storage()

    init(
        onAdd: (@Sendable (String, [String]) async throws -> Void)? = nil,
        onRemove: (@Sendable (String, [String]) async throws -> Void)? = nil
    ) {
        storage.onAdd = onAdd
        storage.onRemove = onRemove
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var onAdd: (@Sendable (String, [String]) async throws -> Void)? {
        get { withStorage { $0.onAdd } }
        set { withStorage { $0.onAdd = newValue } }
    }

    var onRemove: (@Sendable (String, [String]) async throws -> Void)? {
        get { withStorage { $0.onRemove } }
        set { withStorage { $0.onRemove = newValue } }
    }

    var addCalls: [AddCall] { withStorage { $0.addCalls } }
    var removeCalls: [RemoveCall] { withStorage { $0.removeCalls } }

    func addToPlaylist(
        playlistId: String, trackUris: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try authorization.authorizeDispatch()
        let override = withStorage { storage -> (@Sendable (String, [String]) async throws -> Void)? in
            storage.addCalls.append(AddCall(playlistId: playlistId, trackUris: trackUris))
            return storage.onAdd
        }
        guard let override else { throw CatalogProviderCapabilityError.unsupported }
        try await override(playlistId, trackUris)
    }

    func removeFromPlaylist(
        playlistId: String, uids: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try authorization.authorizeDispatch()
        let override = withStorage { storage -> (@Sendable (String, [String]) async throws -> Void)? in
            storage.removeCalls.append(RemoveCall(playlistId: playlistId, uids: uids))
            return storage.onRemove
        }
        guard let override else { throw CatalogProviderCapabilityError.unsupported }
        try await override(playlistId, uids)
    }
}

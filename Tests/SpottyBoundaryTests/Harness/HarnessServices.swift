import Foundation
import SpottyDomain
@testable import SpottyCore

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
        var commands: [SpotifyConnectCommand] = []
        var requestedURIs: [String] = []
        var sendBehavior = SendBehavior.succeed
        var metadataBehavior = MetadataBehavior.immediate
        var metadataTitle = "Metadata"
        var sendParks: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var metadataParks: [String: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>] = [:]
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
    var parkedSendCount: Int { withStorage { $0.sendParks.count } }

    /// Releases the oldest parked send.
    func completePark(success: Bool) {
        let parked = withStorage { storage -> CheckedContinuation<Void, any Error>? in
            guard let id = storage.sendParks.keys.min() else { return nil }
            return storage.sendParks.removeValue(forKey: id)
        }
        guard let parked else { return }
        if success {
            parked.resume()
        } else {
            parked.resume(throwing: HarnessFailure.unavailable)
        }
    }

    /// Releases the parked metadata request for `uri`, or the only parked request when omitted.
    func completeMetadata(for uri: String? = nil, title: String? = nil) {
        typealias Parked = CheckedContinuation<SpotifyConnectTrackMetadata, any Error>
        let resolved = withStorage { storage -> (String, Parked)? in
            let key = uri ?? storage.metadataParks.keys.sorted().first
            guard let key, let parked = storage.metadataParks.removeValue(forKey: key) else { return nil }
            storage.activeMetadataRequests -= 1
            return (key, parked)
        }
        guard let resolved else { return }
        let resolvedTitle = title ?? withStorage { $0.metadataTitle }
        resolved.1.resume(returning: HarnessFixtures.metadata(uri: resolved.0, title: resolvedTitle))
    }

    private func cancelMetadata(_ uri: String) {
        let parked = withStorage { storage -> CheckedContinuation<SpotifyConnectTrackMetadata, any Error>? in
            guard let parked = storage.metadataParks.removeValue(forKey: uri) else { return nil }
            storage.activeMetadataRequests -= 1
            return parked
        }
        parked?.resume(throwing: CancellationError())
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
            try await Task.sleep(nanoseconds: 60_000_000_000)
        case .park:
            let id = withStorage { storage -> UInt64 in
                storage.nextParkID &+= 1
                return storage.nextParkID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    withStorage { $0.sendParks[id] = continuation }
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
            withStorage { storage in
                storage.activeMetadataRequests += 1
                storage.maximumActiveMetadataRequests = max(
                    storage.maximumActiveMetadataRequests,
                    storage.activeMetadataRequests
                )
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>) in
                    withStorage { $0.metadataParks[uri] = continuation }
                }
            } onCancel: {
                self.cancelMetadata(uri)
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
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[CatalogTrack], any Error>) in
                withStorage { $0.continuation = continuation }
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
        var markCount = 0
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
        revocations: Revocations = .finished
    ) {
        storage.hasStoredGrant = hasGrant
        storage.authorization = authorization
        storage.grantState = grantState
        storage.reauthenticationRequired = reauthenticationRequired
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

    func hasGrant() async -> Bool { hasStoredGrant }

    func grantState() async -> KeymasterGrantState {
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

    func accessToken() async throws -> String { "fixture-access" }

    func adopt(_: KeymasterTokens) async throws {}

    func clear() async {
        if parkClear {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withStorage { $0.clearPark = continuation }
            }
        }
        withStorage { $0.clearCount += 1 }
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
final class HarnessCatalog: CatalogProviding, @unchecked Sendable {
    private struct Storage {
        var onSearchTracks: (@Sendable (String, Int) async throws -> [PathfinderTrack])?
        var onSearchAlbums: (@Sendable (String, Int) async throws -> [PathfinderAlbum])?
        var onSearchArtists: (@Sendable (String, Int) async throws -> [PathfinderArtist])?
        var onSearchPlaylists: (@Sendable (String, Int) async throws -> [PathfinderPlaylist])?
        var onHome: (@Sendable () async throws -> PathfinderHome)?
        var onLibraryPlaylists: (@Sendable () async throws -> [PathfinderPlaylist])?
        var onPlaylistLibrary: (@Sendable () async throws -> [PlaylistLibraryNode])?
        var onLibraryAlbums: (@Sendable () async throws -> [PathfinderAlbum])?
        var onLibraryArtists: (@Sendable () async throws -> [PathfinderArtist])?
        var onLibraryTracks: (@Sendable () async throws -> [PathfinderLibraryTrackItem])?
        var onProfile: (@Sendable () async throws -> PathfinderProfile)?
        var onPlaylist: (@Sendable (String) async throws -> PathfinderPlaylistUnion)?
        var onAlbum: (@Sendable (String) async throws -> PathfinderAlbumUnion)?
        var onArtist: (@Sendable (String) async throws -> PathfinderArtistUnion)?
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

    var onSearchTracks: (@Sendable (String, Int) async throws -> [PathfinderTrack])? {
        get { withStorage { $0.onSearchTracks } }
        set { withStorage { $0.onSearchTracks = newValue } }
    }

    var onSearchAlbums: (@Sendable (String, Int) async throws -> [PathfinderAlbum])? {
        get { withStorage { $0.onSearchAlbums } }
        set { withStorage { $0.onSearchAlbums = newValue } }
    }

    var onSearchArtists: (@Sendable (String, Int) async throws -> [PathfinderArtist])? {
        get { withStorage { $0.onSearchArtists } }
        set { withStorage { $0.onSearchArtists = newValue } }
    }

    var onSearchPlaylists: (@Sendable (String, Int) async throws -> [PathfinderPlaylist])? {
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

    var onPlaylist: (@Sendable (String) async throws -> PathfinderPlaylistUnion)? {
        get { withStorage { $0.onPlaylist } }
        set { withStorage { $0.onPlaylist = newValue } }
    }

    var onAlbum: (@Sendable (String) async throws -> PathfinderAlbumUnion)? {
        get { withStorage { $0.onAlbum } }
        set { withStorage { $0.onAlbum = newValue } }
    }

    var onArtist: (@Sendable (String) async throws -> PathfinderArtistUnion)? {
        get { withStorage { $0.onArtist } }
        set { withStorage { $0.onArtist = newValue } }
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

    func searchTracks(_ term: String, limit: Int) async throws -> [PathfinderTrack] {
        counters.record("searchTracks")
        guard let override = onSearchTracks else { throw HarnessFailure.unavailable }
        return try await override(term, limit)
    }

    func searchAlbums(_ term: String, limit: Int) async throws -> [PathfinderAlbum] {
        counters.record("searchAlbums")
        guard let override = onSearchAlbums else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchArtists(_ term: String, limit: Int) async throws -> [PathfinderArtist] {
        counters.record("searchArtists")
        guard let override = onSearchArtists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchPlaylists(_ term: String, limit: Int) async throws -> [PathfinderPlaylist] {
        counters.record("searchPlaylists")
        guard let override = onSearchPlaylists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func home() async throws -> PathfinderHome {
        counters.record("home")
        guard let override = onHome else { throw HarnessFailure.unavailable }
        return try await override()
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

    func libraryAlbums() async throws -> [PathfinderAlbum] {
        counters.record("libraryAlbums")
        guard let override = onLibraryAlbums else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func libraryArtists() async throws -> [PathfinderArtist] {
        counters.record("libraryArtists")
        guard let override = onLibraryArtists else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        counters.record("libraryTracks")
        guard let override = onLibraryTracks else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func profile() async throws -> PathfinderProfile {
        counters.record("profile")
        guard let override = onProfile else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        counters.record("playlist")
        guard let override = onPlaylist else { throw HarnessFailure.unavailable }
        return try await override(id)
    }

    func album(id: String) async throws -> PathfinderAlbumUnion {
        counters.record("album")
        guard let override = onAlbum else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }

    func artist(id: String) async throws -> PathfinderArtistUnion {
        counters.record("artist")
        guard let override = onArtist else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }

    func artistDiscography(id: String) async throws -> PathfinderArtistUnion {
        counters.record("artistDiscography")
        guard let override = onArtistDiscography else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }
}

/// Track attributes that resolve to nothing unless a check scripts them.
final class HarnessTrackAttributes: TrackAttributesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [[String]] = []
    private var storedOnAttributes: (@Sendable ([String]) async throws -> [String: TrackAttributes])?

    init(onAttributes: (@Sendable ([String]) async throws -> [String: TrackAttributes])? = nil) {
        storedOnAttributes = onAttributes
    }

    var onAttributes: (@Sendable ([String]) async throws -> [String: TrackAttributes])? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnAttributes
        }
        set {
            lock.lock()
            storedOnAttributes = newValue
            lock.unlock()
        }
    }

    var requests: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var requestCount: Int { requests.count }

    func attributes(for uris: [String]) async throws -> [String: TrackAttributes] {
        lock.lock()
        storedRequests.append(uris)
        let override = storedOnAttributes
        lock.unlock()
        guard let override else { return [:] }
        return try await override(uris)
    }
}

/// Playlist writes that are unavailable unless a check scripts them, and that record every call.
final class HarnessPlaylistMutations: PlaylistMutating, @unchecked Sendable {
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

    func addToPlaylist(playlistId: String, trackUris: [String]) async throws {
        let override = withStorage { storage -> (@Sendable (String, [String]) async throws -> Void)? in
            storage.addCalls.append(AddCall(playlistId: playlistId, trackUris: trackUris))
            return storage.onAdd
        }
        guard let override else { throw CatalogProviderCapabilityError.unsupported }
        try await override(playlistId, trackUris)
    }

    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        let override = withStorage { storage -> (@Sendable (String, [String]) async throws -> Void)? in
            storage.removeCalls.append(RemoveCall(playlistId: playlistId, uids: uids))
            return storage.onRemove
        }
        guard let override else { throw CatalogProviderCapabilityError.unsupported }
        try await override(playlistId, uids)
    }
}

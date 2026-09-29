import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyGateway
import SpottyRuntimeContracts

// MARK: - Remote playback

/// The default Connect client for runtime and boundary checks. Sends succeed and are recorded; metadata
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
        /// Throws `WebQueueFailure.requestFailed(429)`.
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
        parked?.resume(throwing: error ?? WebQueueFailure.requestFailed(429))
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
            throw WebQueueFailure.requestFailed(429)
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
        var continuation: AsyncStream<AccountGrantRevocation>.Continuation?
        var pendingRevocation: AccountGrantRevocation?
        var onRevocationValidation: (@Sendable () async -> Void)?
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

    /// Parks delivery of an already-computed answer to exercise a stale validation result.
    var onRevocationValidation: (@Sendable () async -> Void)? {
        get { withStorage { $0.onRevocationValidation } }
        set { withStorage { $0.onRevocationValidation = newValue } }
    }

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
    @discardableResult
    func revoke() -> AccountGrantRevocation {
        let revocation = AccountGrantRevocation()
        let continuation = withStorage { storage in
            storage.hasStoredGrant = false
            storage.grantState = .absent
            storage.pendingRevocation = revocation
            return storage.continuation
        }
        continuation?.yield(revocation)
        return revocation
    }

    func isCurrent(_ revocation: AccountGrantRevocation) async -> Bool {
        let (current, pause) = withStorage { ($0.pendingRevocation == revocation, $0.onRevocationValidation) }
        await pause?()
        return current
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
        guard await hasGrant() else { throw HarnessFailure.unavailable }
        return "fixture-access"
    }

    func adopt(_: KeymasterTokens) async throws {
        withStorage {
            $0.pendingRevocation = nil
            $0.reauthenticationRequired = false
            $0.hasStoredGrant = true
            $0.grantState = .available
        }
    }

    func clear() async -> Bool {
        // Fence immediately. Parking controls completion of teardown, not grant availability.
        let succeeds = withStorage { storage in
            storage.pendingRevocation = nil
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

    func revocations() -> AsyncStream<AccountGrantRevocation> {
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

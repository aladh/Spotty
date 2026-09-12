import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottyEngineAdapter

/// The default local engine for boundary checks.
///
/// Every requirement succeeds and is recorded, so a check configures only the one method it is
/// about. Per-method closures replace the recorded default entirely; they run after the call has
/// been counted and, for `execute`, after the operation has been appended.
final class HarnessEngine: LocalPlaybackEngine, @unchecked Sendable {
    /// How `events()` behaves. `.finished` matches an engine that never publishes, `.live` keeps a
    /// continuation so the check can `emit` envelopes.
    enum Events: Sendable {
        case finished
        case live
    }

    /// Counter keys, so checks read `engine.count(.execute)` instead of a bare string.
    enum Call: String, Sendable {
        case events
        case eventTerminations
        case authorizeStreaming
        case initialize
        case execute
        case positionMilliseconds
        case resumePositionMilliseconds
        case resumeContextURI
        case resumeTrackURI
        case queueSnapshot
        case shutdown
        case cleanup
        case clearStreamingCredentials
        case disconnect
        case forceReconnect
    }

    private struct Storage {
        var operations: [LocalPlaybackOperation] = []
        var continuation: AsyncStream<RustPlaybackEventEnvelope>.Continuation?
        var activeSubscriptions = 0
        var executeResult = PlaybackEngineResult.ok
        var initializeResult = PlaybackEngineResult.ok
        var shutdownResult = PlaybackEngineResult.ok
        var disconnectResult = PlaybackEngineResult.ok
        var authorizeResult: Int32 = 0
        var forceReconnectResult: Int32 = 0
        var position: UInt32 = 0
        var resumePosition: UInt32 = 0
        var resumeContext: String?
        var resumeTrack: String?
        var snapshot: RustQueueState?

        var onEvents: (@Sendable () -> AsyncStream<RustPlaybackEventEnvelope>)?
        var onAuthorizeStreaming: (@Sendable (String) -> Int32)?
        var onInitialize: (@Sendable () -> PlaybackEngineResult)?
        var onExecute: (@Sendable (LocalPlaybackOperation) -> PlaybackEngineResult)?
        var onPositionMilliseconds: (@Sendable () -> UInt32)?
        var onResumePositionMilliseconds: (@Sendable () -> UInt32)?
        var onResumeContextURI: (@Sendable () -> String?)?
        var onResumeTrackURI: (@Sendable () -> String?)?
        var onQueueSnapshot: (@Sendable () -> RustQueueState?)?
        var onShutdown: (@Sendable () -> PlaybackEngineResult)?
        var onCleanup: (@Sendable () -> Void)?
        var onClearStreamingCredentials: (@Sendable () -> Void)?
        var onDisconnect: (@Sendable () -> PlaybackEngineResult)?
        var onForceReconnect: (@Sendable () -> Int32)?
    }

    private let lock = NSLock()
    private var storage = Storage()
    private let counters = HarnessCounters()
    private let eventsBehavior: Events

    init(
        events: Events = .finished,
        executeResult: PlaybackEngineResult = .ok,
        initializeResult: PlaybackEngineResult = .ok,
        authorizeResult: Int32 = 0,
        position: UInt32 = 0,
        resumePosition: UInt32 = 0,
        resumeContextURI: String? = nil,
        resumeTrackURI: String? = nil,
        queueSnapshot: RustQueueState? = nil
    ) {
        eventsBehavior = events
        storage.executeResult = executeResult
        storage.initializeResult = initializeResult
        storage.authorizeResult = authorizeResult
        storage.position = position
        storage.resumePosition = resumePosition
        storage.resumeContext = resumeContextURI
        storage.resumeTrack = resumeTrackURI
        storage.snapshot = queueSnapshot
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: - Configuration

    var executeResult: PlaybackEngineResult {
        get { withStorage { $0.executeResult } }
        set { withStorage { $0.executeResult = newValue } }
    }

    var initializeResult: PlaybackEngineResult {
        get { withStorage { $0.initializeResult } }
        set { withStorage { $0.initializeResult = newValue } }
    }

    var shutdownResult: PlaybackEngineResult {
        get { withStorage { $0.shutdownResult } }
        set { withStorage { $0.shutdownResult = newValue } }
    }

    var disconnectResult: PlaybackEngineResult {
        get { withStorage { $0.disconnectResult } }
        set { withStorage { $0.disconnectResult = newValue } }
    }

    var authorizeResult: Int32 {
        get { withStorage { $0.authorizeResult } }
        set { withStorage { $0.authorizeResult = newValue } }
    }

    var forceReconnectResult: Int32 {
        get { withStorage { $0.forceReconnectResult } }
        set { withStorage { $0.forceReconnectResult = newValue } }
    }

    var position: UInt32 {
        get { withStorage { $0.position } }
        set { withStorage { $0.position = newValue } }
    }

    var resumePosition: UInt32 {
        get { withStorage { $0.resumePosition } }
        set { withStorage { $0.resumePosition = newValue } }
    }

    var snapshot: RustQueueState? {
        get { withStorage { $0.snapshot } }
        set { withStorage { $0.snapshot = newValue } }
    }

    var onEvents: (@Sendable () -> AsyncStream<RustPlaybackEventEnvelope>)? {
        get { withStorage { $0.onEvents } }
        set { withStorage { $0.onEvents = newValue } }
    }

    var onAuthorizeStreaming: (@Sendable (String) -> Int32)? {
        get { withStorage { $0.onAuthorizeStreaming } }
        set { withStorage { $0.onAuthorizeStreaming = newValue } }
    }

    var onInitialize: (@Sendable () -> PlaybackEngineResult)? {
        get { withStorage { $0.onInitialize } }
        set { withStorage { $0.onInitialize = newValue } }
    }

    var onExecute: (@Sendable (LocalPlaybackOperation) -> PlaybackEngineResult)? {
        get { withStorage { $0.onExecute } }
        set { withStorage { $0.onExecute = newValue } }
    }

    var onPositionMilliseconds: (@Sendable () -> UInt32)? {
        get { withStorage { $0.onPositionMilliseconds } }
        set { withStorage { $0.onPositionMilliseconds = newValue } }
    }

    var onResumePositionMilliseconds: (@Sendable () -> UInt32)? {
        get { withStorage { $0.onResumePositionMilliseconds } }
        set { withStorage { $0.onResumePositionMilliseconds = newValue } }
    }

    var onResumeContextURI: (@Sendable () -> String?)? {
        get { withStorage { $0.onResumeContextURI } }
        set { withStorage { $0.onResumeContextURI = newValue } }
    }

    var onResumeTrackURI: (@Sendable () -> String?)? {
        get { withStorage { $0.onResumeTrackURI } }
        set { withStorage { $0.onResumeTrackURI = newValue } }
    }

    var onQueueSnapshot: (@Sendable () -> RustQueueState?)? {
        get { withStorage { $0.onQueueSnapshot } }
        set { withStorage { $0.onQueueSnapshot = newValue } }
    }

    var onShutdown: (@Sendable () -> PlaybackEngineResult)? {
        get { withStorage { $0.onShutdown } }
        set { withStorage { $0.onShutdown = newValue } }
    }

    var onCleanup: (@Sendable () -> Void)? {
        get { withStorage { $0.onCleanup } }
        set { withStorage { $0.onCleanup = newValue } }
    }

    var onClearStreamingCredentials: (@Sendable () -> Void)? {
        get { withStorage { $0.onClearStreamingCredentials } }
        set { withStorage { $0.onClearStreamingCredentials = newValue } }
    }

    var onDisconnect: (@Sendable () -> PlaybackEngineResult)? {
        get { withStorage { $0.onDisconnect } }
        set { withStorage { $0.onDisconnect = newValue } }
    }

    var onForceReconnect: (@Sendable () -> Int32)? {
        get { withStorage { $0.onForceReconnect } }
        set { withStorage { $0.onForceReconnect = newValue } }
    }

    // MARK: - Observation

    var operations: [LocalPlaybackOperation] {
        withStorage { $0.operations }
    }

    var rehydrations: [ResumeLoadPlan] {
        operations.compactMap { operation in
            if case let .rehydrate(plan, _) = operation { return plan }
            return nil
        }
    }

    var rehydratedGenerations: [UInt64] {
        operations.compactMap { operation in
            if case let .rehydrate(_, generation) = operation { return generation }
            return nil
        }
    }

    func count(_ call: Call) -> Int { counters.count(call.rawValue) }

    var executeCount: Int { count(.execute) }
    var forceReconnectCount: Int { count(.forceReconnect) }
    var initializeCount: Int { count(.initialize) }
    var shutdownCount: Int { count(.shutdown) }
    var cleanupCount: Int { count(.cleanup) }
    var disconnectCount: Int { count(.disconnect) }
    var authorizeCount: Int { count(.authorizeStreaming) }
    var clearStreamingCredentialsCount: Int { count(.clearStreamingCredentials) }
    var eventSubscriptionCount: Int { count(.events) }
    var eventTerminationCount: Int { count(.eventTerminations) }

    var activeEventSubscriptionCount: Int {
        withStorage { $0.activeSubscriptions }
    }

    /// Publishes an envelope to the installed `.live` stream. A `.finished` engine drops it.
    func emit(_ envelope: RustPlaybackEventEnvelope) {
        withStorage { $0.continuation }?.yield(envelope)
    }

    /// Ends the installed `.live` stream.
    func finishEvents() {
        let continuation = withStorage { storage -> AsyncStream<RustPlaybackEventEnvelope>.Continuation? in
            let installed = storage.continuation
            storage.continuation = nil
            return installed
        }
        continuation?.finish()
    }

    // MARK: - LocalPlaybackEngine

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        counters.record(Call.events.rawValue)
        if let override = onEvents { return override() }
        switch eventsBehavior {
        case .finished:
            return AsyncStream { $0.finish() }
        case .live:
            return AsyncStream { continuation in
                self.withStorage { storage in
                    storage.continuation = continuation
                    storage.activeSubscriptions += 1
                }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.counters.record(Call.eventTerminations.rawValue)
                    self.withStorage { $0.activeSubscriptions -= 1 }
                }
            }
        }
    }

    func authorizeStreaming(with accessToken: String) -> Int32 {
        counters.record(Call.authorizeStreaming.rawValue)
        if let override = onAuthorizeStreaming { return override(accessToken) }
        return authorizeResult
    }

    func initialize() -> PlaybackEngineResult {
        counters.record(Call.initialize.rawValue)
        if let override = onInitialize { return override() }
        return initializeResult
    }

    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        counters.record(Call.execute.rawValue)
        withStorage { $0.operations.append(operation) }
        if let override = onExecute { return override(operation) }
        return executeResult
    }

    func positionMilliseconds() -> UInt32 {
        counters.record(Call.positionMilliseconds.rawValue)
        if let override = onPositionMilliseconds { return override() }
        return position
    }

    func resumePositionMilliseconds() -> UInt32 {
        counters.record(Call.resumePositionMilliseconds.rawValue)
        if let override = onResumePositionMilliseconds { return override() }
        return resumePosition
    }

    func resumeContextURI() -> String? {
        counters.record(Call.resumeContextURI.rawValue)
        if let override = onResumeContextURI { return override() }
        return withStorage { $0.resumeContext }
    }

    func resumeTrackURI() -> String? {
        counters.record(Call.resumeTrackURI.rawValue)
        if let override = onResumeTrackURI { return override() }
        return withStorage { $0.resumeTrack }
    }

    func queueSnapshot() -> RustQueueState? {
        counters.record(Call.queueSnapshot.rawValue)
        if let override = onQueueSnapshot { return override() }
        return snapshot
    }

    func shutdown() -> PlaybackEngineResult {
        counters.record(Call.shutdown.rawValue)
        if let override = onShutdown { return override() }
        return shutdownResult
    }

    func cleanup() {
        counters.record(Call.cleanup.rawValue)
        onCleanup?()
    }

    func clearStreamingCredentials() {
        counters.record(Call.clearStreamingCredentials.rawValue)
        onClearStreamingCredentials?()
    }

    func disconnect() -> PlaybackEngineResult {
        counters.record(Call.disconnect.rawValue)
        if let override = onDisconnect { return override() }
        return disconnectResult
    }

    func forceReconnect() -> Int32 {
        counters.record(Call.forceReconnect.rawValue)
        if let override = onForceReconnect { return override() }
        return forceReconnectResult
    }
}

/// A blocking gate for engine methods that must hold the calling thread the way the real engine
/// does. Whichever `HarnessEngine` closure routes through `enter()`/`wait()` blocks until the
/// check calls `finish`/`release`, so later operations queue behind it on the coordinator.
///
/// The permit is one-shot and may be granted before a caller arrives, matching the semaphore and
/// condition gates the boundary suite used before.
final class HarnessEngineGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var allowed = false
    private var entered = 0
    private var result: PlaybackEngineResult

    init(result: PlaybackEngineResult = .error) {
        self.result = result
    }

    /// How many callers have reached the gate, including the one currently blocked.
    var enteredCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var hasStarted: Bool { enteredCount > 0 }

    /// Blocks until the check releases the gate, then reports the result it supplied.
    func enter() -> PlaybackEngineResult {
        condition.lock()
        entered += 1
        while !allowed {
            condition.wait()
        }
        let result = self.result
        allowed = false
        condition.unlock()
        return result
    }

    /// Blocks until the check releases the gate, for methods with no engine result.
    func wait() {
        _ = enter()
    }

    /// Releases one caller and gives it `result`.
    func finish(with result: PlaybackEngineResult) {
        condition.lock()
        self.result = result
        allowed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Releases one caller, keeping the result already configured.
    func release() {
        condition.lock()
        allowed = true
        condition.broadcast()
        condition.unlock()
    }
}

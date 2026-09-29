import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts

/// Serial owner for local blocking commands and remote network commands. The runtime receives
/// command outcomes; blocking engine work stays off the transition executor and MainActor.
actor PlaybackCoordinator {
    private let local: any LocalPlaybackEngine
    private let remote: any RemotePlaybackClient

    func prepareAudioOutput(_ output: any AudioOutputPreparing) throws {
        try output.prepareForPlayback()
    }

    init(
        local: any LocalPlaybackEngine,
        remote: any RemotePlaybackClient
    ) {
        self.local = local
        self.remote = remote
    }

    /// Reconnect recovery has its own engine-enforced generation and window, independent of
    /// user intent admission. The runtime predicate is an early-out; the engine validates again
    /// after the actor hop. Other playback commands require a dispatch permit.
    func rehydrate(
        _ plan: ResumeLoadPlan,
        sessionGeneration: UInt64,
        isStillWanted: @SessionRuntimeActor @Sendable () -> Bool
    ) async -> PlaybackEngineResult? {
        if Task.isCancelled { return nil }
        guard await isStillWanted() else { return nil }
        return local.execute(.rehydrate(plan, sessionGeneration: sessionGeneration))
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

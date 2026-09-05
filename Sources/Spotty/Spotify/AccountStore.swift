import SpottyDomain
import Foundation
import Observation
import OSLog

/// Owns the complete account lifecycle. Every suspended operation is tied to both a generation
/// and account epoch, so logout/revocation wins even when authorization or engine startup returns
/// late.
@MainActor
@Observable
final class AccountStore {
    private(set) var phase: PlaybackSessionPhase = .signedOut {
        didSet {
            guard oldValue != phase else { return }
            let from = sessionPhaseLogLabel(oldValue)
            let to = sessionPhaseLogLabel(phase)
            SpottyLog.account.info(
                "Session phase changed: \(from, privacy: .public) -> \(to, privacy: .public); epoch=\(self.epoch, privacy: .public)"
            )
            onPhaseChange?(phase)
        }
    }
    /// A credential-rejected engine session must be replaced by a fresh browser authorization.
    /// Keeping this separate from `phase` lets ordinary transport failures reconnect with the
    /// current grant while making the explicit reauthentication path durable until it succeeds.
    private(set) var requiresReauthentication = false
    /// Sole writable account-epoch owner. `PlaybackStore.accountEpoch` projects this value;
    /// `PlaybackState.accountEpoch` is reducer-owned accepted snapshot state, not a second
    /// imperative counter.
    private(set) var epoch: UInt64 = 1

    @ObservationIgnored private let environment: PlaybackEnvironment
    @ObservationIgnored private let coordinator: PlaybackCoordinator
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var teardown = SessionTeardownCoalescer()
    @ObservationIgnored private var teardownTask: Task<SessionTeardownIntent, Never>?
    @ObservationIgnored var onPhaseChange: ((PlaybackSessionPhase) -> Void)?
    @ObservationIgnored var onReauthenticationChange: ((Bool) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?

    init(environment: PlaybackEnvironment, coordinator: PlaybackCoordinator) {
        self.environment = environment
        self.coordinator = coordinator
    }

    func restore() async {
        guard !teardown.isActive, phase != .ready, connectionTask == nil else { return }
        let interval = SpottyLog.accountSignposter.beginInterval("Restore")
        defer { SpottyLog.accountSignposter.endInterval("Restore", interval) }
        guard let task = startConnection(interactive: false) else { return }
        await task.value
    }

    func connect() {
        guard !teardown.isActive, phase != .ready, connectionTask == nil else { return }
        _ = startConnection(interactive: true)
    }

    /// Starts a browser authorization explicitly. The existing grant stays in place until the
    /// new exchange and its persistence have completed successfully.
    func reauthorize() {
        guard !teardown.isActive, phase != .ready, connectionTask == nil else { return }
        setRequiresReauthentication(true)
        _ = startConnection(interactive: true)
    }

    func cancelConnect() {
        guard phase == .authorizing else { return }
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        phase = .signedOut
    }

    func logout() async {
        await endSession(clearGrant: true, finalPhase: .signedOut)
    }

    func handleGrantRevocation() async {
        setRequiresReauthentication(true)
        await endSession(
            clearGrant: false,
            finalPhase: .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
        )
    }

    func receiveEngineConnection(_ session: PlaybackSessionPhase?) {
        guard !teardown.isActive, connectionTask == nil else { return }
        if let session {
            phase = session
        }
    }

    /// Marks the accepted engine outcome as requiring a fresh authorization. The caller owns the
    /// asynchronous engine teardown; this synchronous marker makes a subsequent explicit Connect
    /// action choose the interactive path even if the old grant remains valid for Web APIs.
    func markCredentialRejection() {
        guard !teardown.isActive else { return }
        setRequiresReauthentication(true)
    }

    func endSession(clearGrant: Bool, finalPhase: PlaybackSessionPhase) async {
        _ = await beginEndSession(clearGrant: clearGrant, finalPhase: finalPhase).value
    }

    /// Starts one account teardown or merges into the teardown already in flight. Returning the
    /// shared task lets PlaybackStore keep its wider presentation cleanup in the same lifetime.
    @discardableResult
    func beginEndSession(
        clearGrant: Bool,
        finalPhase: PlaybackSessionPhase
    ) -> Task<SessionTeardownIntent, Never> {
        let requested = SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        let shouldStart = teardown.request(requested)
        let cumulative = teardown.intent ?? requested

        if !shouldStart, let teardownTask {
            phase = cumulative.finalPhase
            return teardownTask
        }

        let staleTask = invalidateAccountIdentity()
        phase = cumulative.finalPhase

        let task = Task { [weak self] in
            guard let self else { return cumulative }
            return await self.performEndSession(staleConnectionTask: staleTask, initialIntent: cumulative)
        }
        teardownTask = task
        return task
    }

    /// Propagates a stronger request from PlaybackStore while the account operation is suspended.
    /// False means the account-level teardown already completed; PlaybackStore will reconcile the
    /// upgrade without starting a second engine shutdown or account epoch.
    @discardableResult
    func upgradeActiveEndSession(
        clearGrant: Bool,
        finalPhase: PlaybackSessionPhase
    ) -> Bool {
        guard teardown.isActive, teardownTask != nil else { return false }
        let requested = SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        _ = teardown.request(requested)
        phase = (teardown.intent ?? requested).finalPhase
        return true
    }

    /// Applies an intent that became stronger after the account-level task completed but while
    /// PlaybackStore was still clearing presentation state. This deliberately does not advance the
    /// epoch or shut the engine down again.
    func reconcileCompletedEndSession(
        applied: SessionTeardownIntent,
        desired: SessionTeardownIntent
    ) async -> SessionTeardownIntent {
        let resolved = applied.merging(desired)
        if resolved.clearGrant && !applied.clearGrant {
            await environment.account.clear()
            setRequiresReauthentication(false)
        }
        phase = resolved.finalPhase
        return resolved
    }

    private func performEndSession(
        staleConnectionTask: Task<Void, Never>?,
        initialIntent: SessionTeardownIntent
    ) async -> SessionTeardownIntent {
        let interval = SpottyLog.accountSignposter.beginInterval("Teardown")
        defer { SpottyLog.accountSignposter.endInterval("Teardown", interval) }
        if let staleConnectionTask { await staleConnectionTask.value }

        if requiresReauthentication, !initialIntent.clearGrant {
            await environment.account.markReauthenticationRequired()
        }

        _ = await coordinator.shutdownEngine()
        await coordinator.cleanupEngine()
        await coordinator.clearStreamingCredentials()
        var resolved = teardown.intent ?? initialIntent
        if resolved.clearGrant {
            await environment.account.clear()
            setRequiresReauthentication(false)
            resolved = teardown.intent ?? resolved
        }

        let completed = teardown.complete() ?? resolved
        phase = completed.finalPhase
        teardownTask = nil
        return completed
    }

    /// The only mutation of `epoch`. A new account lifetime starts here so in-flight work
    /// stamped with the previous value is rejected.
    func advanceEpoch() {
        epoch &+= 1
    }

    /// Advances account identity and cancels in-flight connection work. Returns the cancelled
    /// connection task so the caller can await it after presentation teardown.
    @discardableResult
    func invalidateAccountIdentity() -> Task<Void, Never>? {
        advanceEpoch()
        connectionGeneration &+= 1
        let staleTask = connectionTask
        connectionTask = nil
        staleTask?.cancel()
        return staleTask
    }

    /// Invalidates account identity without waiting for engine shutdown so presentation
    /// teardown can observe the new epoch first. Streaming credentials stay intact.
    @discardableResult
    func prepareShutdownForTermination() -> Task<Void, Never>? {
        let staleTask = invalidateAccountIdentity()
        phase = .signedOut
        return staleTask
    }

    func completeShutdownForTermination(staleConnectionTask: Task<Void, Never>?) async {
        if let staleConnectionTask { await staleConnectionTask.value }
        _ = await coordinator.shutdownEngine()
        await coordinator.cleanupEngine()
        phase = .signedOut
    }

    @discardableResult
    private func startConnection(interactive: Bool) -> Task<Void, Never>? {
        guard connectionTask == nil else { return connectionTask }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let operationEpoch = epoch
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConnection(
                interactive: interactive,
                generation: generation,
                epoch: operationEpoch
            )
            if self.isCurrent(generation: generation, epoch: operationEpoch) {
                self.connectionTask = nil
            }
        }
        connectionTask = task
        return task
    }

    private func runConnection(interactive: Bool, generation: UInt64, epoch: UInt64) async {
        let grantState = await environment.account.grantState()
        let persistedReauthentication = await environment.account.reauthenticationRequired()
        guard isCurrent(generation: generation, epoch: epoch) else { return }
        if persistedReauthentication {
            setRequiresReauthentication(true)
        }

        if interactive, grantState != .available || requiresReauthentication {
            await performInteractiveConnect(generation: generation, epoch: epoch)
            return
        }

        switch grantState {
        case .available:
            guard !requiresReauthentication else {
                phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
                return
            }
            await restoreGrant(generation: generation, epoch: epoch)
        case .absent:
            phase = .signedOut
        case .denied:
            phase = .failed("Spotty cannot access its saved Spotify session. Allow Keychain access and try again.")
        case .failed:
            phase = .failed("Spotty could not read its saved Spotify session. Try again or sign in again.")
        }
    }

    private func restoreGrant(generation: UInt64, epoch: UInt64) async {
        switch await initializeRestoredPlayer(generation: generation, epoch: epoch, reportFailure: false) {
        case .ready, .credentialsRejected, .failed:
            return
        case .transientFailure:
            break
        }
        guard isCurrent(generation: generation, epoch: epoch) else { return }
        guard !requiresReauthentication else {
            phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
            return
        }

        do {
            let token = try await environment.account.accessToken()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            guard !requiresReauthentication else {
                phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
                return
            }
            let code = await coordinator.authorizeStreaming(with: token)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            guard !requiresReauthentication else {
                phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
                return
            }
            guard code == 0 else {
                SpottyLog.account.error("Streaming authorization failed; code=\(code, privacy: .public)")
                phase = .failed(LiveSpotifyError.streamingAuthorization(code).localizedDescription)
                return
            }
            await coordinator.cleanupEngine()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            _ = await initializeRestoredPlayer(generation: generation, epoch: epoch, reportFailure: true)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            SpottyLog.account.error(
                "Saved session restoration failed; domain=\((error as NSError).domain, privacy: .public); code=\((error as NSError).code, privacy: .public)"
            )
            phase = .failed(error.localizedDescription)
        }
    }

    private func initializeRestoredPlayer(
        generation: UInt64,
        epoch: UInt64,
        reportFailure: Bool
    ) async -> PlayerInitializationOutcome {
        for attempt in 0..<3 {
            if attempt > 0 {
                do {
                    try await environment.clock.sleep(seconds: attempt == 1 ? 1 : 3)
                } catch {
                    return .failed
                }
                guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
            }
            let outcome = await initializePlayer(
                generation: generation, epoch: epoch, reportFailure: reportFailure && attempt == 2
            )
            guard case .transientFailure = outcome else { return outcome }
            guard isCurrent(generation: generation, epoch: epoch), !requiresReauthentication else { return .failed }
        }
        return .transientFailure
    }

    private func performInteractiveConnect(generation: UInt64, epoch: UInt64) async {
        phase = .authorizing
        do {
            let tokens = try await environment.account.authorizeInteractively()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            // The OAuth response is now accepted. From this commit point onward cancellation is
            // owned by the session teardown path, which drains persistence before clearing it.
            phase = .connecting
            try await environment.account.adopt(tokens)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            setRequiresReauthentication(false)

            let code = await coordinator.authorizeStreaming(with: tokens.accessToken)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            guard !requiresReauthentication else {
                phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
                return
            }
            guard code == 0 else { throw LiveSpotifyError.streamingAuthorization(code) }
            _ = await initializePlayer(generation: generation, epoch: epoch, reportFailure: true)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func initializePlayer(
        generation: UInt64,
        epoch: UInt64,
        reportFailure: Bool
    ) async -> PlayerInitializationOutcome {
        let interval = SpottyLog.accountSignposter.beginInterval("Engine initialization")
        defer { SpottyLog.accountSignposter.endInterval("Engine initialization", interval) }
        guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
        guard !requiresReauthentication else {
            phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
            return .credentialsRejected
        }
        phase = .connecting
        do {
            try environment.audioOutput.prepareForPlayback()
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
            SpottyLog.audio.error("Audio output preparation failed")
            phase = .failed(error.localizedDescription)
            return .failed
        }
        let result = await coordinator.initializeEngine()
        guard isCurrent(generation: generation, epoch: epoch) else { return .failed }

        if result.isCredentialsRejected || requiresReauthentication {
            setRequiresReauthentication(true)
            await environment.account.markReauthenticationRequired()
            guard isCurrent(generation: generation, epoch: epoch) else { return .credentialsRejected }
            phase = .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
            return .credentialsRejected
        }

        if result.isOK {
            phase = .ready
            onReady?()
            return .ready
        }
        if reportFailure {
            SpottyLog.account.error("Engine initialization failed; code=\(result.rawValue, privacy: .public)")
            phase = .failed("Spotty Connect could not start (\(result.rawValue))")
        }
        return .transientFailure
    }

    private enum PlayerInitializationOutcome {
        case ready
        case failed
        case transientFailure
        case credentialsRejected
    }

    private func isCurrent(generation: UInt64, epoch: UInt64) -> Bool {
        !Task.isCancelled && connectionGeneration == generation && self.epoch == epoch
    }

    private func setRequiresReauthentication(_ required: Bool) {
        guard requiresReauthentication != required else { return }
        requiresReauthentication = required
        onReauthenticationChange?(required)
    }
}

/// Public log category for a session phase. Failed phases keep their user-facing text off logs.
func sessionPhaseLogLabel(_ phase: PlaybackSessionPhase) -> String {
    switch phase {
    case .signedOut: "signedOut"
    case .authorizing: "authorizing"
    case .connecting: "connecting"
    case .ready: "ready"
    case .recovering: "recovering"
    case .failed: "failed"
    }
}

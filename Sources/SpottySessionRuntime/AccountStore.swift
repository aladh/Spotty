import SpottyGateway
import SpottyDiagnostics
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog

/// Owns the account connection lifecycle: phase, epoch, reauthentication, and connection work.
/// Every suspended operation is tied to both a generation and account epoch, so logout/revocation
/// wins even when authorization or engine startup returns late.
///
/// Session teardown is *not* owned here. `SessionTeardownController` on `PlaybackSessionRuntime` coalesces
/// requests and drives the narrow primitives below (`invalidateAccountIdentity`, `publishPhase`,
/// `performAccountTeardown`, `applyStrongerIntent`) in order, and sets `isTearingDown` at the
/// boundaries so connection work refuses to start against a session being torn down.
@SessionRuntimeActor
final class AccountStore {
    private(set) var phase: PlaybackSessionPhase = .signedOut {
        didSet {
            if phase == .ready { environment.playlistMutationAdmission.activate(accountEpoch: epoch) }
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
    /// Sole writable account-epoch owner. `PlaybackSessionRuntime.accountEpoch` projects this value;
    /// `PlaybackState.accountEpoch` is reducer-owned accepted snapshot state, not a second
    /// imperative counter.
    private(set) var epoch: UInt64 = 1

    private let environment: PlaybackEnvironment
    private let coordinator: PlaybackCoordinator
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var retiredAccountEpoch: UInt64 = 1
    /// Set by the teardown owner at the boundaries of one session teardown. Connection work
    /// refuses to start while it is true.
    var isTearingDown = false
    var onPhaseChange: ((PlaybackSessionPhase) -> Void)?
    var onReauthenticationChange: ((Bool) -> Void)?
    var onReady: (() -> Void)?
    var onCacheRetirementFailure: (() -> Void)?

    init(environment: PlaybackEnvironment, coordinator: PlaybackCoordinator) {
        self.environment = environment
        self.coordinator = coordinator
    }

    var canStartConnection: Bool { !isTearingDown && phase != .ready && connectionTask == nil }

    var connectionSettlement: Task<Void, Never>? { connectionTask }

    func restore() async {
        guard !isTearingDown, phase != .ready, connectionTask == nil else { return }
        let interval = SpottyLog.accountSignposter.beginInterval("Restore")
        defer { SpottyLog.accountSignposter.endInterval("Restore", interval) }
        guard let task = startConnection(interactive: false) else { return }
        await task.value
    }

    func connect() {
        guard !isTearingDown, phase != .ready, connectionTask == nil else { return }
        _ = startConnection(interactive: true)
    }

    /// Starts a browser authorization explicitly. The existing grant stays in place until the
    /// new exchange and its persistence have completed successfully.
    func reauthorize() {
        guard !isTearingDown, phase != .ready, connectionTask == nil else { return }
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

    func receiveEngineConnection(_ session: PlaybackSessionPhase?) {
        guard !isTearingDown, connectionTask == nil else { return }
        if let session {
            phase = session
        }
    }

    /// Marks the accepted engine outcome as requiring a fresh authorization. The caller owns the
    /// asynchronous engine teardown; this synchronous marker makes a subsequent explicit Connect
    /// action choose the interactive path even if the old grant remains valid for Web APIs.
    func markCredentialRejection() {
        guard !isTearingDown else { return }
        setRequiresReauthentication(true)
    }

    /// Publishes a session phase decided by the teardown owner. Ordinary connection work assigns
    /// `phase` directly; this is the narrow entrance `PlaybackSessionRuntime` uses while it drives teardown.
    func publishPhase(_ phase: PlaybackSessionPhase) {
        self.phase = phase
    }

    /// The account-side body of one teardown: drain the cancelled connection work, persist the
    /// reauthentication marker when the grant survives, shut the engine down, and clear the
    /// streaming credential — plus the persisted grant when the intent says so.
    ///
    /// Coalescing, phase publication, and presentation cleanup belong to the teardown owner. This
    /// performs exactly the intent it is handed and reports what it applied, so a request that
    /// became stronger while this was suspended is reconciled by `applyStrongerIntent` rather than
    /// by a second engine shutdown or a second account epoch.
    func performAccountTeardown(
        staleConnectionTask: Task<Void, Never>?,
        intent: SessionTeardownIntent
    ) async -> SessionTeardownIntent {
        let interval = SpottyLog.accountSignposter.beginInterval("Teardown")
        defer { SpottyLog.accountSignposter.endInterval("Teardown", interval) }
        let artworkEpoch = retiredAccountEpoch
        if let staleConnectionTask { await staleConnectionTask.value }
        await environment.artwork.retire(accountEpoch: artworkEpoch)
        // Retire catalog admission before credentials can be cleared or replaced. Failure leaves
        // the provider fenced and is reported without reopening access to the old account cache.
        let cacheRetired = await environment.catalogCacheLifecycle?.retire(purge: true) ?? true
        if !cacheRetired {
            SpottyLog.account.error("Catalog cache retirement failed; cache access remains fenced")
            onCacheRetirementFailure?()
        }

        if requiresReauthentication, !intent.clearGrant {
            await environment.account.markReauthenticationRequired()
        }

        _ = await coordinator.shutdownEngine()
        await coordinator.cleanupEngine()
        await coordinator.clearStreamingCredentials()
        if intent.clearGrant {
            await environment.account.clear()
            setRequiresReauthentication(false)
        }
        // The phase is not republished here: the owner already published the cumulative intent,
        // and an upgrade that arrived while this was suspended must not be reverted to the
        // weaker phase this call started with.
        return intent
    }

    /// Applies an intent that became stronger after the account-side teardown completed but while
    /// the owner was still clearing presentation state. This deliberately does not advance the
    /// epoch or shut the engine down again.
    func applyStrongerIntent(
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

    /// The only mutation of `epoch`. A new account lifetime starts here so in-flight work
    /// stamped with the previous value is rejected.
    func advanceEpoch() {
        epoch &+= 1
        environment.playlistMutationAdmission.retire(nextAccountEpoch: epoch)
    }

    /// Advances account identity and cancels in-flight connection work. Returns the cancelled
    /// connection task so the caller can await it after presentation teardown.
    @discardableResult
    func invalidateAccountIdentity() -> Task<Void, Never>? {
        retiredAccountEpoch = epoch
        advanceEpoch()
        connectionGeneration &+= 1
        let staleTask = connectionTask
        connectionTask = nil
        staleTask?.cancel()
        return staleTask
    }

    /// Finishes process termination after the owner invalidated identity and drained effects.
    /// Streaming credentials stay intact for the next launch.
    func completeShutdownForTermination(staleConnectionTask: Task<Void, Never>?) async {
        let artworkEpoch = retiredAccountEpoch
        if let staleConnectionTask { await staleConnectionTask.value }
        await environment.artwork.retire(accountEpoch: artworkEpoch)
        _ = await environment.catalogCacheLifecycle?.retire(purge: false)
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
            phase = .failed(
                "Spotty cannot access its saved Spotify session. Check its session-file permissions and try again.")
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
            try await coordinator.prepareAudioOutput(environment.audioOutput)
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
            SpottyLog.audio.error("Audio output preparation failed")
            phase = .failed(error.localizedDescription)
            return .failed
        }
        guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
        guard !requiresReauthentication else { return .credentialsRejected }
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
            await environment.artwork.activate(accountEpoch: epoch)
            guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
            await environment.catalogCacheLifecycle?.activate()
            guard isCurrent(generation: generation, epoch: epoch) else { return .failed }
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

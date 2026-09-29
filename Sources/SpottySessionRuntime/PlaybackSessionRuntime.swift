import SpottyGateway
import SpottyDiagnostics
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog

/// The small playback projection catalog rows need. It deliberately excludes timing so position
/// samples do not invalidate the rows that only draw current-track and transport state.
package struct CurrentTrackIndicator: Equatable, Sendable {
    package let trackURI: String?
    package let isPlaying: Bool

    package init(trackURI: String? = nil, isPlaying: Bool = false) {
        self.trackURI = trackURI
        self.isPlaying = isPlaying
    }

    package init(state: PlaybackState) {
        let uri = state.currentTrack?.uri
        self.init(trackURI: uri?.isEmpty == false ? uri : nil, isPlaying: state.transport == .playing)
    }
}

/// Coarse catalog-facing capabilities derived from the reducer snapshot. Keeping these facts
/// separate from `state` lets catalog ancestors observe connection and command transitions without
/// subscribing to high-frequency timing changes.
package struct CatalogPlaybackAvailability: Equatable, Sendable {
    package let isConnected: Bool
    package let hasPendingPlaybackCommand: Bool

    package init(state: PlaybackState) {
        isConnected = state.session == .ready
        hasPendingPlaybackCommand = state.pendingCommands.keys.contains { $0 != .queue }
    }
}

@SessionRuntimeActor
package final class PlaybackSessionRuntime: Sendable {
    package typealias Phase = PlaybackSessionPhase

    private let transitions: PlaybackTransitions
    var state: PlaybackState { transitions.state }
    /// Equatable publications derived only from accepted reducer state. Source revisions and
    /// timing anchors cannot invalidate semantic, device or queue observers.
    private(set) var semantic = PlaybackSemanticProjection(state: PlaybackState(accountEpoch: 1))
    private(set) var timeline = PlaybackTiming(anchoredAt: .distantPast)
    private(set) var playbackDuration: TimeInterval = 0
    private(set) var presentedQueueEntries: [QueueEntry] = []
    private(set) var presentedDevices: [ConnectDevice] = []
    private(set) var presentedLocalDeviceID: String?
    /// Coarse track/transport observation for catalog rows. Timing changes never rewrite this
    /// value, so its observers only wake when the current track or playing state changes.
    private(set) var currentTrackIndicator = CurrentTrackIndicator()
    /// Accepted playing context for sidebar rows; timing ticks do not invalidate every row.
    private(set) var playingContextURI: String?
    /// Coarse connection and command capability observation for catalog ancestors. This is a
    /// projection of accepted reducer state, not a second state owner.
    private(set) var catalogPlaybackAvailability = CatalogPlaybackAvailability(
        state: PlaybackState(accountEpoch: 1)
    )

    /// A typed engine credential rejection keeps the independent Keymaster grant intact while
    /// making the next account action an explicit browser reauthorization.
    private(set) var requiresReauthentication = false

    /// Playback labels retained by the runtime independently of the client's browsing collections.
    let catalogMetadata: RuntimeCatalogMetadata
    let history = RuntimeHistory()
    let environment: PlaybackEnvironment
    /// Runtime mutation-feedback values. Queue results reach the desktop through presentation
    /// snapshots rather than `PlaybackState.notice`.
    let feedback: RuntimeFeedback
    let metadataService: TrackMetadataService
    let coordinator: PlaybackCoordinator
    let queueService: QueueService
    let accountStore: AccountStore
    var catalogSession: CatalogSessionSnapshot { environment.catalogSessionAdmission.snapshot }
    /// Read-only projection of `AccountStore.epoch`. Do not increment or assign this value.
    package var accountEpoch: UInt64 { accountStore.epoch }
    /// Swift-owned local display name. The engine no longer sends a hardcoded `device_name`.
    let thisDeviceName = "This Mac"
    var lastRemoteDeviceID: String? { preferenceState.lastRemoteDeviceID }
    /// The first Connect snapshot describes state that predates this process. It seeds the UI,
    /// but must not be counted as something the listener just played in this Spotty session.
    var hasReceivedPlaybackSnapshot = false
    let effects = PlaybackEffectRegistry()
    /// Included in presentation snapshots so native commands update availability during teardown.
    /// The same gate rejects queued engine events while the old session is being cleared.
    var isTearingDown: Bool { !lifecycle.acceptsWork }
    let lifecycle = SessionLifecycle()
    /// Process-lifetime subscriptions start only after SwiftUI reaches the durable restore
    /// boundary. `SpottyApp` values may be initialized speculatively, so `init` must not subscribe.
    var hasStartedLifetimeEffects = false
    var lastEngineEventSequence: UInt64 = 0
    /// Engine identity is committed with the reducer snapshot, never advanced independently.
    package var engineGeneration: UInt64 { state.engineEpoch }
    /// Engine session generation whose reconnect rehydration Swift has already issued. The
    /// engine republishes `resume_pending` on every snapshot inside its window; one load
    /// sequence per rebuilt session is the contract.
    var rehydratedSessionGeneration: UInt64?
    /// Whether the latest accepted connection snapshot still describes an open engine
    /// rehydration window (`resumePending` with `spircReady` clear). Read again immediately
    /// before a queued rehydration executes, so a window that closed while the coordinator
    /// was busy does not get a late load.
    var engineRehydrationWindowOpen = false
    /// One immutable stamp for playback-scoped work. This projects the two existing
    /// lifecycle owners without becoming a third writable counter.
    package var playbackLifetime: PlaybackLifetime {
        PlaybackLifetime(accountEpoch: accountEpoch, engineGeneration: engineGeneration)
    }
    /// SessionRuntimeActor watermark for Connect *callback* identity. Distinct from
    /// `state.sourceRevisions[.engineQueue]`, which tracks provenance snapshots after merge.
    var connectQueueCallback = ConnectQueueCallbackWatermark()
    /// Inspector-facing version advanced only after a changed Connect URI ordering commits.
    /// Refresh-produced queue projections must never write it or restart their own hydration.
    var queueInspectorOrderingVersion: UInt64 = 0
    var shuffleHistoryCache: [String: TimeInterval] { preferenceState.shuffleHistory }
    /// Connect protocol queue used for `set_queue`. This is a SessionRuntimeActor projection of
    /// `QueueService`'s mutation snapshot, updated only after accepted Connect intake or a
    /// committed replacement. Web inspector refresh must not write it.
    var queueMutation: QueueMutationSnapshot?
    /// Lifetime token for one in-flight Connect `set_queue` replacement. Not a source revision.
    /// A finished request clears only its own token so teardown cannot drop a newer session gate.
    var queueReplacementToken: UUID?
    let preferenceState: PlaybackPreferenceState
    var presentationRevision: UInt64 = 0
    var publicationPending = false
    var presentationSubscribers: [UUID: AsyncStream<RuntimePresentation>.Continuation] = [:]

    package init(
        environment: PlaybackEnvironment
    ) {
        self.environment = environment
        preferenceState = PlaybackPreferenceState(storage: environment.preferences, accountEpoch: 1)
        let initialState = PlaybackState(accountEpoch: 1)
        transitions = PlaybackTransitions(initialState: initialState, clock: environment.clock)
        timeline = initialState.timing
        self.feedback = RuntimeFeedback()
        let metadataService = TrackMetadataService(remote: environment.remote)
        self.metadataService = metadataService
        let coordinator = PlaybackCoordinator(
            local: environment.local,
            remote: environment.remote
        )
        self.coordinator = coordinator
        queueService = QueueService(
            webQueue: environment.webQueue,
            metadata: metadataService,
            clock: environment.clock,
            hook: environment.queueServiceHook
        )
        accountStore = AccountStore(environment: environment, coordinator: coordinator, lifecycle: lifecycle)
        catalogMetadata = RuntimeCatalogMetadata()
        feedback.changed = { [weak self] in self?.publish() }
        history.changed = { [weak self] in self?.publish() }
        catalogMetadata.changed = { [weak self] in self?.publish() }
        accountStore.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.publish()
            // A successful initialization return can beat consumption of its engine callbacks.
            // Catalog/auth readiness does not publish command readiness before local identity and
            // connection facts have reached the reducer. Only accepted engine observations do.
            if phase != .ready {
                self.send(.session(phase), source: .account)
            }
        }
        accountStore.onCacheRetirementFailure = { [weak self] in
            self?.feedback.failure(
                "The session ended, but Spotty could not remove its catalog cache. Cache access remains disabled.")
        }
        accountStore.onGrantRemovalFailure = { [weak self] in
            self?.feedback.failure(AccountStore.grantRemovalFailureMessage)
        }
        accountStore.onReauthenticationChange = { [weak self] required in
            guard let self else { return }
            self.requiresReauthentication = required
            self.publish()
        }
        // A new process must inspect its saved session before it can report signed out.
        send(.session(accountStore.phase), source: .account)
    }

    isolated deinit {
        // Clients can retain a stream independently of its runtime. Release their parked tasks
        // when this publication owner disappears, just as owned effects end with the runtime.
        for subscriber in presentationSubscribers.values { subscriber.finish() }
    }

    package func startLifetimeEffectsIfNeeded() {
        guard lifecycle.acceptsWork, !hasStartedLifetimeEffects else { return }
        hasStartedLifetimeEffects = true
        // Create each stream before account restoration can initialize the engine. The
        // subscription is therefore installed synchronously even though consumption is a task.
        let engineEvents = environment.local.events()
        let grantRevocations = environment.account.revocations()
        let lifecycleEvents = environment.lifecycle.events()
        // These three are process-lifetime subscriptions, not account-scoped work: they must keep
        // delivering across account replacement, so they deliberately do not use `stillCurrent`.
        effects.run(.engineEvents) { [weak self] in
            for await envelope in engineEvents {
                guard !Task.isCancelled, let self else { return }
                self.receive(envelope)
            }
        }
        effects.run(.grantRevocations) { [weak self] in
            for await revocation in grantRevocations {
                guard !Task.isCancelled else { return }
                await self?.handleGrantRevocation(revocation)
            }
        }
        effects.run(.lifecycle) { [weak self] in
            for await event in lifecycleEvents {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event)
            }
        }
        effects.run(.queueServiceBootstrap) { [weak self] in
            guard let self else { return }
            await self.queueService.reset(accountEpoch: self.accountEpoch)
        }
        effects.run(.preferencesRestore, onCancel: { [preferenceState] in preferenceState.cancelRestoration() }) {
            [weak self, preferenceState] in
            await preferenceState.restore { [weak self] enabled in self?.setShuffleEnabled(enabled) }
        }
    }

    /// macOS suspends the process on sleep and sockets die underneath it; without this the
    /// first play after waking would fail until the user manually reconnected.
    ///
    /// The backend's `forceReconnect` captures the playing track and position before tearing
    /// down and restores them through its own reconnection loop, so playback resumes where it
    /// was. The backend also self-reports disconnections; this covers the case where it does
    /// not notice — a clean sleep can look, to it, like nothing happened at all.
    private func receive(_ event: SystemLifecycleEvent) async {
        guard isConnected else { return }
        switch event {
        case .willSleep:
            _ = await coordinator.disconnect()
        case .didWake:
            statusTextFallbackAfterWake()
            _ = await coordinator.forceReconnect()
        }
    }

    /// Tells the listener what is happening instead of leaving the stale "Playing" label up
    /// while the backend rebuilds its session.
    private func statusTextFallbackAfterWake() {
        guard showsPauseControl else { return }
        showTransientCommandError("Restoring playback after sleep…")
    }

    /// The only mutation entrance for the atomic playback snapshot.
    /// Engine callbacks pass their payload `sessionGeneration` as `engineEpoch`. Asynchronous
    /// outcomes pass the account and engine identity captured when the work started so
    /// `PlaybackReducer` rejects stale results. Unstamped events use `accountEpoch` (the
    /// `AccountStore.epoch` projection) and `engineGeneration` (the accepted reducer epoch).
    /// Reducer-owned `state.accountEpoch` is accepted snapshot state, not a
    /// second imperative lifecycle owner. Omitted `receivedAt` is the orchestration clock;
    /// engine intake passes the fan-out receipt time, which stays distinct from source revisions.
    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        accountEpoch: UInt64? = nil,
        receivedAt: Date? = nil
    ) -> Bool {
        reduce(
            event,
            source: source,
            revision: revision,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch,
            receivedAt: receivedAt
        ).accepted
    }

    /// Same mutation entrance as `send`, but returns what the reducer accepted and changed so
    /// post-acceptance side effects are driven by the reduction instead of a state diff.
    @discardableResult
    func reduce(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        accountEpoch: UInt64? = nil,
        receivedAt: Date? = nil
    ) -> PlaybackReduction {
        let stampedAccountEpoch = accountEpoch ?? self.accountEpoch
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        let commit = transitions.apply(
            PlaybackEventEnvelope(
                accountEpoch: stampedAccountEpoch, engineEpoch: stampedEngineEpoch, source: source,
                revision: revision, receivedAt: receivedAt ?? environment.clock.now(), event: event),
            currentLifetime: playbackLifetime)
        let reduction = commit.reduction
        if reduction.accepted {
            switch event {
            case let .enginePlayback(snapshot) where snapshot.shuffle != nil:
                preferenceState.supersedeShuffleSeed()
            case let .engineCluster(snapshot)
            where reduction.acceptedSources.contains(.enginePlayback) && snapshot.playback?.shuffle != nil:
                preferenceState.supersedeShuffleSeed()
            case let .commandStarted(command) where command.expectedShuffle != nil:
                preferenceState.supersedeShuffleSeed()
            default: break
            }
            let next = state
            // A timed-out intent keeps its own deadline bookkeeping; every other terminal
            // outcome releases the deadline effect it no longer needs.
            let settledIntentIDs = reduction.settledIntents.filter { $0.outcome != .timedOut }.map(\.id)
            let confirmedTracks = reduction.confirmedPlayTrackURIs
            let queueEntriesChanged = reduction.queueEntriesChanged
            let devicesChanged = reduction.devicesChanged
            let nextSemantic = PlaybackSemanticProjection(state: next)
            if semantic != nextSemantic { semantic = nextSemantic }
            if timeline != next.timing { timeline = next.timing }
            if playbackDuration != next.timing.duration { playbackDuration = next.timing.duration }
            if queueEntriesChanged {
                let nextQueue = QueueEntry.uniquelyIdentified(next.queue.entries)
                if presentedQueueEntries != nextQueue { presentedQueueEntries = nextQueue }
            }
            if devicesChanged {
                let nextDevices = next.devices.devices.map {
                    ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
                }
                if presentedDevices != nextDevices { presentedDevices = nextDevices }
            }
            if presentedLocalDeviceID != next.devices.localDeviceID {
                presentedLocalDeviceID = next.devices.localDeviceID
            }
            for uri in confirmedTracks { recordPlayed(uri) }
            for id in settledIntentIDs where queueReplacementToken != id { effects.cancel(.commandDeadline(id)) }
            let nextIndicator = CurrentTrackIndicator(state: next)
            if currentTrackIndicator != nextIndicator {
                currentTrackIndicator = nextIndicator
            }
            let nextAvailability = CatalogPlaybackAvailability(state: next)
            if catalogPlaybackAvailability != nextAvailability {
                catalogPlaybackAvailability = nextAvailability
            }
            let nextPlayingContext =
                nextAvailability.isConnected && next.currentTrack != nil && next.transport != .stopped
                ? next.playbackContextURI : nil
            if playingContextURI != nextPlayingContext {
                playingContextURI = nextPlayingContext
            }
            publish()
            return reduction
        }
        // A rejected incoming event cannot discard a separately accepted dispatch receipt.
        if commit.needsPublication { publish() }
        SpottyLog.playback.debug(
            "Rejected event; source=\(String(describing: source), privacy: .public); account=\(stampedAccountEpoch, privacy: .public); engine=\(stampedEngineEpoch, privacy: .public); revision=\(String(describing: revision), privacy: .public)"
        )
        return .rejected
    }

    /// Stamps playback-scoped work with the exact lifetime captured before suspension.
    /// The reducer envelope remains scalar because account and engine have independent
    /// semantics there; command call sites cannot accidentally mix captures from two lifetimes.
    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        playbackLifetime: PlaybackLifetime,
        receivedAt: Date? = nil
    ) -> Bool {
        send(
            event,
            source: source,
            revision: revision,
            engineEpoch: playbackLifetime.engineGeneration,
            accountEpoch: playbackLifetime.accountEpoch,
            receivedAt: receivedAt
        )
    }

    @discardableResult
    func setPresentation(
        track: CurrentTrack?,
        transport: PlaybackTransportState? = nil,
        timing: PlaybackTiming? = nil,
        source: PlaybackEventSource = .user,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: track,
                    transport: transport ?? state.transport,
                    timing: timing ?? state.timing
                )),
            source: source,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
        )
    }

    @discardableResult
    func setTrackMetadata(
        uri: String,
        title: String?,
        artist: String?,
        artworkURL: URL?,
        duration: TimeInterval,
        provenance: MetadataProvenance,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .trackMetadata(
                PlaybackTrackMetadata(
                    uri: uri,
                    title: title,
                    artist: artist,
                    artworkURL: artworkURL,
                    duration: duration,
                    source: provenance
                )),
            source: .metadata,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
        )
    }

    @discardableResult
    func setTiming(
        position: TimeInterval,
        duration: TimeInterval? = nil,
        anchoredAt: Date? = nil,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .timing(
                position: position,
                duration: duration ?? self.duration,
                anchoredAt: anchoredAt ?? environment.clock.now()
            ),
            source: .user,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
        )
    }

    func setShuffleEnabled(_ enabled: Bool) {
        var options = state.options
        options.shuffle = enabled
        if send(.options(options), source: .user) { preferenceState.supersedeShuffleSeed() }
    }

    @discardableResult
    func setNotice(_ message: String?) -> UUID? {
        let notice = message.map { PlaybackNotice(message: $0) }
        guard send(.notice(notice), source: .user) else { return nil }
        return notice?.id
    }

    package func dismissPlaybackNotice(id: UUID) {
        guard state.notice?.id == id else { return }
        _ = send(.notice(nil), source: .user)
    }

    /// Every dispatch is tied to its admitted intent. Route predicates stay with orchestration;
    /// the transition owner validates current admission and owns the resulting capability.
    func makePlaybackDispatchPermit(
        intentID: UUID,
        ifStillWanted: @escaping @SessionRuntimeActor @Sendable () -> Bool
    ) -> PlaybackDispatchPermit? {
        transitions.dispatchPermit(for: intentID, ifStillWanted: ifStillWanted)
    }

    func invalidatePlaybackDispatchPermits() { transitions.invalidateDispatches() }

}

nonisolated enum LiveSpotifyError: LocalizedError {
    case streamingAuthorization(Int32)

    var errorDescription: String? {
        switch self {
        case let .streamingAuthorization(code):
            "Spotify playback authorization failed (\(code))"
        }
    }
}

import AppKit
import SpottyDomain
import Foundation
import Observation
import OSLog

/// Engine playback observation. Transport, empty-URI identity, and option values
/// are projected at intake (`PlaybackSnapshotProjection`).
nonisolated struct RustPlaybackState: Sendable {
    let revision: UInt64
    let sessionGeneration: UInt64
    let isPlaying: Bool
    let isPaused: Bool
    let trackURI: String
    let contextURI: String?
    let positionMS: Int64
    let durationMS: Int64
    let timestampMS: Int64
    let shuffle: Bool
    let repeatTrack: Bool
    let repeatContext: Bool
    /// One-shot local current-request failure from the retained engine. Synthetic callers that
    /// predate the wire field receive the safe default.
    let trackUnavailable: Bool
    /// Active-member fact captured with the same Connect player observation.
    /// The initializer defaults this for synthetic callers that predate the wire field.
    let isActiveDevice: Bool

    init(
        revision: UInt64,
        sessionGeneration: UInt64,
        isPlaying: Bool,
        isPaused: Bool,
        trackURI: String,
        positionMS: Int64,
        durationMS: Int64,
        timestampMS: Int64,
        shuffle: Bool,
        repeatTrack: Bool,
        repeatContext: Bool,
        trackUnavailable: Bool = false,
        isActiveDevice: Bool = false,
        contextURI: String? = nil
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.trackURI = trackURI
        self.contextURI = contextURI
        self.positionMS = positionMS
        self.durationMS = durationMS
        self.timestampMS = timestampMS
        self.shuffle = shuffle
        self.repeatTrack = repeatTrack
        self.repeatContext = repeatContext
        self.trackUnavailable = trackUnavailable
        self.isActiveDevice = isActiveDevice
    }
}

nonisolated struct RustQueueState: Sendable {
    /// Current-track identity from the engine. Catalog enrichment supplies names.
    struct Item: Sendable {
        let uri: String
        let provider: String
        let uid: String
    }

    let revision: UInt64
    let sessionGeneration: UInt64
    let track: Item?
    let protocolNextTracks: [QueueProtocolTrack]
    let protocolPrevTracks: [QueueProtocolTrack]
    let queueRevision: String
    let disallowSetQueue: Bool
    let disallowRemovingFromNextTracks: Bool
}

nonisolated struct RustConnectionState: Sendable {
    let revision: UInt64
    let sessionGeneration: UInt64
    let sessionConnected: Bool
    let spircReady: Bool
    let isActiveDevice: Bool
    /// Engine reconnect is holding readiness open for Swift's resume-load targets.
    let resumePending: Bool
    let lastError: String?
    let deviceID: String?
    /// Definitive streaming-credential rejection, distinct from generic reconnect failure.
    /// The initializer defaults this for synthetic callers that predate the wire field.
    let credentialsRejected: Bool

    init(
        revision: UInt64,
        sessionGeneration: UInt64,
        sessionConnected: Bool,
        spircReady: Bool,
        isActiveDevice: Bool,
        resumePending: Bool,
        lastError: String?,
        deviceID: String?,
        credentialsRejected: Bool = false
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.sessionConnected = sessionConnected
        self.spircReady = spircReady
        self.isActiveDevice = isActiveDevice
        self.resumePending = resumePending
        self.lastError = lastError
        self.deviceID = deviceID
        self.credentialsRejected = credentialsRejected
    }
}

nonisolated struct RustDevicesState: Sendable {
    let revision: UInt64
    let sessionGeneration: UInt64
    let activeDeviceID: String
    let devices: [ConnectProtocolDevice]
}

/// The small playback projection catalog rows need. It deliberately excludes timing so position
/// samples do not invalidate the rows that only draw current-track and transport state.
struct CurrentTrackIndicator: Equatable, Sendable {
    let trackURI: String?
    let isPlaying: Bool

    init(trackURI: String? = nil, isPlaying: Bool = false) {
        self.trackURI = trackURI
        self.isPlaying = isPlaying
    }

    init(state: PlaybackState) {
        let uri = state.currentTrack?.uri
        self.init(trackURI: uri?.isEmpty == false ? uri : nil, isPlaying: state.transport == .playing)
    }
}

/// Coarse catalog-facing capabilities derived from the reducer snapshot. Keeping these facts
/// separate from `state` lets catalog ancestors observe connection and command transitions without
/// subscribing to high-frequency timing changes.
struct CatalogPlaybackAvailability: Equatable, Sendable {
    let isConnected: Bool
    let hasPendingPlaybackCommand: Bool

    init(state: PlaybackState) {
        isConnected = state.session == .ready
        hasPendingPlaybackCommand = state.pendingCommands.keys.contains { $0 != .queue }
    }
}

nonisolated let spottyAudioRendererResult: Result<AudioRenderer, AudioRendererError> = {
    do {
        return .success(try AudioRenderer())
    } catch {
        SpottyLog.audio.error("Audio renderer initialization failed")
        return .failure(error as? AudioRendererError ?? .formatDescription(-1))
    }
}()

@MainActor
@Observable
final class PlaybackStore {
    typealias Phase = PlaybackSessionPhase

    private(set) var state = PlaybackState(accountEpoch: 1)
    /// Coarse track/transport observation for catalog rows. Timing changes never rewrite this
    /// value, so its observers only wake when the current track or playing state changes.
    private(set) var currentTrackIndicator = CurrentTrackIndicator()
    /// Coarse connection and command capability observation for catalog ancestors. This is a
    /// projection of accepted reducer state, not a second state owner.
    private(set) var catalogPlaybackAvailability = CatalogPlaybackAvailability(
        state: PlaybackState(accountEpoch: 1)
    )

    /// A typed engine credential rejection keeps the independent Keymaster grant intact while
    /// making the next account action an explicit browser reauthorization.
    private(set) var requiresReauthentication = false

    /// Catalog state lives in its own observable store; views that only draw
    /// catalog data can depend on it without observing playback at all.
    let catalog: CatalogStore
    let history = PlaybackHistoryStore()
    @ObservationIgnored let environment: PlaybackEnvironment
    /// App-composed mutation-feedback owner. Queue and playlist mutations
    /// report through this presenter rather than `PlaybackState.notice`.
    @ObservationIgnored let feedback: TransientFeedbackPresenter
    @ObservationIgnored let metadataService: TrackMetadataService
    @ObservationIgnored let coordinator: PlaybackCoordinator
    @ObservationIgnored let queueService: QueueService
    @ObservationIgnored let accountStore: AccountStore
    @ObservationIgnored let catalogSession: CatalogSessionAvailability
    /// Read-only projection of `AccountStore.epoch`. Do not increment or assign this value.
    var accountEpoch: UInt64 { accountStore.epoch }
    /// Swift-owned local display name. The engine no longer sends a hardcoded `device_name`.
    let thisDeviceName = "This Mac"
    @ObservationIgnored var lastRemoteDeviceID: String?
    /// The first Connect snapshot describes state that predates this process. It seeds the UI,
    /// but must not be counted as something the listener just played in this Spotty session.
    @ObservationIgnored var hasReceivedPlaybackSnapshot = false
    @ObservationIgnored let effects = PlaybackEffectRegistry()
    /// Observable while session teardown is active so native commands update their availability.
    /// The same gate rejects queued engine events while the old session is being cleared.
    var isTearingDown = false
    @ObservationIgnored var teardown = SessionTeardownCoalescer()
    @ObservationIgnored var teardownTask: Task<Void, Never>?
    @ObservationIgnored var terminationGate = PlaybackTerminationGate()
    /// Process-lifetime subscriptions start only after SwiftUI reaches the durable restore
    /// boundary. `SpottyApp` values may be initialized speculatively, so `init` must not subscribe.
    @ObservationIgnored var hasStartedLifetimeEffects = false
    @ObservationIgnored var lastEngineEventSequence: UInt64 = 0
    @ObservationIgnored var engineGeneration: UInt64 = 0
    /// Engine session generation whose reconnect rehydration Swift has already issued. The
    /// engine republishes `resume_pending` on every snapshot inside its window; one load
    /// sequence per rebuilt session is the contract.
    @ObservationIgnored var rehydratedSessionGeneration: UInt64?
    /// Whether the latest accepted connection snapshot still describes an open engine
    /// rehydration window (`resumePending` with `spircReady` clear). Read again immediately
    /// before a queued rehydration executes, so a window that closed while the coordinator
    /// was busy does not get a late load.
    @ObservationIgnored var engineRehydrationWindowOpen = false
    /// One immutable stamp for playback-scoped work. This projects the two existing
    /// lifecycle owners without becoming a third writable counter.
    var playbackLifetime: PlaybackLifetime {
        PlaybackLifetime(accountEpoch: accountEpoch, engineGeneration: engineGeneration)
    }
    /// MainActor watermark for Connect *callback* identity. Distinct from
    /// `state.sourceRevisions[.engineQueue]`, which tracks provenance snapshots after merge.
    @ObservationIgnored var connectQueueCallback = ConnectQueueCallbackWatermark()
    /// Inspector-facing version advanced only after a changed Connect URI ordering commits.
    /// Refresh-produced queue projections must never write it or restart their own hydration.
    var queueInspectorOrderingVersion: UInt64 = 0
    @ObservationIgnored var shuffleHistoryCache: [String: TimeInterval] = [:]
    /// Connect protocol queue used for `set_queue`. This is a MainActor projection of
    /// `QueueService`'s mutation snapshot, updated only after accepted Connect intake or a
    /// committed replacement. Web inspector refresh must not write it.
    @ObservationIgnored var queueMutation: QueueMutationSnapshot?
    /// Lifetime token for one in-flight Connect `set_queue` replacement. Not a source revision.
    /// A finished request clears only its own token so teardown cannot drop a newer session gate.
    @ObservationIgnored var queueReplacementToken: UUID?

    init(
        environment: PlaybackEnvironment = .live,
        feedback: TransientFeedbackPresenter
    ) {
        self.environment = environment
        self.feedback = feedback
        let metadataService = TrackMetadataService(remote: environment.remote)
        self.metadataService = metadataService
        let coordinator = PlaybackCoordinator(
            local: environment.local,
            remote: environment.remote,
            metadataService: metadataService
        )
        self.coordinator = coordinator
        queueService = QueueService(
            webQueue: environment.webQueue,
            metadata: metadataService,
            clock: environment.clock,
            hook: environment.queueServiceHook
        )
        accountStore = AccountStore(environment: environment, coordinator: coordinator)
        let catalogSession = CatalogSessionAvailability(accountEpoch: accountStore.epoch, isAvailable: false)
        self.catalogSession = catalogSession
        catalog = CatalogStore(
            provider: environment.catalog,
            attributesProvider: environment.trackAttributes,
            playlistMutations: environment.playlistMutations,
            session: catalogSession,
            clock: environment.clock,
            feedback: feedback
        )
        accountStore.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.catalogSession.update(
                accountEpoch: self.accountEpoch,
                isAvailable: phase == .ready
            )
            self.send(.session(phase), source: .account)
        }
        accountStore.onReauthenticationChange = { [weak self] required in
            guard let self else { return }
            self.requiresReauthentication = required
        }
        accountStore.onReady = { [weak self] in
            guard let self else { return }
            let epoch = self.accountEpoch
            self.effects.replace(
                .catalogLoad,
                with: Task { [weak self] in
                    guard let self, self.accountEpoch == epoch else { return }
                    await self.catalog.homeLibrary.load()
                })
        }
    }

    func startLifetimeEffectsIfNeeded() {
        guard !hasStartedLifetimeEffects else { return }
        hasStartedLifetimeEffects = true
        // Create each stream before account restoration can initialize the engine. The
        // subscription is therefore installed synchronously even though consumption is a task.
        let engineEvents = environment.local.events()
        let grantRevocations = environment.account.revocations()
        let lifecycleEvents = environment.lifecycle.events()
        effects.replace(
            .engineEvents,
            with: Task { [weak self] in
                for await envelope in engineEvents {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(envelope)
                }
            })
        effects.replace(
            .grantRevocations,
            with: Task { [weak self] in
                for await _ in grantRevocations {
                    guard !Task.isCancelled else { return }
                    await self?.handleGrantRevocation()
                }
            })
        effects.replace(
            .lifecycle,
            with: Task { [weak self] in
                for await event in lifecycleEvents {
                    guard !Task.isCancelled, let self else { return }
                    await self.receive(event)
                }
            })
        effects.replace(
            .queueServiceBootstrap,
            with: Task { [weak self] in
                guard let self else { return }
                await self.queueService.reset(accountEpoch: self.accountEpoch)
            })
        effects.replace(
            .preferencesRestore,
            with: Task { [weak self, environment] in
                guard let self else { return }
                let epoch = self.accountEpoch
                let shuffleEnabled = await environment.preferences.shuffleEnabled()
                guard
                    !Task.isCancelled,
                    self.terminationGate.allowsCommands,
                    self.accountEpoch == epoch
                else { return }
                self.setShuffleEnabled(shuffleEnabled)
                let lastRemoteDeviceID = await environment.preferences.lastRemoteDeviceID()
                guard
                    !Task.isCancelled,
                    self.terminationGate.allowsCommands,
                    self.accountEpoch == epoch
                else { return }
                self.lastRemoteDeviceID = lastRemoteDeviceID
                let shuffleHistory = await environment.preferences.shuffleHistory()
                guard
                    !Task.isCancelled,
                    self.terminationGate.allowsCommands,
                    self.accountEpoch == epoch
                else { return }
                self.shuffleHistoryCache = shuffleHistory
            })
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
    /// `AccountStore.epoch` projection) and `engineGeneration`, which mirrors `state.engineEpoch`
    /// after `reduce`. Reducer-owned `state.accountEpoch` is accepted snapshot state, not a
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
        let stampedAccountEpoch = accountEpoch ?? self.accountEpoch
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        var next = state
        let accepted = PlaybackReducer.reduce(
            &next,
            envelope: PlaybackEventEnvelope(
                accountEpoch: stampedAccountEpoch,
                engineEpoch: stampedEngineEpoch,
                source: source,
                revision: revision,
                receivedAt: receivedAt ?? environment.clock.now(),
                event: event
            )
        )
        if accepted {
            state = next
            engineGeneration = next.engineEpoch
            let nextIndicator = CurrentTrackIndicator(state: next)
            if currentTrackIndicator != nextIndicator {
                currentTrackIndicator = nextIndicator
            }
            let nextAvailability = CatalogPlaybackAvailability(state: next)
            if catalogPlaybackAvailability != nextAvailability {
                catalogPlaybackAvailability = nextAvailability
            }
            return true
        }
        SpottyLog.playback.debug(
            "Rejected event; source=\(String(describing: source), privacy: .public); account=\(stampedAccountEpoch, privacy: .public); engine=\(stampedEngineEpoch, privacy: .public); revision=\(String(describing: revision), privacy: .public)"
        )
        return false
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
        send(.options(options), source: .user)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        setRepeat(mode: mode, flags: mode.flags)
    }

    func setRepeat(mode: RepeatMode, flags: RepeatFlags) {
        var options = state.options
        options.repeatMode = mode
        options.repeatFlags = flags
        send(.options(options), source: .user)
    }

    @discardableResult
    func setNotice(_ message: String?) -> UUID? {
        let notice = message.map { PlaybackNotice(message: $0) }
        guard send(.notice(notice), source: .user) else { return nil }
        return notice?.id
    }

    func dismissPlaybackNotice(id: UUID) {
        guard state.notice?.id == id else { return }
        _ = send(.notice(nil), source: .user)
    }
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

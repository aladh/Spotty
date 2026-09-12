import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts
import SpottySessionRuntime

typealias CurrentTrackIndicator = SpottySessionRuntime.CurrentTrackIndicator
typealias CatalogPlaybackAvailability = SpottySessionRuntime.CatalogPlaybackAvailability

/// MainActor owns observation and native interaction. Playback/account authority and all command
/// effects live in PlaybackSessionRuntime on its dedicated transition executor.
@MainActor
@Observable
final class PlaybackStore {
    typealias Phase = PlaybackSessionPhase

    @ObservationIgnored let runtime: PlaybackSessionRuntime
    @ObservationIgnored private(set) var state = PlaybackState(accountEpoch: 1)
    private(set) var semantic = PlaybackSemanticProjection(state: PlaybackState(accountEpoch: 1))
    private(set) var timeline = PlaybackTiming(anchoredAt: .distantPast)
    private(set) var playbackDuration: TimeInterval = 0
    private(set) var presentedQueueEntries: [QueueEntry] = []
    private(set) var presentedDevices: [ConnectDevice] = []
    private(set) var presentedLocalDeviceID: String?
    private(set) var currentTrackIndicator = CurrentTrackIndicator()
    private(set) var playingContextURI: String?
    private(set) var catalogPlaybackAvailability = CatalogPlaybackAvailability(state: PlaybackState(accountEpoch: 1))
    private(set) var requiresReauthentication = false
    private(set) var accountEpoch: UInt64 = 1
    private(set) var engineGeneration: UInt64 = 0
    private(set) var queueInspectorOrderingVersion: UInt64 = 0
    private(set) var isTearingDown = false
    private(set) var allowsCommands = true
    let thisDeviceName = "This Mac"
    let catalog: CatalogStore
    let history = PlaybackHistoryStore()
    @ObservationIgnored let feedback: TransientFeedbackPresenter
    @ObservationIgnored let artworkProvider: any ArtworkProviding
    @ObservationIgnored let catalogSession: CatalogSessionAvailability
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var lastRevision: UInt64 = 0
    @ObservationIgnored private var lastFeedbackRevision: UInt64 = 0
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var lastMetadata: [CatalogTrack] = []
    @ObservationIgnored private var lastCatalogInputRevision: UInt64?
    @ObservationIgnored private var lastCatalogInputEpoch: UInt64?

    deinit { subscription?.cancel() }

    init(environment: PlaybackEnvironment, feedback: TransientFeedbackPresenter) {
        self.feedback = feedback
        artworkProvider = environment.artwork
        runtime = SessionRuntimeActor.sync { PlaybackSessionRuntime(environment: environment) }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: false)
        catalogSession = session
        catalog = CatalogStore(
            provider: environment.catalog, attributesProvider: environment.trackAttributes,
            playlistMutations: environment.playlistMutations, session: session,
            clock: environment.clock, feedback: feedback)
        let runtime = self.runtime
        SessionRuntimeActor.sync {
            runtime.setCatalogLoader { [weak self] in await self?.loadCatalog() }
        }
        apply(SessionRuntimeActor.sync { runtime.presentation() })
        installPresentationSubscription()
    }

    private func loadCatalog() async {
        let runtime = runtime
        apply(SessionRuntimeActor.sync { runtime.presentation() })
        await catalog.homeLibrary.load()
        synchronizeCatalogMetadata()
    }

    /// A bounded synchronous mailbox entrance is retained for local admission and deterministic
    /// scenarios. Every operation runs off MainActor and returns before any I/O worker settles.
    @discardableResult
    func withRuntime<Value: Sendable>(
        _ operation: @SessionRuntimeActor (PlaybackSessionRuntime) -> Value
    ) -> Value {
        synchronizeCatalogMetadata()
        let runtime = runtime
        let result = SessionRuntimeActor.sync {
            let result = operation(runtime)
            runtime.publish()
            return result
        }
        apply(SessionRuntimeActor.sync { runtime.presentation() })
        return result
    }

    /// A rendered action belongs to the account/lifetime the desktop displayed. The runtime can
    /// advance before MainActor consumes its next snapshot, so validate that stamp at admission.
    private func performRuntimeCommand(
        checksPlaybackLifetime: Bool = true,
        reportsStale: Bool = true,
        _ operation: @SessionRuntimeActor (PlaybackSessionRuntime) -> Void
    ) {
        let epoch = accountEpoch
        let generation = engineGeneration
        let route = commandRoute
        synchronizeCatalogMetadata()
        let runtime = runtime
        let accepted = SessionRuntimeActor.sync {
            guard runtime.accountEpoch == epoch else { return false }
            if checksPlaybackLifetime {
                guard runtime.engineGeneration == generation, runtime.commandRoute == route else { return false }
            }
            operation(runtime)
            runtime.publish()
            return true
        }
        apply(SessionRuntimeActor.sync { runtime.presentation() })
        if !accepted, reportsStale {
            feedback.informational("The playback session changed. Try again.")
        }
    }

    private func synchronizeCatalogMetadata() {
        guard !isApplying, catalogSession.snapshot.isAvailable else { return }
        let epoch = accountEpoch
        let revision = catalog.metadata.runtimeTracksRevision
        guard revision != lastCatalogInputRevision || epoch != lastCatalogInputEpoch else { return }
        let tracks = Array(catalog.metadata.runtimeTracks.values)
        let runtime = runtime
        if SessionRuntimeActor.sync({ runtime.acceptCatalogMetadata(tracks, accountEpoch: epoch) }) {
            lastCatalogInputRevision = revision
            lastCatalogInputEpoch = epoch
        }
    }

    private func installPresentationSubscription() {
        if subscription == nil {
            let runtime = runtime
            let stream = SessionRuntimeActor.sync { runtime.presentations() }
            subscription = Task { [weak self] in
                for await value in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.apply(value)
                }
            }
        }
    }

    func startLifetimeEffectsIfNeeded() {
        installPresentationSubscription()
        withRuntime { $0.startLifetimeEffectsIfNeeded() }
    }

    private func apply(_ value: RuntimePresentation) {
        guard value.revision >= lastRevision else { return }
        isApplying = true
        defer { isApplying = false }
        lastRevision = value.revision
        let changedAccount = accountEpoch != value.accountEpoch
        accountEpoch = value.accountEpoch
        catalogSession.update(accountEpoch: value.accountEpoch, isAvailable: value.catalogAvailable)
        if changedAccount {
            catalog.reset()
            history.reset()
            lastMetadata = []
            lastCatalogInputRevision = nil
            lastCatalogInputEpoch = nil
        }
        let previousState = state
        state = value.state
        let nextSemantic = PlaybackSemanticProjection(state: value.state)
        if semantic != nextSemantic { semantic = nextSemantic }
        if timeline != value.state.timing { timeline = value.state.timing }
        if playbackDuration != value.state.timing.duration { playbackDuration = value.state.timing.duration }
        if engineGeneration != value.engineGeneration { engineGeneration = value.engineGeneration }
        if queueInspectorOrderingVersion != value.queueInspectorOrderingVersion {
            queueInspectorOrderingVersion = value.queueInspectorOrderingVersion
        }
        if requiresReauthentication != value.requiresReauthentication {
            requiresReauthentication = value.requiresReauthentication
        }
        if isTearingDown != value.isTearingDown { isTearingDown = value.isTearingDown }
        if allowsCommands != value.allowsCommands { allowsCommands = value.allowsCommands }
        if previousState.queue.entries != value.state.queue.entries {
            let queue = QueueEntry.uniquelyIdentified(
                value.state.queue.entries.map {
                    QueueEntry(uri: $0.uri, provider: $0.provider, occurrence: $0.occurrence, uid: $0.uid)
                })
            if presentedQueueEntries != queue { presentedQueueEntries = queue }
        }
        if previousState.devices.devices != value.state.devices.devices {
            let devices = value.state.devices.devices.map {
                ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
            }
            if presentedDevices != devices { presentedDevices = devices }
        }
        if presentedLocalDeviceID != value.state.devices.localDeviceID {
            presentedLocalDeviceID = value.state.devices.localDeviceID
        }
        let indicator = CurrentTrackIndicator(state: value.state)
        if currentTrackIndicator != indicator { currentTrackIndicator = indicator }
        let availability = CatalogPlaybackAvailability(state: value.state)
        if catalogPlaybackAvailability != availability { catalogPlaybackAvailability = availability }
        let context =
            availability.isConnected && value.state.transport == .playing ? value.state.playbackContextURI : nil
        if playingContextURI != context { playingContextURI = context }
        history.replaceEntries(value.history)
        if value.catalogAvailable, lastMetadata != value.metadata {
            lastMetadata = value.metadata
            catalog.metadata.replaceTracks(value.metadata, from: .queue)
        }
        if let message = value.feedback, message.revision > lastFeedbackRevision {
            lastFeedbackRevision = message.revision
            switch message.kind {
            case .success: feedback.success(message.text)
            case .informational: feedback.informational(message.text)
            case .failure: feedback.failure(message.text)
            case .dismiss: feedback.dismiss()
            }
        }
    }

    func restore() async {
        startLifetimeEffectsIfNeeded()
        let epoch = accountEpoch
        _ = await runtime.restore(expectedAccountEpoch: epoch)
        withRuntime { _ in }
    }

    func connect() { performRuntimeCommand(checksPlaybackLifetime: false) { $0.connect() } }
    func reauthorize() { performRuntimeCommand(checksPlaybackLifetime: false) { $0.reauthorize() } }
    func cancelConnect() { performRuntimeCommand(checksPlaybackLifetime: false) { $0.cancelConnect() } }
    func logout() async {
        let epoch = accountEpoch
        _ = await runtime.logout(expectedAccountEpoch: epoch)
        withRuntime { _ in }
    }
    func shutdownForTermination() async {
        await runtime.shutdownForTermination()
        withRuntime { _ in }
        subscription?.cancel()
        subscription = nil
    }

    func play(uri: String) { performRuntimeCommand { $0.play(uri: uri) } }
    func play(track: CatalogTrack) { performRuntimeCommand { $0.play(track: track) } }
    func playPlaylist(_ item: CatalogItem) {
        let tracks = catalog.playlistStore.tracks
        let uri = catalog.playlistStore.loadedURI
        performRuntimeCommand { $0.playPlaylist(item, tracks: tracks, loadedURI: uri) }
    }
    func togglePlayback() { performRuntimeCommand { $0.togglePlayback() } }
    func next() { performRuntimeCommand { $0.next() } }
    func previous() { performRuntimeCommand { $0.previous() } }
    func seek(to fraction: Double) { performRuntimeCommand { $0.seek(to: fraction) } }
    func toggleShuffle() { performRuntimeCommand { $0.toggleShuffle() } }
    func cycleRepeat() { performRuntimeCommand { $0.cycleRepeat() } }
    func transferPlayback(to device: ConnectDevice) { performRuntimeCommand { $0.transferPlayback(to: device) } }
    func addToQueue(uris: [String]) { performRuntimeCommand { $0.addToQueue(uris: uris) } }
    func removeUpcomingQueueOccurrences(selectedIDs: Set<String>) {
        performRuntimeCommand { $0.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs) }
    }
    func canRemoveUpcomingQueue(selectedIDs: Set<String>) -> Bool {
        let runtime = runtime
        return SessionRuntimeActor.sync { runtime.canRemoveUpcomingQueue(selectedIDs: selectedIDs) }
    }
    func refreshQueue() {
        performRuntimeCommand(checksPlaybackLifetime: false, reportsStale: false) { $0.refreshQueue() }
    }
    func refreshQueueSnapshot() {
        performRuntimeCommand(checksPlaybackLifetime: false, reportsStale: false) { $0.refreshQueueSnapshot() }
    }
    func cancelQueueRefresh() {
        performRuntimeCommand(checksPlaybackLifetime: false, reportsStale: false) { $0.cancelQueueRefresh() }
    }
    func refreshPosition() {
        performRuntimeCommand(checksPlaybackLifetime: false, reportsStale: false) { $0.refreshPosition() }
    }
    func dismissPlaybackNotice(id: UUID) {
        performRuntimeCommand(checksPlaybackLifetime: false) { $0.dismissPlaybackNotice(id: id) }
    }
}

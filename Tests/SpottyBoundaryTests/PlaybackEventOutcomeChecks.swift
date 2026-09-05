import Testing
import SpottyDomain
import Foundation
import Observation
@testable import SpottyCore

private final class GatedPositionEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    var milliseconds: UInt32 = 42_000

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 {
        lock.lock()
        didStart = true
        lock.unlock()
        gate.wait()
        return milliseconds
    }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    func release() {
        gate.signal()
    }
}

private final class GatedQueueSnapshotEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    private var snapshot: RustQueueState?

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? {
        lock.lock()
        didStart = true
        lock.unlock()
        gate.wait()
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    func release(_ snapshot: RustQueueState) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
        gate.signal()
    }
}

private final class IdleLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }
    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private actor GatedMetadataRemote: RemotePlaybackClient {
    private var continuation: CheckedContinuation<SpotifyConnectTrackMetadata, Never>?
    private(set) var requestedURI: String?

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        requestedURI = uri
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(title: String = "Resolved") {
        guard let uri = requestedURI else { return }
        continuation?.resume(
            returning: SpotifyConnectTrackMetadata(
                uri: uri,
                title: title,
                artist: "Artist",
                artworkURL: nil,
                duration: 180
            )
        )
        continuation = nil
    }
}

private actor ImmediateMetadataRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Resolved",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        )
    }
}

private actor IdleWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private actor SuspendedWebQueue: WebQueueClient {
    private var continuation: CheckedContinuation<[CatalogTrack], any Error>?
    private(set) var requestCount = 0

    func queue() async throws -> [CatalogTrack] {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(with tracks: [CatalogTrack]) {
        continuation?.resume(returning: tracks)
        continuation = nil
    }
}

private actor IdlePreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private actor RecordingOwnerPreferences: PlaybackPreferences {
    private var remoteID: String?

    func seed(_ id: String?) { remoteID = id }
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { remoteID }
    func setLastRemoteDeviceID(_ id: String?) { remoteID = id }
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct StickyClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    func increment() {
        lock.lock()
        countStorage += 1
        lock.unlock()
    }
}

private func outcomeEnvironment(
    local: any LocalPlaybackEngine = IdleLocalEngine(),
    remote: any RemotePlaybackClient,
    webQueue: any WebQueueClient = IdleWebQueue(),
    preferences: any PlaybackPreferences = IdlePreferences()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: webQueue,
        account: BoundaryIdleAccount(),
        audioOutput: BoundaryIdleAudio(),
        preferences: preferences,
        lifecycle: BoundaryIdleLifecycle(),
        clock: StickyClock(),
        catalog: BoundaryIdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: BoundaryIdleAttributes()
    )
}

@MainActor
private func playbackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

private func fixtureTrack(_ uri: String, title: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: title,
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private func fixtureQueueSnapshot(
    accountEpoch: UInt64,
    revision: UInt64,
    uri: String,
    title: String
) -> ProvenanceQueueSnapshot {
    ProvenanceQueueSnapshot(
        accountEpoch: accountEpoch,
        revision: revision,
        source: .connect,
        completeness: .complete,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        contextURI: uri,
        entries: [QueueEntry(uri: uri, provider: "connect", occurrence: 0)],
        tracks: [fixtureTrack(uri, title: title)]
    )
}

@MainActor
private func seedReadyLocalPlayback(
    _ player: PlaybackStore,
    uri: String,
    title: String? = "Now",
    metadataSource: MetadataProvenance = .catalog
) {
    let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [device],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .presentation(
            PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: uri,
                    title: title,
                    artist: title == nil ? nil : "Artist",
                    duration: 200,
                    metadataSource: metadataSource
                ),
                transport: .playing,
                timing: PlaybackTiming(
                    position: 5,
                    duration: 200,
                    anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )),
        source: .user
    )
}

private func queueSnapshot(
    uri: String,
    revision: UInt64 = 1,
    sessionGeneration: UInt64 = 1
) -> RustQueueState {
    RustQueueState(
        revision: revision,
        sessionGeneration: sessionGeneration,
        track: RustQueueState.Item(uri: uri, provider: "context", uid: "occ-now"),
        protocolNextTracks: [],
        protocolPrevTracks: [],
        queueRevision: "",
        disallowSetQueue: false,
        disallowRemovingFromNextTracks: false
    )
}

@MainActor
private func bumpEngine(_ player: PlaybackStore) {
    _ = player.send(
        .engineConnection(
            EngineConnectionSnapshot(
                session: .ready,
                owner: player.state.owner,
                localDeviceID: player.localDeviceID
            )),
        source: .engineConnection,
        revision: (player.state.sourceRevisions[.engineConnection] ?? 0) + 1,
        engineEpoch: player.engineGeneration + 1
    )
}

@MainActor
private func startTrackResolution(_ player: PlaybackStore, uri: String) {
    player.receive(
        RustPlaybackState(
            revision: 1,
            sessionGeneration: player.engineGeneration,
            isPlaying: true,
            isPaused: false,
            trackURI: uri,
            positionMS: 1_000,
            durationMS: 180_000,
            timestampMS: 0,
            shuffle: false,
            repeatTrack: false,
            repeatContext: false
        ),
        revision: 1,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@MainActor
private func awaitCapturedEffect(
    _ settlement: PlaybackEffectSettlement?,
    registered: String
) async {
    #expect((settlement) != nil, "\(registered)")
    await settlement?.wait()
}

@Suite("Playback Event Outcome")
struct PlaybackEventOutcomeTests {
    @Test
    @MainActor
    func testCatalogPlaybackObservationSkipsTimingTicks() async {
        let player = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedReadyLocalPlayback(player, uri: "spotify:track:indicator")

        let initialIndicator = player.currentTrackIndicator
        let initialAvailability = player.catalogPlaybackAvailability
        let invalidations = ObservationCounter()
        withObservationTracking {
            _ = player.currentTrackIndicator
            _ = player.catalogPlaybackAvailability
            _ = player.canStartPlayback
        } onChange: {
            invalidations.increment()
        }

        #expect(player.setTiming(position: 42), "the timing sample is accepted")
        #expect(player.position == 42, "authoritative timing advances without notifying catalog observers")
        #expect(
            (player.currentTrackIndicator) == (initialIndicator),
            "position samples preserve the coarse track/transport indicator"
        )
        #expect(
            (player.catalogPlaybackAvailability) == (initialAvailability),
            "position samples preserve coarse catalog capabilities"
        )
        #expect((invalidations.count) == (0), "position samples do not invalidate coarse catalog observation")

        _ = player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: player.state.currentTrack,
                    transport: .paused,
                    timing: player.state.timing
                )),
            source: .user
        )
        #expect((player.currentTrackIndicator.trackURI) == ("spotify:track:indicator"))
        #expect((player.currentTrackIndicator.isPlaying) == (false), "transport changes update the indicator")
        #expect((invalidations.count) == (1), "transport changes invalidate coarse catalog observation")

        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func testPlaybackEventOutcome() async {
        do {
            let successRemote = GatedMetadataRemote()
            let success = playbackStore(outcomeEnvironment(remote: successRemote))
            startTrackResolution(success, uri: "spotify:track:success")
            #expect(
                (await waitUntil { await successRemote.requestedURI == "spotify:track:success" }) == true,
                "metadata lookup starts")
            success.recordPlayed("spotify:track:success")
            await successRemote.complete()
            #expect(
                (await waitUntil { success.state.currentTrack?.title == "Resolved" }) == true,
                "accepted metadata updates the current track")
            #expect(
                (success.state.currentTrack?.metadataSource) == (.connect), "accepted metadata uses connect provenance")
            #expect(
                (success.history.entries.first?.title) == ("Resolved"),
                "history enrichment waits for reducer acceptance")
            await success.shutdownForTermination()

            let staleEngineRemote = GatedMetadataRemote()
            let staleEngine = playbackStore(outcomeEnvironment(remote: staleEngineRemote))
            startTrackResolution(staleEngine, uri: "spotify:track:stale-engine")
            #expect(
                (await waitUntil { await staleEngineRemote.requestedURI != nil }) == true,
                "stale-engine metadata lookup starts")
            let staleEngineMetadata = staleEngine.effects.settlement(of: .trackMetadata)
            bumpEngine(staleEngine)
            await staleEngineRemote.complete(title: "Late engine")
            await awaitCapturedEffect(
                staleEngineMetadata,
                registered: "stale-engine metadata effect is registered before invalidation"
            )
            #expect(
                (staleEngine.state.currentTrack?.title) == nil,
                "stale-engine metadata does not mutate the current title")
            #expect((staleEngine.history.entries.isEmpty) == true, "stale-engine metadata does not create history")
            await staleEngine.shutdownForTermination()

            let staleAccountRemote = GatedMetadataRemote()
            let staleAccount = playbackStore(outcomeEnvironment(remote: staleAccountRemote))
            startTrackResolution(staleAccount, uri: "spotify:track:stale-account")
            #expect(
                (await waitUntil { await staleAccountRemote.requestedURI != nil }) == true,
                "stale-account metadata lookup starts")
            staleAccount.recordPlayed("spotify:track:stale-account")
            let staleAccountMetadata = staleAccount.effects.settlement(of: .trackMetadata)
            staleAccount.accountStore.advanceEpoch()
            _ = staleAccount.send(
                .reset(session: .signedOut),
                source: .account,
                accountEpoch: staleAccount.accountEpoch
            )
            await staleAccountRemote.complete(title: "Late account")
            await awaitCapturedEffect(
                staleAccountMetadata,
                registered: "stale-account metadata effect is registered before invalidation"
            )
            #expect((staleAccount.state.currentTrack) == nil, "stale-account metadata cannot revive a reset track")
            #expect(
                (staleAccount.history.entries.first?.title) == ("Unknown track"),
                "stale-account metadata does not enrich history after reset")
            await staleAccount.shutdownForTermination()

            let cancelRemote = GatedMetadataRemote()
            let cancelled = playbackStore(outcomeEnvironment(remote: cancelRemote))
            startTrackResolution(cancelled, uri: "spotify:track:cancelled")
            #expect(
                (await waitUntil { await cancelRemote.requestedURI != nil }) == true, "cancelled metadata lookup starts"
            )
            cancelled.recordPlayed("spotify:track:cancelled")
            let cancelledMetadata = cancelled.effects.settlement(of: .trackMetadata)
            cancelled.effects.cancel(.trackMetadata)
            await cancelRemote.complete(title: "Cancelled")
            await awaitCapturedEffect(
                cancelledMetadata,
                registered: "cancelled metadata effect is registered before cancellation"
            )
            #expect((cancelled.state.currentTrack?.title) == nil, "cancelled metadata is inert")
            #expect(
                (cancelled.history.entries.first?.title) == ("Unknown track"),
                "cancelled metadata does not enrich history")
            await cancelled.shutdownForTermination()

            let rejectedRemote = GatedMetadataRemote()
            let rejected = playbackStore(outcomeEnvironment(remote: rejectedRemote))
            startTrackResolution(rejected, uri: "spotify:track:original")
            #expect(
                (await waitUntil { await rejectedRemote.requestedURI == "spotify:track:original" }) == true,
                "reducer-rejection metadata lookup starts")
            rejected.recordPlayed("spotify:track:original")
            _ = rejected.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:other", title: "Other", metadataSource: .catalog),
                        transport: .paused,
                        timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                    )),
                source: .user
            )
            let rejectedMetadata = rejected.effects.settlement(of: .trackMetadata)
            await rejectedRemote.complete(title: "From original")
            await awaitCapturedEffect(
                rejectedMetadata,
                registered: "reducer-rejection metadata effect is registered before completion"
            )
            #expect(
                (rejected.state.currentTrack?.uri) == ("spotify:track:other"),
                "metadata for a previous track is rejected")
            #expect(
                (rejected.history.entries.first?.title) == ("Unknown track"),
                "rejected metadata does not enrich the prior history row")
            await rejected.shutdownForTermination()
        }

        do {
            let successEngine = GatedPositionEngine()
            let success = playbackStore(
                outcomeEnvironment(local: successEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(success, uri: "spotify:track:playing")
            success.refreshPosition()
            #expect((await waitUntil { successEngine.hasStarted }) == true, "position refresh starts")
            successEngine.release()
            #expect(
                (await waitUntil { success.state.timing.position == 42 }) == true,
                "accepted timing replaces the anchored position")
            await success.shutdownForTermination()

            let staleAccountEngine = GatedPositionEngine()
            let staleAccount = playbackStore(
                outcomeEnvironment(local: staleAccountEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(staleAccount, uri: "spotify:track:playing")
            staleAccount.refreshPosition()
            #expect(
                (await waitUntil { staleAccountEngine.hasStarted }) == true, "stale-account position refresh starts")
            let staleAccountPosition = staleAccount.effects.settlement(of: .positionRefresh)
            staleAccount.accountStore.advanceEpoch()
            _ = staleAccount.send(
                .reset(session: .signedOut),
                source: .account,
                accountEpoch: staleAccount.accountEpoch
            )
            staleAccountEngine.release()
            await awaitCapturedEffect(
                staleAccountPosition,
                registered: "stale-account position refresh is registered before invalidation"
            )
            #expect(
                (staleAccount.state.timing.position) == (0),
                "stale-account position refresh cannot stamp signed-out timing"
            )
            await staleAccount.shutdownForTermination()

            let staleEngineEngine = GatedPositionEngine()
            let staleEngine = playbackStore(
                outcomeEnvironment(local: staleEngineEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(staleEngine, uri: "spotify:track:playing")
            staleEngine.refreshPosition()
            #expect((await waitUntil { staleEngineEngine.hasStarted }) == true, "stale-engine position refresh starts")
            let staleEnginePosition = staleEngine.effects.settlement(of: .positionRefresh)
            bumpEngine(staleEngine)
            staleEngineEngine.release()
            await awaitCapturedEffect(
                staleEnginePosition,
                registered: "stale-engine position refresh is registered before invalidation"
            )
            #expect((staleEngine.state.timing.position) == (5), "stale-engine position refresh is inert")
            await staleEngine.shutdownForTermination()

            let cancelEngine = GatedPositionEngine()
            let cancelled = playbackStore(
                outcomeEnvironment(local: cancelEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(cancelled, uri: "spotify:track:playing")
            cancelled.refreshPosition()
            #expect((await waitUntil { cancelEngine.hasStarted }) == true, "cancelled position refresh starts")
            let cancelledPosition = cancelled.effects.settlement(of: .positionRefresh)
            cancelled.effects.cancel(.positionRefresh)
            cancelEngine.release()
            await awaitCapturedEffect(
                cancelledPosition,
                registered: "cancelled position refresh is registered before cancellation"
            )
            #expect((cancelled.state.timing.position) == (5), "cancelled position refresh is inert")
            await cancelled.shutdownForTermination()
        }

        do {
            let player = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
            _ = player.send(.session(.ready), source: .account)
            player.catalogSession.update(accountEpoch: player.accountEpoch, isAvailable: true)

            let firstURI = "spotify:track:first"
            player.apply(
                fixtureQueueSnapshot(accountEpoch: player.accountEpoch, revision: 1, uri: firstURI, title: "First"),
                engineEpoch: player.engineGeneration
            )
            #expect((player.state.queue.entries.first?.uri) == (firstURI), "accepted queue replaces ordering")
            #expect(
                (player.catalog.metadata.knownTrack(for: firstURI)?.title) == ("First"),
                "accepted queue retains catalog metadata")

            let duplicateURI = "spotify:track:duplicate"
            player.apply(
                fixtureQueueSnapshot(
                    accountEpoch: player.accountEpoch, revision: 1, uri: duplicateURI, title: "Duplicate"),
                engineEpoch: player.engineGeneration
            )
            #expect((player.state.queue.entries.first?.uri) == (firstURI), "a duplicate queue revision is rejected")
            #expect(
                (player.catalog.metadata.knownTrack(for: duplicateURI)) == nil,
                "rejected queue state does not replace catalog metadata")
            #expect(
                (player.catalog.metadata.knownTrack(for: firstURI)?.title) == ("First"),
                "rejected queue keeps the accepted catalog row")

            let capturedEngine = player.engineGeneration
            bumpEngine(player)
            let staleEngineURI = "spotify:track:stale-engine"
            player.apply(
                fixtureQueueSnapshot(
                    accountEpoch: player.accountEpoch, revision: 2, uri: staleEngineURI, title: "Late engine"),
                engineEpoch: capturedEngine
            )
            #expect((player.state.queue.entries.first?.uri) == (firstURI), "stale-engine queue adoption is inert")
            #expect(
                (player.catalog.metadata.knownTrack(for: staleEngineURI)) == nil,
                "stale-engine queue does not retain catalog metadata")

            player.accountStore.advanceEpoch()
            _ = player.send(
                .reset(session: .signedOut),
                source: .account,
                accountEpoch: player.accountEpoch
            )
            let staleAccountURI = "spotify:track:stale-account"
            player.apply(
                fixtureQueueSnapshot(accountEpoch: 1, revision: 3, uri: staleAccountURI, title: "Late account"),
                engineEpoch: player.engineGeneration
            )
            #expect((player.state.queue.entries.isEmpty) == true, "stale-account queue adoption is inert")
            #expect(
                (player.catalog.metadata.knownTrack(for: staleAccountURI)) == nil,
                "stale-account queue does not retain catalog metadata")
            await player.shutdownForTermination()

            let webQueue = SuspendedWebQueue()
            let cancelled = playbackStore(
                outcomeEnvironment(remote: ImmediateMetadataRemote(), webQueue: webQueue)
            )
            await cancelled.restore()
            _ = cancelled.send(.session(.ready), source: .account)
            cancelled.catalogSession.update(accountEpoch: cancelled.accountEpoch, isAvailable: true)
            cancelled.refreshQueue()
            #expect((await waitUntil { await webQueue.requestCount == 1 }) == true, "queue refresh starts")
            let cancelledQueueRefresh = cancelled.effects.settlement(of: .queueRefresh)
            cancelled.cancelQueueRefresh()
            await webQueue.complete(with: [fixtureTrack("spotify:track:cancelled-queue", title: "Cancelled")])
            await awaitCapturedEffect(
                cancelledQueueRefresh,
                registered: "cancelled queue refresh is registered before cancellation"
            )
            #expect((cancelled.state.queue.entries.isEmpty) == true, "cancelled queue refresh does not adopt ordering")
            #expect(
                (cancelled.catalog.metadata.knownTrack(for: "spotify:track:cancelled-queue")) == nil,
                "cancelled queue refresh does not retain catalog metadata")
            await cancelled.shutdownForTermination()
        }

        do {
            let namedEngine = GatedQueueSnapshotEngine()
            let namedRemote = GatedMetadataRemote()
            let named = playbackStore(
                outcomeEnvironment(local: namedEngine, remote: namedRemote)
            )
            let uri = "spotify:track:same"
            seedReadyLocalPlayback(named, uri: uri)
            named.recordPlayed(uri)
            named.refreshQueueSnapshot()
            #expect((await waitUntil { namedEngine.hasStarted }) == true, "named queue snapshot fetch starts")
            let namedSnapshot = named.effects.settlement(of: .queueSnapshot)
            let staleNamedGeneration = named.engineGeneration
            bumpEngine(named)
            namedEngine.release(queueSnapshot(uri: uri, sessionGeneration: staleNamedGeneration))
            await awaitCapturedEffect(
                namedSnapshot,
                registered: "stale named snapshot effect is registered before invalidation"
            )
            #expect(
                (named.state.currentTrack?.title) == ("Now"), "stale named snapshot cannot replace now-playing title")
            #expect(
                (named.state.currentTrack?.artist) == ("Artist"),
                "stale named snapshot cannot replace now-playing artist")
            #expect(
                (named.history.entries.first?.title) == ("Unknown track"),
                "stale named snapshot does not enrich history")
            #expect((await namedRemote.requestedURI) == nil, "stale named snapshot does not start metadata resolution")
            await named.shutdownForTermination()

            let missingEngine = GatedQueueSnapshotEngine()
            let missingRemote = GatedMetadataRemote()
            let missing = playbackStore(
                outcomeEnvironment(local: missingEngine, remote: missingRemote)
            )
            seedReadyLocalPlayback(missing, uri: uri, title: nil, metadataSource: .none)
            missing.recordPlayed(uri)
            missing.refreshQueueSnapshot()
            #expect((await waitUntil { missingEngine.hasStarted }) == true, "nameless queue snapshot fetch starts")
            let missingSnapshot = missing.effects.settlement(of: .queueSnapshot)
            let staleMissingGeneration = missing.engineGeneration
            bumpEngine(missing)
            missingEngine.release(queueSnapshot(uri: uri, sessionGeneration: staleMissingGeneration))
            await awaitCapturedEffect(
                missingSnapshot,
                registered: "stale nameless snapshot effect is registered before invalidation"
            )
            #expect((missing.state.currentTrack?.title) == nil, "stale nameless snapshot cannot install a title")
            #expect((missing.state.currentTrack?.uri) == (uri), "stale nameless snapshot keeps the current URI")
            #expect(
                (missing.history.entries.first?.title) == ("Unknown track"),
                "stale nameless snapshot does not enrich history")
            #expect(
                (await missingRemote.requestedURI) == nil, "stale nameless snapshot does not launch a metadata resolver"
            )
            await missing.shutdownForTermination()

            let watermarkEngine = GatedQueueSnapshotEngine()
            let watermarkStore = playbackStore(
                outcomeEnvironment(local: watermarkEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(watermarkStore, uri: uri)
            let before = watermarkStore.connectQueueCallback
            watermarkStore.refreshQueueSnapshot()
            #expect((await waitUntil { watermarkEngine.hasStarted }) == true, "watermark snapshot fetch starts")
            let watermarkSnapshot = watermarkStore.effects.settlement(of: .queueSnapshot)
            let staleWatermarkGeneration = watermarkStore.engineGeneration
            bumpEngine(watermarkStore)
            watermarkEngine.release(
                queueSnapshot(uri: uri, revision: 9, sessionGeneration: staleWatermarkGeneration)
            )
            await awaitCapturedEffect(
                watermarkSnapshot,
                registered: "stale watermark snapshot effect is registered before invalidation"
            )
            #expect(
                (watermarkStore.connectQueueCallback.generation) == (before.generation),
                "a stale snapshot does not advance the callback generation")
            #expect(
                (watermarkStore.connectQueueCallback.revision) == (before.revision),
                "a stale snapshot does not advance the callback revision")
            #expect(
                (watermarkStore.acceptsConnectQueueCallback(
                    generation: watermarkStore.engineGeneration,
                    revision: 1
                )) == true, "a later live callback can still start a fresh revision namespace")
            await watermarkStore.shutdownForTermination()

            let payloadEngine = GatedQueueSnapshotEngine()
            let payloadStore = playbackStore(
                outcomeEnvironment(local: payloadEngine, remote: ImmediateMetadataRemote())
            )
            await payloadStore.restore()
            seedReadyLocalPlayback(payloadStore, uri: uri)
            let mirroredGeneration = payloadStore.engineGeneration
            let payloadGeneration = mirroredGeneration + 1
            payloadStore.refreshQueueSnapshot()
            #expect((await waitUntil { payloadEngine.hasStarted }) == true, "payload-generation snapshot fetch starts")
            payloadEngine.release(
                queueSnapshot(
                    uri: uri,
                    revision: 3,
                    sessionGeneration: payloadGeneration
                )
            )
            #expect(
                (await waitUntil { payloadStore.state.engineEpoch == payloadGeneration }) == true,
                "decoded payload generation stamps reducer state before playback catches up")
            #expect(
                (payloadStore.engineGeneration) == (payloadGeneration), "decoded payload generation stamps presentation"
            )
            #expect(
                (payloadStore.state.currentTrack?.title) == ("Now"),
                "decoded payload generation keeps now-playing title")
            #expect(
                (await waitUntil { payloadStore.queueMutation?.engineEpoch == payloadGeneration }) == true,
                "decoded payload generation stamps the mutation snapshot")
            #expect(
                (payloadStore.queueMutation?.engineEpoch == mirroredGeneration) == (false),
                "decoded payload generation does not stamp the pre-await mirror")
            await payloadStore.shutdownForTermination()

            let bumpedEngine = GatedQueueSnapshotEngine()
            let bumpedStore = playbackStore(
                outcomeEnvironment(local: bumpedEngine, remote: ImmediateMetadataRemote())
            )
            await bumpedStore.restore()
            seedReadyLocalPlayback(bumpedStore, uri: uri)
            let beforeBump = bumpedStore.engineGeneration
            bumpedStore.refreshQueueSnapshot()
            #expect((await waitUntil { bumpedEngine.hasStarted }) == true, "bumped-engine snapshot fetch starts")
            bumpEngine(bumpedStore)
            let liveGeneration = bumpedStore.engineGeneration
            #expect(
                (liveGeneration > beforeBump) == true, "playback adopted a newer engine epoch during the snapshot await"
            )
            bumpedEngine.release(
                queueSnapshot(
                    uri: uri,
                    revision: 4,
                    sessionGeneration: liveGeneration
                )
            )
            #expect(
                (await waitUntil { bumpedStore.state.engineEpoch == liveGeneration }) == true,
                "a snapshot decoded after a live engine bump still stamps the payload generation")
            #expect(
                (bumpedStore.state.engineEpoch) == (liveGeneration),
                "a live-generation snapshot keeps reducer epoch aligned")
            #expect(
                (await waitUntil { bumpedStore.queueMutation?.engineEpoch == liveGeneration }) == true,
                "a live-generation snapshot stamps mutation with the payload, not the pre-await mirror")
            await bumpedStore.shutdownForTermination()

            let stalePayloadEngine = GatedQueueSnapshotEngine()
            let stalePayload = playbackStore(
                outcomeEnvironment(local: stalePayloadEngine, remote: ImmediateMetadataRemote())
            )
            seedReadyLocalPlayback(stalePayload, uri: uri)
            let staleBefore = stalePayload.engineGeneration
            stalePayload.refreshQueueSnapshot()
            #expect((await waitUntil { stalePayloadEngine.hasStarted }) == true, "stale-payload snapshot fetch starts")
            let stalePayloadSnapshot = stalePayload.effects.settlement(of: .queueSnapshot)
            bumpEngine(stalePayload)
            stalePayloadEngine.release(
                queueSnapshot(
                    uri: uri,
                    revision: 5,
                    sessionGeneration: staleBefore
                )
            )
            await awaitCapturedEffect(
                stalePayloadSnapshot,
                registered: "stale payload snapshot effect is registered before invalidation"
            )
            #expect(
                (stalePayload.state.currentTrack?.title) == ("Now"),
                "a stale payload generation cannot replace now-playing title")
            #expect((stalePayload.queueMutation) == nil, "a stale payload generation does not install mutation")
            await stalePayload.shutdownForTermination()
        }

        do {
            let mac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)
            let phone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)
            let activePhone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
            let pausedURI = "spotify:track:paused-remote"
            let expectedPhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)

            @MainActor
            func seedIdentity(_ player: PlaybackStore) {
                _ = player.send(.session(.ready), source: .account)
                _ = player.send(
                    .engineConnection(
                        EngineConnectionSnapshot(
                            session: .ready,
                            owner: .none,
                            localDeviceID: "mac"
                        )),
                    source: .engineConnection,
                    revision: 1,
                    engineEpoch: 1
                )
            }

            let launchPreferences = RecordingOwnerPreferences()
            await launchPreferences.seed("phone")
            let launch = playbackStore(
                outcomeEnvironment(remote: ImmediateMetadataRemote(), preferences: launchPreferences)
            )
            seedIdentity(launch)
            launch.lastRemoteDeviceID = "phone"
            launch.receive([mac, phone], revision: 1, engineEpoch: launch.engineGeneration)
            #expect((launch.state.owner) == (.none), "cluster devices-first with no track is none")
            #expect(
                (launch.state.devices.lastRemoteDeviceID) == ("phone"),
                "the store stamps last-remote context onto the snapshot")
            _ = launch.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: pausedURI,
                        timing: PlaybackTiming(position: 0, duration: 180)
                    )),
                source: .enginePlayback,
                revision: 1,
                engineEpoch: launch.engineGeneration
            )
            #expect(
                (launch.state.owner) == (.uncertain(expectedPhone)),
                "a later URI adopts the stamped last-remote candidate")
            #expect(
                (launch.commandRoute) == (.remote(from: "mac", to: "phone")), "devices-then-track stays remote-routable"
            )
            await launch.shutdownForTermination()

            let remotePreferences = RecordingOwnerPreferences()
            let remoteActive = playbackStore(
                outcomeEnvironment(remote: ImmediateMetadataRemote(), preferences: remotePreferences)
            )
            seedIdentity(remoteActive)
            remoteActive.receive([mac, activePhone], revision: 1, engineEpoch: remoteActive.engineGeneration)
            #expect(
                (remoteActive.state.owner)
                    == (.remote(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true))),
                "an active remote snapshot is remote ownership")
            #expect(
                (remoteActive.lastRemoteDeviceID) == ("phone"),
                "the store records last-remote after an accepted active remote")
            let preferenceWritten: Bool
            if remoteActive.lastRemoteDeviceID == "phone" {
                preferenceWritten = await waitUntil { await remotePreferences.lastRemoteDeviceID() == "phone" }
            } else {
                preferenceWritten = false
            }
            #expect((preferenceWritten) == true, "an accepted active remote writes the last-remote preference")
            await remoteActive.shutdownForTermination()

            let stale = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
            seedIdentity(stale)
            stale.lastRemoteDeviceID = "phone"
            stale.receive([mac, phone], revision: 4, engineEpoch: stale.engineGeneration)
            let afterDevices = stale.state
            stale.receive([mac, activePhone], revision: 3, engineEpoch: stale.engineGeneration)
            #expect((stale.state) == (afterDevices), "a stale device revision does not replace owner")
            stale.receive([mac, activePhone], revision: 5, engineEpoch: 0)
            #expect((stale.state) == (afterDevices), "a stale engine epoch does not replace owner")
            let rejected = stale.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                            PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true),
                        ],
                        localDeviceID: "mac",
                        revision: 5,
                        lastRemoteDeviceID: "phone"
                    )),
                source: .engineDevices,
                revision: 5,
                engineEpoch: stale.engineGeneration,
                accountEpoch: 0
            )
            #expect((!rejected) == true, "a stale account epoch is rejected")
            #expect((stale.state) == (afterDevices), "a stale account epoch does not replace owner")
            await stale.shutdownForTermination()

            let teardown = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
            seedIdentity(teardown)
            teardown.lastRemoteDeviceID = nil
            let beforeTeardown = teardown.state
            teardown.isTearingDown = true
            teardown.receive([mac, activePhone], revision: 1, engineEpoch: teardown.engineGeneration)
            #expect((teardown.state) == (beforeTeardown), "teardown device intake is inert")
            #expect(
                (teardown.lastRemoteDeviceID) == nil, "teardown does not record last-remote from a discarded snapshot")
            await teardown.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let receipt = Date(timeIntervalSince1970: 1_800_000_050)
            let player = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
            seedReadyLocalPlayback(player, uri: "spotify:track:clocked")

            _ = player.setTiming(position: 12)
            #expect(
                (player.state.timing.anchoredAt) == (clockNow), "setTiming without an anchor uses the injected clock")
            #expect((player.state.timing.position) == (12), "setTiming preserves the commanded position")

            _ = player.setTiming(position: 40, anchoredAt: receipt)
            #expect(
                (player.state.timing.anchoredAt) == (receipt),
                "an explicit timing anchor is not replaced by clock.now()")

            player.hasReceivedPlaybackSnapshot = true
            player.receive(
                RustPlaybackState(
                    revision: 2,
                    sessionGeneration: player.engineGeneration,
                    isPlaying: true,
                    isPaused: false,
                    trackURI: "spotify:track:clocked",
                    positionMS: 40_000,
                    durationMS: 200_000,
                    timestampMS: 0,
                    shuffle: false,
                    repeatTrack: false,
                    repeatContext: false
                ),
                revision: 2,
                receivedAt: receipt
            )
            #expect(
                (player.state.timing.anchoredAt) == (receipt),
                "engine intake anchors from receipt time, not the later orchestration clock")
            #expect(
                (player.state.sourceRevisions[.enginePlayback]) == (2),
                "engine playback records the backend revision, not receipt time")
            #expect(
                (player.displayedPosition(at: receipt.addingTimeInterval(0.25))) == (40.25),
                "playing snapshots still interpolate from receipt time")

            player.recordPlayed("spotify:track:clocked")
            #expect(
                (player.history.entries.first?.playedAt) == (clockNow),
                "played history uses the injected orchestration clock")
            #expect(
                (player.shuffleHistoryCache["spotify:track:clocked"]) == (clockNow.timeIntervalSince1970),
                "shuffle history uses the same orchestration clock instant")
            await player.shutdownForTermination()
        }
    }

    @Test
    @MainActor
    func testPlaybackActiveRoleIsIndependentOfConnectionCallbackOrder() async {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let connection = RustConnectionState(
            revision: 1,
            sessionGeneration: 0,
            sessionConnected: true,
            spircReady: true,
            isActiveDevice: true,
            resumePending: false,
            lastError: nil,
            deviceID: "mac"
        )
        let playback = RustPlaybackState(
            revision: 2,
            sessionGeneration: 0,
            isPlaying: true,
            isPaused: false,
            trackURI: "spotify:track:order-independent",
            positionMS: 1_000,
            durationMS: 180_000,
            timestampMS: 0,
            shuffle: false,
            repeatTrack: false,
            repeatContext: false,
            isActiveDevice: true
        )

        let connectionFirst = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        connectionFirst.receive(connection, revision: 1, receivedAt: receivedAt)
        connectionFirst.receive(playback, revision: 2, receivedAt: receivedAt)

        let playbackFirst = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        playbackFirst.receive(playback, revision: 2, receivedAt: receivedAt)
        playbackFirst.receive(connection, revision: 1, receivedAt: receivedAt)

        #expect(
            connectionFirst.state.transport == playbackFirst.state.transport,
            "same active playback observation projects the same transport in either callback order"
        )
        #expect(
            connectionFirst.state.transport == .paused,
            "the initial local observation remains conservatively paused"
        )
        #expect(
            connectionFirst.state.currentTrack?.uri == playbackFirst.state.currentTrack?.uri,
            "same playback observation projects the same track identity in either callback order"
        )

        await connectionFirst.shutdownForTermination()
        await playbackFirst.shutdownForTermination()
    }

    @Test
    @MainActor
    func testPositionRefreshCannotCrossTrackTransition() async {
        let engine = GatedPositionEngine()
        let player = playbackStore(
            outcomeEnvironment(local: engine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(player, uri: "spotify:track:old")

        player.refreshPosition()
        #expect((await waitUntil { engine.hasStarted }) == true, "position refresh starts")
        let positionRefresh = player.effects.settlement(of: .positionRefresh)

        #expect(
            (player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(uri: "spotify:track:new"),
                        transport: player.state.transport,
                        timing: player.state.timing
                    )),
                source: .user
            )) == true,
            "the new track is accepted while the getter is suspended"
        )
        #expect((player.state.currentTrack?.uri) == ("spotify:track:new"), "the new track is current")
        #expect((player.state.timing.position) == (5), "the track transition keeps its existing timing")

        engine.release()
        await awaitCapturedEffect(
            positionRefresh,
            registered: "track-scoped position refresh is registered before completion"
        )
        #expect(
            (player.state.timing.position) == (5),
            "a position sampled for the old track cannot overwrite the new track"
        )
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func testPlaybackUnavailableIntakeSurfacesOnlyAcceptedLocalFailures() async {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let localURI = "spotify:track:boundary-unavailable"
        let local = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedReadyLocalPlayback(local, uri: localURI)

        local.receive(
            RustPlaybackState(
                revision: 11,
                sessionGeneration: local.engineGeneration,
                isPlaying: false,
                isPaused: true,
                trackURI: localURI,
                positionMS: 0,
                durationMS: 180_000,
                timestampMS: 0,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false,
                trackUnavailable: true,
                isActiveDevice: true
            ),
            revision: 11,
            receivedAt: receivedAt
        )
        #expect(
            (local.playbackNotice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "an accepted local engine failure reaches the store notice"
        )
        let noticeID = local.playbackNotice?.id
        local.dismissPlaybackNotice(id: UUID())
        #expect((local.playbackNotice?.id) == (noticeID), "dismissal ignores an unrelated notice identity")
        if let noticeID {
            local.dismissPlaybackNotice(id: noticeID)
        }
        #expect((local.playbackNotice) == nil, "the matching notice identity can be dismissed")

        let remote = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedReadyLocalPlayback(remote, uri: "spotify:track:remote-unavailable")
        _ = remote.send(
            .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
            source: .engineConnection
        )
        remote.receive(
            RustPlaybackState(
                revision: 1,
                sessionGeneration: remote.engineGeneration,
                isPlaying: false,
                isPaused: true,
                trackURI: "spotify:track:remote-unavailable",
                positionMS: 0,
                durationMS: 180_000,
                timestampMS: 0,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false,
                trackUnavailable: true,
                isActiveDevice: false
            ),
            revision: 1,
            receivedAt: receivedAt
        )
        #expect((remote.playbackNotice) == nil, "a remote engine sample cannot create a notice")

        let empty = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedReadyLocalPlayback(empty, uri: "spotify:track:empty-unavailable")
        empty.receive(
            RustPlaybackState(
                revision: 1,
                sessionGeneration: empty.engineGeneration,
                isPlaying: false,
                isPaused: true,
                trackURI: "",
                positionMS: 0,
                durationMS: 0,
                timestampMS: 0,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false,
                trackUnavailable: true,
                isActiveDevice: true
            ),
            revision: 1,
            receivedAt: receivedAt
        )
        #expect((empty.playbackNotice) == nil, "an empty URI cannot create a notice")

        await local.shutdownForTermination()
        await remote.shutdownForTermination()
        await empty.shutdownForTermination()
    }
}

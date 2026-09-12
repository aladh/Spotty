import Testing
import SpottyDomain
import Foundation
import Observation
@testable import SpottyCore
import SpottyRuntimeContracts
@testable import SpottyEngineAdapter
@testable import SpottySessionRuntime

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

@MainActor
private final class RecordingSystemMediaOutput: SystemMediaControlsOutput {
    var handler: (@MainActor @Sendable (SystemMediaCommand) -> Bool)?
    var snapshot: SystemMediaSnapshot?
    var installations = 0
    var removals = 0
    func install(_ handler: @escaping @MainActor @Sendable (SystemMediaCommand) -> Bool) {
        self.handler = handler
        installations += 1
    }
    func update(_ snapshot: SystemMediaSnapshot?) { self.snapshot = snapshot }
    func remove() { removals += 1; snapshot = nil }
}

/// Kept as a bespoke fake: it maps commands to simplified strings and tracks `to` destinations
/// separately, which `HarnessRemote`'s `commands`/`endpoints` observation does not expose.
private actor MediaKeyRemote: RemotePlaybackClient {
    private(set) var destinations: [String] = []
    private(set) var commands: [String] = []
    func send(_ command: SpotifyConnectCommand, from _: String, to: String) async throws {
        destinations.append(to)
        switch command.endpoint {
        case .pause: commands.append("pause")
        case .resume: commands.append("resume")
        case .next: commands.append("next")
        case .previous: commands.append("previous")
        default: commands.append("unexpected")
        }
    }
    func trackMetadata(for _: String) async throws -> SpotifyConnectTrackMetadata {
        throw URLError(.badServerResponse)
    }
}

@Suite("Playback Event Outcome")
struct PlaybackEventOutcomeTests {
    @Test
    @MainActor
    func systemMediaKeysFollowRemoteOwnerAndStopWithLifetime() async {
        let remote = MediaKeyRemote()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: remote))
        let output = RecordingSystemMediaOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        controls.start()
        #expect(output.installations == 1)
        #expect(output.snapshot == nil)
        #expect(output.handler?(.toggle) == false)
        seedReadyLocalPlayback(player, uri: "spotify:track:media-key")
        _ = player.send(
            .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
            source: .engineConnection)
        #expect(await waitUntil { output.snapshot?.title == "Now" })
        #expect(output.snapshot?.playing == true)
        // Explicit play is idempotent and never toggles already-playing audio off.
        #expect(output.handler?(.play) == true)
        #expect(await remote.commands.isEmpty)
        #expect(output.handler?(.pause) == true)
        #expect(await waitUntil { await remote.commands.count == 1 })
        #expect(await remote.destinations == ["speaker"])
        #expect(await remote.commands == ["pause"])
        #expect(await waitUntil { player.canTogglePlayback })
        #expect(output.handler?(.next) == true)
        #expect(await waitUntil { await remote.commands.count == 2 })
        #expect(await remote.commands == ["pause", "next"])
        #expect(await waitUntil { player.canSkipTrack })
        #expect(output.handler?(.previous) == true)
        #expect(await waitUntil { await remote.commands.count == 3 })
        #expect(await remote.destinations == ["speaker", "speaker", "speaker"])
        _ = player.send(.session(.signedOut), source: .account)
        #expect(output.handler?(.toggle) == false)
        #expect(await waitUntil { output.snapshot == nil })
        controls.stop()
        controls.stop()
        #expect(output.removals == 1)
        seedReadyLocalPlayback(player, uri: "spotify:track:after-stop")
        #expect(output.handler?(.next) == false)
        #expect(output.snapshot == nil)
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func testSidebarPlaylistFollowsLocalAndRemoteContext() async {
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        seedReadyLocalPlayback(player, uri: "spotify:track:indicator")
        player.hasReceivedPlaybackSnapshot = true
        let access = CatalogPlaybackAccess(player: player)
        func observe(_ context: String?, playing: Bool, local: Bool, revision: UInt64) {
            player.receive(
                RustPlaybackState(
                    revision: revision, sessionGeneration: player.engineGeneration,
                    isPlaying: playing, isPaused: !playing,
                    trackURI: "spotify:track:indicator", positionMS: 1000, durationMS: 200000,
                    timestampMS: 0, shuffle: false, repeatTrack: false, repeatContext: false,
                    isActiveDevice: local, contextURI: context),
                revision: revision, receivedAt: Date())
        }
        observe("spotify:playlist:first", playing: true, local: true, revision: 1)
        #expect(access.isPlayingPlaylist("spotify:playlist:first"))
        #expect(!access.isPlayingPlaylist("spotify:playlist:other"))
        let invalidations = ObservationCounter()
        withObservationTracking {
            _ = access.isPlayingPlaylist("spotify:playlist:first")
        } onChange: {
            invalidations.increment()
        }
        _ = player.setTiming(position: 42)
        #expect(invalidations.count == 0)
        observe("spotify:playlist:remote", playing: true, local: false, revision: 2)
        #expect(access.isPlayingPlaylist("spotify:playlist:remote"))
        #expect(!access.isPlayingPlaylist("spotify:playlist:first"))
        observe("spotify:playlist:remote", playing: false, local: false, revision: 3)
        #expect(!access.isPlayingPlaylist("spotify:playlist:remote"))
        observe("spotify:playlist:remote", playing: true, local: false, revision: 4)
        // Local transport samples omit context; absence preserves the accepted context.
        observe(nil, playing: true, local: true, revision: 5)
        #expect(access.isPlayingPlaylist("spotify:playlist:remote"))
        // A full protocol snapshot uses an empty string to explicitly clear context.
        observe("", playing: true, local: true, revision: 6)
        #expect(player.playingContextURI == nil)
        #expect(!access.isPlayingPlaylist("spotify:playlist:remote"))
        observe("spotify:playlist:remote", playing: true, local: false, revision: 7)
        _ = player.send(.session(.signedOut), source: .account)
        #expect(!access.isPlayingPlaylist("spotify:playlist:remote"))
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func timingTicksLeaveSemanticDeviceAndQueueObserversAsleep() async {
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        seedReadyLocalPlayback(player, uri: "spotify:track:projection")
        let semanticChanges = ObservationCounter()
        let timingChanges = ObservationCounter()
        withObservationTracking {
            _ = player.displayedTrackTitle
            _ = player.isPlaying
            _ = player.canTogglePlayback
            _ = player.connectDevices
            _ = player.activeRemoteDevice
            _ = player.queueNextEntries
            _ = player.duration
        } onChange: {
            semanticChanges.increment()
        }
        withObservationTracking {
            _ = player.position
            _ = player.positionAnchorDate
        } onChange: {
            timingChanges.increment()
        }
        for position in 1...100 { #expect(player.setTiming(position: Double(position))) }
        #expect(semanticChanges.count == 0)
        #expect(timingChanges.count == 1)
        #expect(player.position == 100)
        _ = player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: player.state.currentTrack, transport: .paused, timing: player.state.timing)),
            source: .user)
        #expect(semanticChanges.count == 1)
        #expect(!player.isPlaying)
        await player.shutdownForTermination()
    }

    @Test
    func systemMediaPublicationBoundsOrdinaryTimingButImmediatelyPublishesDiscontinuities() {
        var gate = SystemMediaPublicationGate()
        let start = Date(timeIntervalSince1970: 100)
        func snapshot(_ position: Double, playing: Bool = true) -> SystemMediaSnapshot {
            SystemMediaSnapshot(
                title: "Track", artist: "Artist", duration: 180,
                position: position, playing: playing, canToggle: true, canSkip: true)
        }
        let admitted1 = gate.admit(snapshot(0), at: start)
        #expect(admitted1)
        for tick in 1...4 {
            let time = Double(tick) / 5
            let admitted2 = gate.admit(snapshot(time), at: start.addingTimeInterval(time))
            #expect(!admitted2)
        }
        let admitted3 = gate.admit(snapshot(1), at: start.addingTimeInterval(1))
        #expect(admitted3)
        let admitted4 = gate.admit(snapshot(40), at: start.addingTimeInterval(1.2))
        #expect(admitted4)
        let admitted5 = gate.admit(snapshot(40, playing: false), at: start.addingTimeInterval(1.3))
        #expect(admitted5)
        let admitted6 = gate.admit(snapshot(40.1, playing: false), at: start.addingTimeInterval(1.4), force: true)
        #expect(admitted6)
        let admitted7 = gate.admit(nil, at: start.addingTimeInterval(1.5))
        #expect(admitted7)
        var unknownDuration = SystemMediaPublicationGate()
        for tick in 0...5 {
            let time = Double(tick) / 5
            let admitted = unknownDuration.admit(
                SystemMediaSnapshot(
                    title: "Track", artist: "Artist", duration: 0, position: 12 + time,
                    playing: true, canToggle: true, canSkip: true), at: start.addingTimeInterval(time))
            #expect(admitted == (tick == 0 || tick == 5))
        }
    }

    @Test
    @MainActor
    func testCatalogPlaybackObservationSkipsTimingTicks() async {
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
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
            let successRemote = HarnessRemote(metadata: .park)
            let success = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: successRemote))
            startTrackResolution(success, uri: "spotify:track:success")
            #expect(
                (await waitUntil { successRemote.requestedURI == "spotify:track:success" }) == true,
                "metadata lookup starts")
            success.recordPlayed("spotify:track:success")
            let successfulMetadata = success.effects.settlement(of: .trackMetadata)
            successRemote.completeMetadata(title: "Resolved")
            await awaitCapturedEffect(
                successfulMetadata,
                registered: "successful metadata effect is captured before its result is released"
            )
            #expect(
                (await waitUntil { success.state.currentTrack?.title == "Resolved" }) == true,
                "accepted metadata updates the current track")
            #expect(
                (success.state.currentTrack?.metadataSource) == (.connect), "accepted metadata uses connect provenance")
            #expect(
                (success.history.entries.first?.title) == ("Resolved"),
                "history enrichment waits for reducer acceptance")
            await success.shutdownForTermination()

            let staleEngineRemote = HarnessRemote(metadata: .park)
            let staleEngine = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: staleEngineRemote))
            startTrackResolution(staleEngine, uri: "spotify:track:stale-engine")
            #expect(
                (await waitUntil { staleEngineRemote.requestedURI != nil }) == true,
                "stale-engine metadata lookup starts")
            let staleEngineMetadata = staleEngine.effects.settlement(of: .trackMetadata)
            bumpEngine(staleEngine)
            staleEngineRemote.completeMetadata(title: "Late engine")
            await awaitCapturedEffect(
                staleEngineMetadata,
                registered: "stale-engine metadata effect is registered before invalidation"
            )
            #expect(
                (staleEngine.state.currentTrack?.title) == nil,
                "stale-engine metadata does not mutate the current title")
            #expect((staleEngine.history.entries.isEmpty) == true, "stale-engine metadata does not create history")
            await staleEngine.shutdownForTermination()

            let staleAccountRemote = HarnessRemote(metadata: .park)
            let staleAccount = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: staleAccountRemote))
            startTrackResolution(staleAccount, uri: "spotify:track:stale-account")
            #expect(
                (await waitUntil { staleAccountRemote.requestedURI != nil }) == true,
                "stale-account metadata lookup starts")
            staleAccount.recordPlayed("spotify:track:stale-account")
            let staleAccountMetadata = staleAccount.effects.settlement(of: .trackMetadata)
            staleAccount.accountStore.advanceEpoch()
            _ = staleAccount.send(
                .reset(session: .signedOut),
                source: .account,
                accountEpoch: staleAccount.accountEpoch
            )
            staleAccountRemote.completeMetadata(title: "Late account")
            await awaitCapturedEffect(
                staleAccountMetadata,
                registered: "stale-account metadata effect is registered before invalidation"
            )
            #expect((staleAccount.state.currentTrack) == nil, "stale-account metadata cannot revive a reset track")
            #expect(
                (staleAccount.history.entries.first?.title) == ("Unknown track"),
                "stale-account metadata does not enrich history after reset")
            await staleAccount.shutdownForTermination()

            let cancelRemote = HarnessRemote(metadata: .park)
            let cancelled = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: cancelRemote))
            startTrackResolution(cancelled, uri: "spotify:track:cancelled")
            #expect(
                (await waitUntil { cancelRemote.requestedURI != nil }) == true, "cancelled metadata lookup starts"
            )
            cancelled.recordPlayed("spotify:track:cancelled")
            let cancelledMetadata = cancelled.effects.settlement(of: .trackMetadata)
            cancelled.effects.cancel(.trackMetadata)
            cancelRemote.completeMetadata(title: "Cancelled")
            await awaitCapturedEffect(
                cancelledMetadata,
                registered: "cancelled metadata effect is registered before cancellation"
            )
            #expect((cancelled.state.currentTrack?.title) == nil, "cancelled metadata is inert")
            #expect(
                (cancelled.history.entries.first?.title) == ("Unknown track"),
                "cancelled metadata does not enrich history")
            await cancelled.shutdownForTermination()

            let rejectedRemote = HarnessRemote(metadata: .park)
            let rejected = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: rejectedRemote))
            startTrackResolution(rejected, uri: "spotify:track:original")
            #expect(
                (await waitUntil { rejectedRemote.requestedURI == "spotify:track:original" }) == true,
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
            rejectedRemote.completeMetadata(title: "From original")
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
            let successEngine = HarnessEngine()
            let successGate = HarnessEngineGate()
            successEngine.onPositionMilliseconds = { [successGate] in
                successGate.wait(); return 42_000
            }
            let success = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: successEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(success, uri: "spotify:track:playing")
            success.refreshPosition()
            #expect((await waitUntil { successGate.hasStarted }) == true, "position refresh starts")
            successGate.release()
            #expect(
                (await waitUntil { success.state.timing.position == 42 }) == true,
                "accepted timing replaces the anchored position")
            await success.shutdownForTermination()

            let staleAccountEngine = HarnessEngine()
            let staleAccountGate = HarnessEngineGate()
            staleAccountEngine.onPositionMilliseconds = { [staleAccountGate] in
                staleAccountGate.wait(); return 42_000
            }
            let staleAccount = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: staleAccountEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(staleAccount, uri: "spotify:track:playing")
            staleAccount.refreshPosition()
            #expect(
                (await waitUntil { staleAccountGate.hasStarted }) == true, "stale-account position refresh starts")
            let staleAccountPosition = staleAccount.effects.settlement(of: .positionRefresh)
            staleAccount.accountStore.advanceEpoch()
            _ = staleAccount.send(
                .reset(session: .signedOut),
                source: .account,
                accountEpoch: staleAccount.accountEpoch
            )
            staleAccountGate.release()
            await awaitCapturedEffect(
                staleAccountPosition,
                registered: "stale-account position refresh is registered before invalidation"
            )
            #expect(
                (staleAccount.state.timing.position) == (0),
                "stale-account position refresh cannot stamp signed-out timing"
            )
            await staleAccount.shutdownForTermination()

            let staleEngineEngine = HarnessEngine()
            let staleEngineGate = HarnessEngineGate()
            staleEngineEngine.onPositionMilliseconds = { [staleEngineGate] in
                staleEngineGate.wait(); return 42_000
            }
            let staleEngine = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: staleEngineEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(staleEngine, uri: "spotify:track:playing")
            staleEngine.refreshPosition()
            #expect((await waitUntil { staleEngineGate.hasStarted }) == true, "stale-engine position refresh starts")
            let staleEnginePosition = staleEngine.effects.settlement(of: .positionRefresh)
            bumpEngine(staleEngine)
            staleEngineGate.release()
            await awaitCapturedEffect(
                staleEnginePosition,
                registered: "stale-engine position refresh is registered before invalidation"
            )
            #expect((staleEngine.state.timing.position) == (5), "stale-engine position refresh is inert")
            await staleEngine.shutdownForTermination()

            let cancelEngine = HarnessEngine()
            let cancelGate = HarnessEngineGate()
            cancelEngine.onPositionMilliseconds = { [cancelGate] in
                cancelGate.wait(); return 42_000
            }
            let cancelled = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: cancelEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(cancelled, uri: "spotify:track:playing")
            cancelled.refreshPosition()
            #expect((await waitUntil { cancelGate.hasStarted }) == true, "cancelled position refresh starts")
            let cancelledPosition = cancelled.effects.settlement(of: .positionRefresh)
            cancelled.effects.cancel(.positionRefresh)
            cancelGate.release()
            await awaitCapturedEffect(
                cancelledPosition,
                registered: "cancelled position refresh is registered before cancellation"
            )
            #expect((cancelled.state.timing.position) == (5), "cancelled position refresh is inert")
            await cancelled.shutdownForTermination()
        }

        do {
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            _ = player.send(.session(.ready), source: .account)
            player.withRuntime { $0.accountStore.publishPhase(.ready) }

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

            let webQueue = HarnessWebQueue(.park)
            let cancelled = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"), webQueue: webQueue)
            )
            await cancelled.restore()
            _ = cancelled.send(.session(.ready), source: .account)
            cancelled.withRuntime { $0.accountStore.publishPhase(.ready) }
            cancelled.refreshQueue()
            #expect((await waitUntil { webQueue.requestCount == 1 }) == true, "queue refresh starts")
            let cancelledQueueRefresh = cancelled.effects.settlement(of: .queueRefresh)
            cancelled.cancelQueueRefresh()
            webQueue.complete(with: [fixtureTrack("spotify:track:cancelled-queue", title: "Cancelled")])
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
            let namedEngine = HarnessEngine()
            let namedGate = HarnessEngineGate()
            namedEngine.onQueueSnapshot = { [namedGate, namedEngine] in
                namedGate.wait(); return namedEngine.snapshot
            }
            let namedRemote = HarnessRemote(metadata: .park)
            let named = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: namedEngine, remote: namedRemote)
            )
            let uri = "spotify:track:same"
            seedReadyLocalPlayback(named, uri: uri)
            named.recordPlayed(uri)
            named.refreshQueueSnapshot()
            #expect((await waitUntil { namedGate.hasStarted }) == true, "named queue snapshot fetch starts")
            let namedSnapshot = named.effects.settlement(of: .queueSnapshot)
            let staleNamedGeneration = named.engineGeneration
            bumpEngine(named)
            namedEngine.snapshot = queueSnapshot(uri: uri, sessionGeneration: staleNamedGeneration)
            namedGate.release()
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
            #expect((namedRemote.requestedURI) == nil, "stale named snapshot does not start metadata resolution")
            await named.shutdownForTermination()

            let missingEngine = HarnessEngine()
            let missingGate = HarnessEngineGate()
            missingEngine.onQueueSnapshot = { [missingGate, missingEngine] in
                missingGate.wait()
                return missingEngine.snapshot
            }
            let missingRemote = HarnessRemote(metadata: .park)
            let missing = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: missingEngine, remote: missingRemote)
            )
            seedReadyLocalPlayback(missing, uri: uri, title: nil, metadataSource: .none)
            missing.recordPlayed(uri)
            missing.refreshQueueSnapshot()
            #expect((await waitUntil { missingGate.hasStarted }) == true, "nameless queue snapshot fetch starts")
            let missingSnapshot = missing.effects.settlement(of: .queueSnapshot)
            let staleMissingGeneration = missing.engineGeneration
            bumpEngine(missing)
            missingEngine.snapshot = queueSnapshot(uri: uri, sessionGeneration: staleMissingGeneration)
            missingGate.release()
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
                (missingRemote.requestedURI) == nil, "stale nameless snapshot does not launch a metadata resolver"
            )
            await missing.shutdownForTermination()

            let watermarkEngine = HarnessEngine()
            let watermarkGate = HarnessEngineGate()
            watermarkEngine.onQueueSnapshot = { [watermarkGate, watermarkEngine] in
                watermarkGate.wait()
                return watermarkEngine.snapshot
            }
            let watermarkStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: watermarkEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(watermarkStore, uri: uri)
            let before = watermarkStore.connectQueueCallback
            watermarkStore.refreshQueueSnapshot()
            #expect((await waitUntil { watermarkGate.hasStarted }) == true, "watermark snapshot fetch starts")
            let watermarkSnapshot = watermarkStore.effects.settlement(of: .queueSnapshot)
            let staleWatermarkGeneration = watermarkStore.engineGeneration
            bumpEngine(watermarkStore)
            watermarkEngine.snapshot = queueSnapshot(uri: uri, revision: 9, sessionGeneration: staleWatermarkGeneration)
            watermarkGate.release()
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

            let payloadEngine = HarnessEngine()
            let payloadGate = HarnessEngineGate()
            payloadEngine.onQueueSnapshot = { [payloadGate, payloadEngine] in
                payloadGate.wait()
                return payloadEngine.snapshot
            }
            let payloadStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: payloadEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            await payloadStore.restore()
            seedReadyLocalPlayback(payloadStore, uri: uri)
            let mirroredGeneration = payloadStore.engineGeneration
            let payloadGeneration = mirroredGeneration + 1
            payloadStore.refreshQueueSnapshot()
            #expect((await waitUntil { payloadGate.hasStarted }) == true, "payload-generation snapshot fetch starts")
            let payloadSnapshot = payloadStore.effects.settlement(of: .queueSnapshot)
            payloadEngine.snapshot = queueSnapshot(
                uri: uri,
                revision: 3,
                sessionGeneration: payloadGeneration
            )
            payloadGate.release()
            await awaitCapturedEffect(
                payloadSnapshot,
                registered: "payload-generation snapshot effect is captured before its result is released"
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

            let bumpedEngine = HarnessEngine()
            let bumpedGate = HarnessEngineGate()
            bumpedEngine.onQueueSnapshot = { [bumpedGate, bumpedEngine] in
                bumpedGate.wait()
                return bumpedEngine.snapshot
            }
            let bumpedStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: bumpedEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            await bumpedStore.restore()
            seedReadyLocalPlayback(bumpedStore, uri: uri)
            let beforeBump = bumpedStore.engineGeneration
            bumpedStore.refreshQueueSnapshot()
            #expect((await waitUntil { bumpedGate.hasStarted }) == true, "bumped-engine snapshot fetch starts")
            bumpEngine(bumpedStore)
            let liveGeneration = bumpedStore.engineGeneration
            #expect(
                (liveGeneration > beforeBump) == true, "playback adopted a newer engine epoch during the snapshot await"
            )
            bumpedEngine.snapshot = queueSnapshot(
                uri: uri,
                revision: 4,
                sessionGeneration: liveGeneration
            )
            bumpedGate.release()
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

            let stalePayloadEngine = HarnessEngine()
            let stalePayloadGate = HarnessEngineGate()
            stalePayloadEngine.onQueueSnapshot = { [stalePayloadGate, stalePayloadEngine] in
                stalePayloadGate.wait()
                return stalePayloadEngine.snapshot
            }
            let stalePayload = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: stalePayloadEngine, remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedReadyLocalPlayback(stalePayload, uri: uri)
            let staleBefore = stalePayload.engineGeneration
            stalePayload.refreshQueueSnapshot()
            #expect((await waitUntil { stalePayloadGate.hasStarted }) == true, "stale-payload snapshot fetch starts")
            let stalePayloadSnapshot = stalePayload.effects.settlement(of: .queueSnapshot)
            bumpEngine(stalePayload)
            stalePayloadEngine.snapshot = queueSnapshot(
                uri: uri,
                revision: 5,
                sessionGeneration: staleBefore
            )
            stalePayloadGate.release()
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

            let launchPreferences = HarnessPreferences()
            launchPreferences.seed(lastRemoteDeviceID: "phone")
            let launch = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(
                    remote: HarnessRemote(metadataTitle: "Resolved"),
                    preferences: launchPreferences
                )
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

            let remotePreferences = HarnessPreferences()
            let remoteActive = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(
                    remote: HarnessRemote(metadataTitle: "Resolved"),
                    preferences: remotePreferences
                )
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
                preferenceWritten = await waitUntil { remotePreferences.storedRemoteDeviceID == "phone" }
            } else {
                preferenceWritten = false
            }
            #expect((preferenceWritten) == true, "an accepted active remote writes the last-remote preference")
            await remoteActive.shutdownForTermination()

            let stale = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
            )
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

            let teardown = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
            )
            seedIdentity(teardown)
            teardown.lastRemoteDeviceID = nil
            let beforeTeardown = teardown.state
            teardown.withRuntime { $0.isTearingDown = true }
            teardown.receive([mac, activePhone], revision: 1, engineEpoch: teardown.engineGeneration)
            #expect((teardown.state) == (beforeTeardown), "teardown device intake is inert")
            #expect(
                (teardown.lastRemoteDeviceID) == nil, "teardown does not record last-remote from a discarded snapshot")
            await teardown.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let receipt = Date(timeIntervalSince1970: 1_800_000_050)
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
            )
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

        let connectionFirst = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        connectionFirst.receive(connection, revision: 1, receivedAt: receivedAt)
        connectionFirst.receive(playback, revision: 2, receivedAt: receivedAt)

        let playbackFirst = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
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
        let engine = HarnessEngine()
        let gate = HarnessEngineGate()
        engine.onPositionMilliseconds = { [gate] in
            gate.wait(); return 42_000
        }
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        seedReadyLocalPlayback(player, uri: "spotify:track:old")

        player.refreshPosition()
        #expect((await waitUntil { gate.hasStarted }) == true, "position refresh starts")
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

        gate.release()
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

    @Test(arguments: [false, true])
    @MainActor
    func testPlaybackUnavailableIntakeSurfacesOnlyAcceptedLocalFailures(audioKeyRefused: Bool) async {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let localURI = "spotify:track:boundary-unavailable"
        let local = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
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
                audioKeyRefused: audioKeyRefused,
                isActiveDevice: true
            ),
            revision: 11,
            receivedAt: receivedAt
        )
        #expect(
            (local.playbackNotice?.message)
                == (audioKeyRefused ? PlaybackNotice.audioKeyRefusedMessage : PlaybackNotice.trackUnavailableMessage),
            "an accepted local engine failure reaches the store notice"
        )
        let noticeID = local.playbackNotice?.id
        local.dismissPlaybackNotice(id: UUID())
        #expect((local.playbackNotice?.id) == (noticeID), "dismissal ignores an unrelated notice identity")
        if let noticeID {
            local.dismissPlaybackNotice(id: noticeID)
        }
        #expect((local.playbackNotice) == nil, "the matching notice identity can be dismissed")

        let remote = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
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
                audioKeyRefused: audioKeyRefused,
                isActiveDevice: false
            ),
            revision: 1,
            receivedAt: receivedAt
        )
        #expect((remote.playbackNotice) == nil, "a remote engine sample cannot create a notice")

        let empty = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
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
                audioKeyRefused: audioKeyRefused,
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

@Suite("Coherent Connect intake")
struct CoherentConnectIntakeTests {
    @Test
    @MainActor
    func settledIntentRevokesOnlyItsUnclaimedPermit() async {
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        store.receive(cluster(revision: 1, activeID: "phone", trackURI: "spotify:track:a"), receivedAt: Date())
        let transportID = UUID()
        let optionsID = UUID()
        store.send(
            .commandStarted(
                PendingPlaybackCommand(id: transportID, kind: .transport, expectedTransport: nil, startedAt: Date())),
            source: .command
        )
        store.send(
            .commandStarted(
                PendingPlaybackCommand(id: optionsID, kind: .options, expectedTransport: nil, startedAt: Date())),
            source: .command
        )
        let transport = store.makePlaybackDispatchPermit(commandID: transportID, ifStillWanted: { true })
        let options = store.makePlaybackDispatchPermit(commandID: optionsID, ifStillWanted: { true })
        let queue = store.makePlaybackDispatchPermit(ifStillWanted: { true })
        store.send(.commandFinished(id: transportID, accepted: false, notice: nil), source: .command)
        #expect(transport?.claim() == false, "an intent settled before dispatch cannot send")
        #expect(
            store.makePlaybackDispatchPermit(commandID: transportID, ifStillWanted: { true }) == nil,
            "a settled intent cannot acquire a fresh permit")
        #expect(options?.claim() == true, "settling one intent preserves another kind's permit")
        #expect(queue?.claim() == true, "queue admission is independent of the transport pending slot")
        store.send(.commandFinished(id: optionsID, accepted: false, notice: nil), source: .command)
        let queuedAfterSettlement = store.makePlaybackDispatchPermit(ifStillWanted: { true })
        store.receive(cluster(revision: 2, activeID: "local", trackURI: "spotify:track:a"), receivedAt: Date())
        #expect(queuedAfterSettlement?.claim() == false, "handoff revokes queue work even without pending transport")
        await store.shutdownForTermination()
    }

    @Test
    @MainActor
    func initializationReturnDoesNotPublishCommandReadiness() async {
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        store.accountStore.onPhaseChange?(.connecting)
        store.accountStore.onPhaseChange?(.ready)
        #expect(store.phase == .connecting)
        #expect(!store.canStartPlayback)

        store.receive(
            RustConnectionState(
                revision: 1, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                isActiveDevice: false, resumePending: false, lastError: nil, deviceID: nil
            ),
            revision: 1,
            receivedAt: Date()
        )
        #expect(store.phase == .connecting)
        #expect(!store.canStartPlayback)
        store.receive(cluster(revision: 2, activeID: "", trackURI: ""), receivedAt: Date())
        #expect(store.phase == .ready)
        #expect(store.canStartPlayback)
        #expect(store.defaultLocalPlaybackDevice?.id == "local")
        await store.shutdownForTermination()
    }

    @Test
    @MainActor
    func aggregateOwnerAndQueueIdentityStayCoherent() async {
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        let observation = cluster(revision: 1, activeID: "phone", trackURI: "spotify:track:new")
        store.receive(observation, receivedAt: Date())
        #expect(store.trackURI == "spotify:track:new")
        #expect(store.commandRoute == .remote(from: "local", to: "phone"))
        #expect(store.state.devices.devices.first(where: \.isActive)?.id == "phone")
        let (accepted, afterDuplicate) = store.withRuntime { runtime in
            // Compare the two authoritative states in one intake turn. Unrelated metadata
            // enrichment may legitimately arrive between separate desktop mailbox entrances.
            let accepted = runtime.state
            runtime.receive(
                cluster(revision: 1, activeID: "local", trackURI: "spotify:track:old"), receivedAt: Date())
            return (accepted, runtime.state)
        }
        #expect(afterDuplicate == accepted)
        await store.shutdownForTermination()
    }

    @Test
    @MainActor
    func staleAggregateDevicesDoNotPersistRemoteIdentity() async {
        let preferences = HarnessPreferences()
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"), preferences: preferences)
        )
        store.receive(cluster(revision: 1, activeID: "phone", trackURI: "spotify:track:a"), receivedAt: Date())
        #expect(await waitUntil { preferences.storedRemoteDeviceID == "phone" })

        let acceptedDevices = store.state.devices
        store.receive(
            cluster(
                revision: 2,
                activeID: "tablet",
                trackURI: "spotify:track:b",
                devicesRevision: 0
            ),
            receivedAt: Date()
        )

        #expect(
            store.state.devices == acceptedDevices,
            "a stale devices component does not replace the accepted device snapshot"
        )
        #expect(store.lastRemoteDeviceID == "phone", "the rejected component cannot change the saved route")
        #expect(
            preferences.storedRemoteDeviceID == "phone",
            "a stale aggregate devices component does not persist its remote identity"
        )
        await store.shutdownForTermination()
    }

    @Test
    @MainActor
    func pressureGapReconstructsTruthWithoutRestartingEngine() async {
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        let authoritative = cluster(revision: 1, activeID: "phone", trackURI: "spotify:track:a")
        store.receive(authoritative, receivedAt: Date())
        store.send(
            .commandStarted(
                PendingPlaybackCommand(
                    id: UUID(), kind: .transport, expectedTransport: .playing,
                    expectedTrack: CurrentTrack(uri: "spotify:track:optimistic"), startedAt: Date()
                )
            ),
            source: .command
        )
        store.receive(
            RustPlaybackEventEnvelope(
                sequence: 2,
                receivedAt: Date(),
                event: .resynchronizationRequired(
                    sessionGeneration: 1,
                    snapshots: [
                        RustPlaybackEventEnvelope(sequence: 1, receivedAt: Date(), event: .cluster(authoritative))
                    ]
                )
            )
        )
        #expect(store.phase == .ready)
        #expect(store.state.pendingCommands.isEmpty)
        #expect(store.engineGeneration == 1)
        #expect(store.trackURI == "spotify:track:a")
        #expect(store.commandRoute == .remote(from: "local", to: "phone"))
        store.receive(cluster(revision: 1, activeID: "local", trackURI: "spotify:track:old"), receivedAt: Date())
        #expect(store.trackURI == "spotify:track:a")
        await store.shutdownForTermination()
    }

    private func cluster(
        revision: UInt64,
        activeID: String,
        trackURI: String,
        devicesRevision: UInt64? = nil
    ) -> RustConnectClusterState {
        RustConnectClusterState(
            revision: revision,
            sessionGeneration: 1,
            source: 2,
            localDeviceID: "local",
            devices: RustDevicesState(
                revision: devicesRevision ?? revision,
                sessionGeneration: 1,
                activeDeviceID: activeID,
                devices: [
                    ConnectProtocolDevice(id: "local", name: "Spotty", type: "computer"),
                    ConnectProtocolDevice(id: "phone", name: "Phone", type: "smartphone"),
                    ConnectProtocolDevice(id: "tablet", name: "Tablet", type: "tablet"),
                ]
            ),
            connection: RustConnectionState(
                revision: revision, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                isActiveDevice: activeID == "local", resumePending: false, lastError: nil, deviceID: "local"
            ),
            playback: RustPlaybackState(
                revision: revision, sessionGeneration: 1, isPlaying: false, isPaused: true,
                trackURI: trackURI, positionMS: 0, durationMS: 180_000, timestampMS: 0,
                shuffle: false, repeatTrack: false, repeatContext: false,
                isActiveDevice: activeID == "local"
            ),
            queue: nil
        )
    }
}

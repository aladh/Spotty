@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
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
        let output = HarnessSystemMediaOutput()
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
        #expect(access.isPlayingPlaylist("spotify:playlist:remote"), "paused playback retains its active context")
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
    func coldCurrentTrackRetainsAlbumAndArtistNavigation() async throws {
        let album = CatalogItem(
            id: "album", uri: "spotify:album:album", title: "Album", subtitle: "Album", artworkURL: nil, kind: .album)
        let artist = CatalogItem(
            id: "artist", uri: "spotify:artist:artist", title: "Artist", subtitle: "Artist", artworkURL: nil,
            kind: .artist)
        let remote = HarnessRemote()
        remote.onMetadata = { uri in
            SpotifyConnectTrackMetadata(
                uri: uri, title: "Track", artist: artist.title, artworkURL: nil, duration: 180,
                artists: [artist], albumItem: album)
        }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: remote))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        startTrackResolution(player, uri: "spotify:track:cold-links")
        try await requireEventually { player.catalogCurrentTrack?.albumItem == album }
        #expect(player.catalogCurrentTrack?.artists == [artist])
        #expect(player.catalogCurrentTrack?.album == album.title)
        #expect(remote.commands.isEmpty, "metadata navigation never sends a playback command")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func queueAdoptionPublishesOnlyAcceptedMetadata() async {
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
    }

    @Test
    @MainActor
    func retainedRemoteIdentityPublishesARouteWhenPlaybackArrives() async {
        let mac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)
        let phone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)
        let pausedURI = "spotify:track:paused-remote"
        let expectedPhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)

        let launchPreferences = HarnessPreferences()
        launchPreferences.seed(lastRemoteDeviceID: "phone")
        let launch = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(
                remote: HarnessRemote(metadataTitle: "Resolved"),
                preferences: launchPreferences
            )
        )
        _ = launch.send(.session(.ready), source: .account)
        _ = launch.send(
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
        launch.withRuntime { $0.preferenceState.rememberRemoteDevice("phone", accountEpoch: $0.accountEpoch) }
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
    }

    @Test
    @MainActor
    func playbackAndHistoryUseTheirRespectiveClockAnchors() async {
        let clockNow = HarnessDates.fixed
        let receipt = clockNow.addingTimeInterval(50)
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
            (player.history.first?.playedAt) == (clockNow),
            "played history uses the injected orchestration clock")
        #expect(
            (player.shuffleHistoryCache["spotify:track:clocked"]) == (clockNow.timeIntervalSince1970),
            "shuffle history uses the same orchestration clock instant")
        await player.shutdownForTermination()
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

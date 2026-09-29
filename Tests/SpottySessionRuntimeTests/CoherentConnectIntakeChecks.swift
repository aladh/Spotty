import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@Suite("Coherent Connect intake")
@SessionRuntimeActor
struct CoherentConnectIntakeTests {
    @Test(arguments: [false, true], [false, true])
    func observedListeningHistoryIncludesLocalAndRemoteTrackChanges(local: Bool, aggregated: Bool) async throws {
        let clock = HarnessClock.sticky()
        try await withIntakeRuntime(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"), clock: clock)
        ) { runtime in
            let activeID = local ? "local" : "phone"
            if !aggregated {
                let seed = HarnessFixtures.connectCluster(revision: 1, activeID: activeID, trackURI: "")
                runtime.receive(
                    RustConnectClusterState(
                        revision: 1, sessionGeneration: 1, source: 2, localDeviceID: seed.localDeviceID,
                        devices: seed.devices, connection: seed.connection, playback: nil, queue: nil),
                    receivedAt: clock.now())
            }
            @SessionRuntimeActor
            func receive(_ revision: UInt64, _ name: String, playing: Bool = true) throws {
                let observation = HarnessFixtures.connectCluster(
                    revision: revision, activeID: activeID, trackURI: "spotify:track:\(name)", isPlaying: playing)
                if aggregated {
                    runtime.receive(observation, receivedAt: clock.now())
                } else {
                    runtime.receive(try #require(observation.playback), revision: revision, receivedAt: clock.now())
                }
            }
            try receive(1, "startup")
            #expect(runtime.history.entries.isEmpty, "Opening the app must not manufacture a listening event")
            try receive(2, "paused", playing: false)
            #expect(runtime.history.entries.isEmpty, "A newly observed paused track is not a play")
            try receive(3, "heard")
            #expect(runtime.history.entries.map(\.uri) == ["spotify:track:heard"])
            let playedAt = clock.now()
            #expect(runtime.history.entries.first?.playedAt == playedAt)
            #expect(runtime.shuffleHistoryCache["spotify:track:heard"] == playedAt.timeIntervalSince1970)

            clock.advance(seconds: 60)
            try receive(4, "heard")
            try receive(3, "stale")
            #expect(
                runtime.history.entries.first?.playedAt == playedAt,
                "Timing samples must not rewrite when listening began")
            #expect(runtime.history.entries.map(\.uri) == ["spotify:track:heard"])
            if aggregated {
                runtime.receive(
                    HarnessFixtures.connectCluster(
                        revision: 5, activeID: activeID, trackURI: "spotify:track:stale-component",
                        isPlaying: true, playbackRevision: 3),
                    receivedAt: clock.now())
                #expect(
                    runtime.history.entries.map(\.uri) == ["spotify:track:heard"],
                    "Aggregate acceptance cannot admit stale playback")
            }

            let restored = HarnessFixtures.connectCluster(
                revision: 6, activeID: activeID, trackURI: "spotify:track:restored", isPlaying: true)
            runtime.receive(
                RustPlaybackEventEnvelope(
                    sequence: 1, receivedAt: clock.now(),
                    event: .resynchronizationRequired(
                        sessionGeneration: 1,
                        snapshots: [
                            RustPlaybackEventEnvelope(
                                sequence: 1, receivedAt: clock.now(), event: .cluster(restored))
                        ])))
            #expect(
                runtime.history.entries.map(\.uri) == ["spotify:track:heard"], "Recovery replays are not new listening")
            try receive(7, "later")
            #expect(runtime.history.entries.map(\.uri) == ["spotify:track:later", "spotify:track:heard"])
            #expect(runtime.history.entries.first?.playedAt == clock.now())
        }
    }

    @Test(arguments: [false, true], [false, true])
    func observedResumeRecordsTheSameTrackWithoutCommands(local: Bool, aggregated: Bool) async throws {
        let clock = HarnessClock.sticky()
        try await withIntakeRuntime(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"), clock: clock)
        ) { runtime in
            let activeID = local ? "local" : "phone"
            let uri = "spotify:track:resumed"
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: activeID, trackURI: uri), receivedAt: clock.now())
            #expect(runtime.history.entries.isEmpty, "The initial paused track has not been heard")
            @SessionRuntimeActor
            func receive(_ revision: UInt64, playing: Bool) throws {
                let observation = HarnessFixtures.connectCluster(
                    revision: revision, activeID: activeID, trackURI: uri, isPlaying: playing)
                if aggregated {
                    runtime.receive(observation, receivedAt: clock.now())
                } else {
                    runtime.receive(try #require(observation.playback), revision: revision, receivedAt: clock.now())
                }
            }

            clock.advance(seconds: 30)
            try receive(2, playing: true)
            let firstPlay = clock.now()
            #expect(
                runtime.history.entries.map(\.uri) == [uri], "An externally started current track belongs in history")
            #expect(runtime.history.entries.first?.playedAt == firstPlay)
            #expect(runtime.shuffleHistoryCache[uri] == firstPlay.timeIntervalSince1970)
            clock.advance(seconds: 30)
            try receive(3, playing: true)
            try receive(4, playing: false)
            try receive(3, playing: true)
            if aggregated {
                runtime.receive(
                    HarnessFixtures.connectCluster(
                        revision: 5, activeID: activeID, trackURI: uri, isPlaying: true, playbackRevision: 3),
                    receivedAt: clock.now())
            }
            #expect(
                runtime.history.entries.first?.playedAt == firstPlay,
                "Timing, pause, and stale samples are not new plays")
            try receive(6, playing: true)
            let resumedAt = clock.now()
            #expect(runtime.history.entries.count == 1, "Resuming updates the existing entry without duplicating it")
            #expect(runtime.history.entries.first?.playedAt == resumedAt)

            try receive(7, playing: false)
            clock.advance(seconds: 30)
            let restored = HarnessFixtures.connectCluster(
                revision: 8, activeID: activeID, trackURI: uri, isPlaying: true)
            runtime.receive(
                RustPlaybackEventEnvelope(
                    sequence: 1, receivedAt: clock.now(),
                    event: .resynchronizationRequired(
                        sessionGeneration: 1,
                        snapshots: [
                            RustPlaybackEventEnvelope(
                                sequence: 1, receivedAt: clock.now(), event: .cluster(restored))
                        ])))
            #expect(
                runtime.history.entries.first?.playedAt == resumedAt,
                "The recovery replay itself cannot record listening")
            try receive(9, playing: true)
            #expect(
                runtime.history.entries.first?.playedAt == (local ? clock.now() : resumedAt),
                "The first fresh local sample confirms playing after conservative recovery; remote timing stays inert")
            try receive(10, playing: false)
            try receive(11, playing: true)
            #expect(
                runtime.history.entries.first?.playedAt == clock.now(), "A fresh resume still records after recovery")
        }
    }

    @Test
    func observedIntentConfirmationWritesListeningHistoryOnce() async throws {
        let clock = HarnessClock.sticky()
        let preferences = HarnessPreferences()
        try await withIntakeRuntime(
            HarnessEnvironment.make(remote: HarnessRemote(send: .succeed), preferences: preferences, clock: clock)
        ) { runtime in
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: "phone", trackURI: "spotify:track:paused"),
                receivedAt: clock.now())
            let target = "spotify:track:confirmed"
            runtime.play(uri: target)
            let intent = try #require(runtime.state.intents.last)
            #expect(intent.outcome == .admitted)
            let settlement = try #require(runtime.effects.settlement(of: .command(intent.command.id)))
            await settlement.wait()
            #expect(runtime.state.intents.last?.outcome == .sent)
            #expect(runtime.history.entries.isEmpty, "Transport acceptance alone cannot record a play")
            clock.advance(seconds: 1)
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 2, activeID: "phone", trackURI: target, isPlaying: true),
                receivedAt: clock.now())
            #expect(runtime.history.entries.map(\.uri) == [target])
        }
        #expect(preferences.historyWrites.count == 1, "Intent confirmation and its observed transition share one write")
    }

    @Test
    func settledIntentRevokesOnlyItsUnclaimedPermit() async throws {
        try await withIntakeRuntime(HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))) {
            runtime in
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: "phone", trackURI: "spotify:track:a"),
                receivedAt: HarnessDates.fixed)
            let transportID = UUID()
            let optionsID = UUID()
            runtime.send(
                .commandStarted(
                    PendingPlaybackCommand(
                        id: transportID, kind: .transport, expectedTransport: nil, startedAt: HarnessDates.fixed)),
                source: .command
            )
            runtime.send(
                .commandStarted(
                    PendingPlaybackCommand(
                        id: optionsID, kind: .options, expectedTransport: nil, startedAt: HarnessDates.fixed)),
                source: .command
            )
            let transportPermit = runtime.makePlaybackDispatchPermit(intentID: transportID, ifStillWanted: { true })
            let optionsPermit = runtime.makePlaybackDispatchPermit(intentID: optionsID, ifStillWanted: { true })
            let transport = try #require(transportPermit)
            let options = try #require(optionsPermit)
            let queue = try admitQueuePermit(runtime)
            runtime.send(.commandFinished(id: transportID, accepted: false, notice: nil), source: .command)
            #expect(transport.claim() == false, "an intent settled before dispatch cannot send")
            #expect(
                runtime.makePlaybackDispatchPermit(intentID: transportID, ifStillWanted: { true }) == nil,
                "a settled intent cannot acquire a fresh permit")
            #expect(options.claim() == true, "settling one intent preserves another kind's permit")
            #expect(queue.claim() == true, "queue admission is independent of the transport pending slot")
            runtime.send(.commandFinished(id: optionsID, accepted: false, notice: nil), source: .command)
            let queuedAfterSettlement = try admitQueuePermit(runtime)
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 2, activeID: "local", trackURI: "spotify:track:a"),
                receivedAt: HarnessDates.fixed)
            #expect(queuedAfterSettlement.claim() == false, "handoff revokes queue work even without pending transport")
        }
    }

    @Test
    func aggregateOwnerAndQueueIdentityStayCoherent() async throws {
        try await withIntakeRuntime(HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))) {
            runtime in
            let observation = HarnessFixtures.connectCluster(
                revision: 1, activeID: "phone", trackURI: "spotify:track:new")
            runtime.receive(observation, receivedAt: HarnessDates.fixed)
            #expect(runtime.trackURI == "spotify:track:new")
            #expect(runtime.commandRoute == .remote(from: "local", to: "phone"))
            #expect(runtime.state.devices.devices.first(where: \.isActive)?.id == "phone")
            // Compare duplicate intake in one actor turn, before unrelated metadata can arrive.
            let accepted = runtime.state
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: "local", trackURI: "spotify:track:old"),
                receivedAt: HarnessDates.fixed)
            #expect(runtime.state == accepted)
        }
    }

    @Test
    func staleAggregateDevicesDoNotPersistRemoteIdentity() async throws {
        let preferences = HarnessPreferences()
        try await withIntakeRuntime(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"), preferences: preferences)
        ) { runtime in
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: "phone", trackURI: "spotify:track:a"),
                receivedAt: HarnessDates.fixed)
            await runtime.preferenceState.flush()
            #expect(preferences.storedRemoteDeviceID == "phone")

            let acceptedDevices = runtime.state.devices
            runtime.receive(
                HarnessFixtures.connectCluster(
                    revision: 2,
                    activeID: "tablet",
                    trackURI: "spotify:track:b",
                    devicesRevision: 0
                ),
                receivedAt: HarnessDates.fixed
            )

            #expect(
                runtime.state.devices == acceptedDevices,
                "a stale devices component does not replace the accepted device snapshot"
            )
            #expect(runtime.lastRemoteDeviceID == "phone", "the rejected component cannot change the saved route")
            await runtime.preferenceState.flush()
            #expect(
                preferences.storedRemoteDeviceID == "phone",
                "a stale aggregate devices component does not persist its remote identity"
            )
        }
    }

    @Test
    func pressureGapReconstructsTruthWithoutRestartingEngine() async throws {
        let engine = HarnessEngine()
        try await withIntakeRuntime(
            HarnessEnvironment.make(engine: engine, remote: HarnessRemote(metadataTitle: "Resolved"))
        ) { runtime in
            let authoritative = HarnessFixtures.connectCluster(
                revision: 1, activeID: "phone", trackURI: "spotify:track:a")
            runtime.receive(authoritative, receivedAt: HarnessDates.fixed)
            runtime.send(
                .commandStarted(
                    PendingPlaybackCommand(
                        id: UUID(), kind: .transport, expectedTransport: .playing,
                        expectedTrack: CurrentTrack(uri: "spotify:track:optimistic"), startedAt: HarnessDates.fixed
                    )
                ),
                source: .command
            )
            runtime.receive(
                RustPlaybackEventEnvelope(
                    sequence: 2,
                    receivedAt: HarnessDates.fixed,
                    event: .resynchronizationRequired(
                        sessionGeneration: 1,
                        snapshots: [
                            RustPlaybackEventEnvelope(
                                sequence: 1, receivedAt: HarnessDates.fixed,
                                event: .cluster(authoritative))
                        ]
                    )
                )
            )
            #expect(runtime.phase == .ready)
            #expect(runtime.state.pendingCommands.isEmpty)
            #expect(runtime.engineGeneration == 1)
            #expect(runtime.trackURI == "spotify:track:a")
            #expect(runtime.commandRoute == .remote(from: "local", to: "phone"))
            runtime.receive(
                HarnessFixtures.connectCluster(revision: 1, activeID: "local", trackURI: "spotify:track:old"),
                receivedAt: HarnessDates.fixed)
            #expect(runtime.trackURI == "spotify:track:a")
            let recovery = runtime.effects.settlement(of: .engineRecovery)
            let scheduledRecovery = recovery != nil
            #expect(!scheduledRecovery, "Snapshot replay must not schedule an engine restart")
            await recovery?.wait()
        }
        #expect(engine.forceReconnectCount == 0, "Recovering dropped observations must not restart the engine")
        #expect(engine.initializeCount == 0, "Snapshot replay must not initialize another player")
    }

}

@SessionRuntimeActor
private func withIntakeRuntime(
    _ environment: PlaybackEnvironment,
    body: @SessionRuntimeActor (PlaybackSessionRuntime) async throws -> Void
) async throws {
    let runtime = PlaybackSessionRuntime(environment: environment)
    do {
        try await body(runtime)
    } catch {
        await runtime.shutdownForTermination()
        throw error
    }
    await runtime.shutdownForTermination()
}

@SessionRuntimeActor
private func admitQueuePermit(_ runtime: PlaybackSessionRuntime) throws -> PlaybackDispatchPermit {
    let command = PendingPlaybackCommand(
        id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
    try #require(
        runtime.send(.queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command))
    let permit = runtime.makePlaybackDispatchPermit(intentID: command.id, ifStillWanted: { true })
    return try #require(permit)
}

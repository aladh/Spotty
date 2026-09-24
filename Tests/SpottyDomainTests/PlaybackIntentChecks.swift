import Foundation
import Testing
@testable import SpottyDomain

@Suite("Playback intent outcomes")
struct PlaybackIntentChecks {
    let now = Date(timeIntervalSince1970: 100)

    @Test func dispatchAndObservationAreDifferentFromTransportReturn() {
        var state = PlaybackState(session: .ready, currentTrack: CurrentTrack(uri: "spotify:track:a"))
        let id = UUID()
        func send(_ event: PlaybackEvent, source: PlaybackEventSource = .command, time: Date? = nil) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0, engineEpoch: 0, source: source, receivedAt: time ?? now, event: event))
        }
        let snapshot = EnginePlaybackSnapshot(
            transport: .playing, trackURI: "spotify:track:a", timing: PlaybackTiming())
        send(
            .commandStarted(
                PendingPlaybackCommand(id: id, kind: .transport, expectedTransport: .playing, startedAt: now)))
        send(.commandDispatched(id: id, at: now))
        send(.commandFinished(id: id, accepted: true, notice: nil))
        #expect(state.intents.last?.outcome == .sent)
        send(.enginePlayback(snapshot), source: .enginePlayback, time: now.addingTimeInterval(-1))
        #expect(state.intents.last?.outcome == .sent)
        send(.enginePlayback(snapshot), source: .enginePlayback)
        #expect(state.intents.last?.outcome == .observedConfirmed)
        send(.commandFinished(id: id, accepted: false, notice: PlaybackNotice(message: "late failure")))
        send(.commandTimedOut(id: id))
        #expect(state.intents.last?.outcome == .observedConfirmed)
        #expect(state.transport == .playing)
    }

    @Test func timeoutIsTerminalButLaterObservationStillUpdatesTruth() {
        var state = PlaybackState(session: .ready, currentTrack: CurrentTrack(uri: "spotify:track:a"))
        let id = UUID()
        func send(_ event: PlaybackEvent, source: PlaybackEventSource = .command) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0, engineEpoch: 0, source: source, receivedAt: now, event: event))
        }
        send(
            .commandStarted(
                PendingPlaybackCommand(id: id, kind: .transport, expectedTransport: .playing, startedAt: now)))
        send(.commandDispatched(id: id, at: now))
        send(.commandTimedOut(id: id))
        #expect(state.pendingCommands.isEmpty)
        send(.commandFinished(id: id, accepted: false, notice: PlaybackNotice(message: "late")))
        send(
            .enginePlayback(
                EnginePlaybackSnapshot(transport: .paused, trackURI: "spotify:track:a", timing: PlaybackTiming())),
            source: .enginePlayback)
        #expect(state.intents.last?.outcome == .timedOut)
        #expect(state.transport == .paused)
        #expect(state.notice == nil)
    }

    @Test func duplicateQueueRequestsNeedDistinctObservedOccurrences() {
        let command = PendingPlaybackCommand(id: UUID(), kind: .queue, expectedTransport: nil, startedAt: now)
        var first = PlaybackIntent(command: command, baselineTrackURI: nil)
        first.queueMinimumCounts = ["spotify:track:a": 1]
        first.dispatchedAt = now
        first.outcome = .sent
        var second = first
        second.queueMinimumCounts = ["spotify:track:a": 2]
        let observation = PlaybackEventEnvelope(
            accountEpoch: 0, engineEpoch: 0, source: .engineQueue,
            receivedAt: now,
            event: .queue(
                PlaybackQueueSnapshot(
                    entries: [PlaybackQueueItem(uri: "spotify:track:a", provider: "queue", uid: "one")],
                    source: .connect, completeness: .complete, revision: 1, receivedAt: now)))
        first.observe(observation)
        second.observe(observation)
        #expect(first.outcome == .observedConfirmed)
        #expect(second.outcome == .sent)
    }

    @Test func unknownFinishCannotInventReconciledSuccess() {
        let lifetime = PlaybackLifetime(accountEpoch: 1, engineGeneration: 1)
        #expect(
            playbackCommandFollowUp(
                finishAccepted: false, operationSucceeded: true,
                requiresReconnect: false,
                capturedLifetime: lifetime, currentLifetime: lifetime, isTearingDown: false) == .inert)
    }
    @Test func transferConfirmsStableIdentityAndIgnoresUncertainTarget() {
        let target = PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker")
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .transfer, expectedTransport: nil,
            expectedOwner: .uncertain(target), startedAt: now)
        var intent = PlaybackIntent(command: command, baselineTrackURI: nil)
        intent.dispatchedAt = now
        intent.outcome = .dispatched
        func observation(_ owner: PlaybackOwner) -> PlaybackEventEnvelope {
            PlaybackEventEnvelope(
                accountEpoch: 0, engineEpoch: 0, source: .engineConnection,
                receivedAt: now,
                event: .engineConnection(
                    EngineConnectionSnapshot(
                        session: .ready, owner: owner, localDeviceID: "mac")))
        }
        intent.observe(observation(.uncertain(target)))
        #expect(intent.outcome == .dispatched)
        intent.observe(
            observation(.remote(PlaybackDevice(id: "speaker", name: "Renamed", type: "cast", isActive: true))))
        #expect(intent.outcome == .observedConfirmed)
    }

    @Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func transferRequiresMatchingPlaybackAndOwner(local: Bool, ordering: (Bool, Bool)) {
        let (playing, ownerFirst) = ordering
        let target = PlaybackDevice(id: local ? "mac" : "speaker", name: "Target", type: "computer")
        let source = PlaybackDevice(id: "source", name: "Source", type: "computer")
        let transport: PlaybackTransportState = playing ? .playing : .paused
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .transfer, expectedTransport: nil,
            expectedOwner: local ? nil : .uncertain(target), startedAt: now)
        var state = PlaybackState(
            engineEpoch: 7, session: .ready, transport: transport,
            currentTrack: CurrentTrack(uri: "spotify:track:transfer"), playbackContextURI: "spotify:playlist:transfer",
            timing: PlaybackTiming(position: 42, anchoredAt: now))
        state.owner = .remote(source)
        state.devices = PlaybackDeviceSnapshot(devices: [target], localDeviceID: "mac", revision: 1)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: PlaybackEventEnvelope(
                accountEpoch: 0, engineEpoch: 7,
                source: .command, receivedAt: now, event: .commandStarted(command)))
        var intent = state.intents[0]
        intent.dispatchedAt = now
        intent.outcome = .sent
        func owner(epoch: UInt64 = 7) -> PlaybackEventEnvelope {
            PlaybackEventEnvelope(
                accountEpoch: 0, engineEpoch: epoch, source: .engineConnection, receivedAt: now,
                event: .engineConnection(
                    EngineConnectionSnapshot(
                        session: .ready,
                        owner: local ? .local(target) : .remote(target), localDeviceID: "mac")))
        }
        func playback(
            epoch: UInt64 = 7, track: String = "spotify:track:transfer",
            context: String? = "spotify:playlist:transfer", position: Double = 42,
            active: Bool? = nil, observedTransport: PlaybackTransportState? = nil
        ) -> PlaybackEventEnvelope {
            PlaybackEventEnvelope(
                accountEpoch: 0, engineEpoch: epoch, source: .enginePlayback, receivedAt: now,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: observedTransport ?? transport, trackURI: track,
                        timing: PlaybackTiming(position: position, anchoredAt: now), contextURI: context,
                        isActiveDevice: active ?? local)))
        }
        intent.observe(owner(epoch: 6))
        intent.observe(playback())
        #expect(intent.outcome == .sent, "an old generation cannot supply destination ownership")
        // Start each ordering without remembered evidence from the negative checks.
        intent = state.intents[0]
        intent.dispatchedAt = now
        intent.outcome = .sent
        for mismatch in [
            playback(epoch: 6), playback(track: "spotify:track:other"), playback(context: nil),
            playback(context: "spotify:playlist:other"), playback(position: 0), playback(active: !local),
            playback(observedTransport: .stopped),
        ] {
            var rejected = intent
            rejected.observe(owner())
            rejected.observe(mismatch)
            #expect(rejected.outcome == .sent)
        }
        intent.observe(ownerFirst ? owner() : playback())
        #expect(intent.outcome == .sent)
        intent.observe(ownerFirst ? playback() : owner())
        #expect(intent.outcome == .observedConfirmed)
    }

    @Test func unsentExpirationRestoresOptimism() {
        var state = PlaybackState(session: .ready, transport: .paused)
        let id = UUID()
        for event in [
            PlaybackEvent.commandStarted(
                PendingPlaybackCommand(
                    id: id, kind: .transport, expectedTransport: .playing, startedAt: now)), .commandTimedOut(id: id),
        ] {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0, engineEpoch: 0, source: .command, receivedAt: now, event: event))
        }
        #expect(state.intents.last?.outcome == .timedOut)
        #expect(state.intents.last?.dispatchedAt == nil)
        #expect(state.transport == .paused)
        #expect(state.pendingCommands.isEmpty)
    }

    @Test func navigationNeedsATrackChangeOrRestart() {
        var intent = PlaybackIntent(
            command: PendingPlaybackCommand(
                id: UUID(), kind: .navigation,
                expectedTransport: nil, startedAt: now), baselineTrackURI: "spotify:track:a")
        intent.baselinePosition = 45
        intent.dispatchedAt = now
        intent.outcome = .dispatched
        func observation(uri: String = "spotify:track:a", position: Double) -> PlaybackEventEnvelope {
            PlaybackEventEnvelope(
                accountEpoch: 0, engineEpoch: 0, source: .enginePlayback,
                receivedAt: now,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: uri, timing: PlaybackTiming(position: position))))
        }
        intent.observe(observation(position: 46))
        #expect(intent.outcome == .dispatched)
        var restart = intent
        intent.observe(observation(uri: "spotify:track:b", position: 0))
        restart.observe(observation(position: 0))
        #expect(intent.outcome == .observedConfirmed)
        #expect(restart.outcome == .observedConfirmed)
    }

    @Test func unsentPlayRollbackSettlesTheSeekItDisplaces() {
        var state = PlaybackState(
            session: .ready, transport: .paused, currentTrack: CurrentTrack(uri: "spotify:track:a"))
        let play = UUID(), seek = UUID()
        let events: [PlaybackEvent] = [
            .commandStarted(
                PendingPlaybackCommand(
                    id: play, kind: .transport, expectedTransport: .playing,
                    expectedTrack: CurrentTrack(uri: "spotify:track:b"), startedAt: now)),
            .commandStarted(
                PendingPlaybackCommand(
                    id: seek, kind: .seek, expectedTransport: nil,
                    expectedTiming: PlaybackTiming(position: 20), startedAt: now)),
            .commandTimedOut(id: play),
        ]
        for event in events {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0,
                    engineEpoch: 0, source: .command, receivedAt: now, event: event))
        }
        #expect(state.intents.first(where: { $0.command.id == seek })?.outcome == .superseded)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.currentTrack?.uri == "spotify:track:a")
        let settled = state
        #expect(
            !PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0,
                    engineEpoch: 0, source: .command, receivedAt: now, event: .commandTimedOut(id: seek))))
        #expect(state == settled)
    }

    @Test func unrelatedRawURISnapshotKeepsItsActualTransport() {
        var state = PlaybackState(
            session: .ready, transport: .paused, currentTrack: CurrentTrack(uri: "spotify:track:a"))
        let id = UUID()
        let events: [(PlaybackEventSource, PlaybackEvent)] = [
            (
                .command,
                .commandStarted(
                    PendingPlaybackCommand(
                        id: id, kind: .transport,
                        expectedTransport: .playing, expectedTrackURI: "spotify:track:b", startedAt: now))
            ),
            (.command, .commandDispatched(id: id, at: now)),
            (
                .enginePlayback,
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: "spotify:track:c", timing: PlaybackTiming(position: 30)))
            ),
        ]
        for (source, event) in events {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 0,
                    engineEpoch: 0, source: source, receivedAt: now, event: event))
        }
        #expect(state.currentTrack?.uri == "spotify:track:c")
        #expect(state.transport == .paused)
        #expect(state.intents.last?.outcome == .superseded)
    }

}

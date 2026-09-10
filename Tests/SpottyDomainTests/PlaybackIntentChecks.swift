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
                requiresReconnect: false, commandKind: .transport, pendingCommandID: nil,
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

}

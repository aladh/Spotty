import Testing
import SpottyDomain
import Foundation

private let seekReconciliationDate = Date(timeIntervalSince1970: 2_000_000)
private let seekReconciliationTrack = "spotify:track:seek-reconciliation"

private func seekReconciliationEnvelope(
    account: UInt64 = 1,
    engine: UInt64 = 1,
    source: PlaybackEventSource,
    revision: UInt64? = nil,
    receivedAt: Date = seekReconciliationDate,
    event: PlaybackEvent
) -> PlaybackEventEnvelope {
    PlaybackEventEnvelope(
        accountEpoch: account,
        engineEpoch: engine,
        source: source,
        revision: revision,
        receivedAt: receivedAt,
        event: event
    )
}

@discardableResult
private func startSeek(
    _ state: inout PlaybackState,
    id: UUID,
    expected: PlaybackTiming
) -> Bool {
    PlaybackReducer.reduce(
        &state,
        envelope: seekReconciliationEnvelope(
            source: .command,
            event: .commandStarted(
                PendingPlaybackCommand(
                    id: id,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: expected,
                    startedAt: seekReconciliationDate
                ))
        )
    )
}

private func engineTimingEnvelope(
    revision: UInt64,
    timing: PlaybackTiming,
    trackURI: String? = seekReconciliationTrack,
    account: UInt64 = 1,
    engine: UInt64 = 1
) -> PlaybackEventEnvelope {
    seekReconciliationEnvelope(
        account: account,
        engine: engine,
        source: .enginePlayback,
        revision: revision,
        receivedAt: timing.anchoredAt,
        event: .enginePlayback(
            EnginePlaybackSnapshot(
                transport: trackURI == nil ? .stopped : .playing,
                trackURI: trackURI,
                timing: timing
            ))
    )
}

@Suite("Playback Seek Reconciliation")
struct PlaybackSeekReconciliationTests {
    @Test(arguments: [
        (PlaybackTransportState.playing, 0.15, 80.15, true),
        (.playing, 3.0, 83.15, true),
        (.playing, 3.0, 80.15, true),
        (.paused, 3.0, 80.15, true),
        (.paused, 3.0, 83.0, false),
        (.playing, 3.0, 78.0, false),
        (.playing, 3.0, 85.0, false),
        (.playing, -0.1, 80.0, false),
    ])
    func seekConfirmationAllowsElapsedPlaybackButRejectsUnrelatedPositions(
        transport: PlaybackTransportState, elapsed: TimeInterval, position: TimeInterval, confirms: Bool
    ) {
        let expected = PlaybackTiming(position: 80, duration: 200, anchoredAt: seekReconciliationDate)
        let actual = PlaybackTiming(
            position: position, duration: 200, anchoredAt: seekReconciliationDate.addingTimeInterval(elapsed))
        let id = UUID()
        var state = PlaybackState(
            accountEpoch: 1, engineEpoch: 1, session: .ready, transport: transport,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: PlaybackTiming(position: 10, duration: 200, anchoredAt: seekReconciliationDate))
        _ = startSeek(&state, id: id, expected: expected)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: seekReconciliationEnvelope(
                source: .command, event: .commandDispatched(id: id, at: seekReconciliationDate)))
        _ = PlaybackReducer.reduce(
            &state,
            envelope: seekReconciliationEnvelope(
                source: .enginePlayback, revision: 1, receivedAt: actual.anchoredAt,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(transport: transport, trackURI: seekReconciliationTrack, timing: actual))))

        #expect(state.timing == (confirms ? actual : expected))
        #expect((state.pendingCommands[.seek] == nil) == confirms)
        #expect(state.intents.last?.outcome == (confirms ? .observedConfirmed : .dispatched))
        _ = PlaybackReducer.reduce(
            &state,
            envelope: seekReconciliationEnvelope(
                source: .command, receivedAt: seekReconciliationDate.addingTimeInterval(8),
                event: .commandTimedOut(id: id)))
        #expect(state.intents.last?.outcome == (confirms ? .observedConfirmed : .timedOut))
    }

    @Test
    func testLatestAuthoritativeTimingWinsRejectedSeekRollback() {
        let prior = PlaybackTiming(
            position: 40,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(-10)
        )
        let expected = PlaybackTiming(
            position: 80,
            duration: 200,
            anchoredAt: seekReconciliationDate
        )
        let firstCorrection = PlaybackTiming(
            position: 77,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(1)
        )
        let latestCorrection = PlaybackTiming(
            position: 73,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(2)
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000181")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: prior
        )

        #expect((startSeek(&state, id: commandID, expected: expected)) == true, "the seek starts")
        #expect((state.timing) == (expected), "the optimistic seek remains visible")

        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: engineTimingEnvelope(revision: 1, timing: firstCorrection)
            )) == true,
            "the first same-track engine correction is accepted"
        )
        #expect((state.timing) == (expected), "the first correction does not break the optimistic hold")
        #expect(
            (state.pendingCommands[.seek]?.latestAuthoritativeTiming) == (firstCorrection),
            "the first correction is retained for reconciliation"
        )

        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: engineTimingEnvelope(revision: 2, timing: latestCorrection)
            )) == true,
            "the newer same-track engine correction is accepted"
        )
        #expect((state.timing) == (expected), "the latest correction still does not break the optimistic hold")
        #expect(
            (state.pendingCommands[.seek]?.latestAuthoritativeTiming) == (latestCorrection),
            "the latest correction replaces the earlier retained sample"
        )

        let beforeStaleCorrection = state
        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: engineTimingEnvelope(revision: 1, timing: firstCorrection)
            )) == false,
            "an older engine revision is rejected before seek reconciliation"
        )
        #expect((state) == (beforeStaleCorrection), "a stale engine sample cannot replace the latest correction")

        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: seekReconciliationEnvelope(
                    source: .command,
                    event: .commandFinished(
                        id: commandID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Seek was rejected")
                    )
                )
            )) == true,
            "the rejected seek finish is accepted"
        )
        #expect((state.timing) == (latestCorrection), "rejection restores the newest authoritative timing")
        #expect(
            (state.timing.anchoredAt) == (latestCorrection.anchoredAt),
            "rejection preserves the authoritative sample timestamp"
        )
        #expect((state.pendingCommands[.seek]) == nil, "the rejected seek clears its command")
    }

    @Test
    func testRejectedSeekFallsBackWhenNoAuthoritativeSampleArrives() {
        let prior = PlaybackTiming(
            position: 25,
            duration: 180,
            anchoredAt: seekReconciliationDate.addingTimeInterval(-4)
        )
        let expected = PlaybackTiming(
            position: 100,
            duration: 180,
            anchoredAt: seekReconciliationDate
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000182")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: prior
        )

        #expect((startSeek(&state, id: commandID, expected: expected)) == true, "the seek starts")
        _ = PlaybackReducer.reduce(
            &state,
            envelope: seekReconciliationEnvelope(
                source: .user,
                receivedAt: seekReconciliationDate.addingTimeInterval(1),
                event: .timing(
                    position: 60,
                    duration: 180,
                    anchoredAt: seekReconciliationDate.addingTimeInterval(1)
                )
            )
        )
        #expect((state.timing) == (expected), "a non-engine timing event keeps the optimistic hold")
        #expect(
            (state.pendingCommands[.seek]?.latestAuthoritativeTiming) == nil,
            "a non-authoritative timing event is not used for seek rollback"
        )

        _ = PlaybackReducer.reduce(
            &state,
            envelope: seekReconciliationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: commandID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((state.timing) == (prior), "a rejected seek with no engine sample uses pre-command timing")
        #expect((state.timing.anchoredAt) == (prior.anchoredAt), "fallback keeps the pre-command timestamp")
    }

    @Test
    func testMatchingAuthoritativeTimingConfirmsSeek() {
        let prior = PlaybackTiming(
            position: 10,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(-2)
        )
        let expected = PlaybackTiming(
            position: 80,
            duration: 200,
            anchoredAt: seekReconciliationDate
        )
        let confirmed = PlaybackTiming(
            position: 80,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(3)
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000183")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: prior
        )

        _ = startSeek(&state, id: commandID, expected: expected)
        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: engineTimingEnvelope(revision: 1, timing: confirmed)
            )) == true,
            "a matching engine sample is accepted"
        )
        #expect((state.timing) == (confirmed), "confirmation adopts the authoritative sample")
        #expect((state.pendingCommands[.seek]) == nil, "a matching engine sample confirms the seek")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: false,
                operationSucceeded: false,
                requiresReconnect: true,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert),
            "a late reconnect-required seek finish has no recovery side effect after confirmation"
        )

        let afterConfirmation = state
        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: seekReconciliationEnvelope(
                    source: .command,
                    event: .commandFinished(
                        id: commandID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Seek was rejected")
                    )
                )
            )) == false,
            "a finish after confirmation is stale"
        )
        #expect((state) == (afterConfirmation), "a stale finish cannot roll back a confirmed seek")
    }

    @Test
    func testNewTrackSupersedesSeekAndStaleFinish() {
        let prior = PlaybackTiming(
            position: 20,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(-1)
        )
        let expected = PlaybackTiming(
            position: 90,
            duration: 200,
            anchoredAt: seekReconciliationDate
        )
        let replacement = PlaybackTiming(
            position: 0,
            duration: 180,
            anchoredAt: seekReconciliationDate.addingTimeInterval(1)
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000184")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: prior
        )

        _ = startSeek(&state, id: commandID, expected: expected)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: engineTimingEnvelope(
                revision: 1,
                timing: replacement,
                trackURI: "spotify:track:replacement"
            )
        )
        #expect((state.currentTrack?.uri) == ("spotify:track:replacement"), "the newer track is adopted")
        #expect((state.timing) == (replacement), "the newer track timing is adopted")
        #expect((state.pendingCommands[.seek]) == nil, "a newer track supersedes the pending seek")

        let afterTrackSwitch = state
        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: seekReconciliationEnvelope(
                    source: .command,
                    event: .commandFinished(
                        id: commandID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Seek was rejected")
                    )
                )
            )) == false,
            "a finish for the superseded seek is stale"
        )
        #expect((state) == (afterTrackSwitch), "a superseded seek cannot restore the old track timing")
    }

    @Test
    func testEngineGenerationDropsRetainedSeekTiming() {
        let prior = PlaybackTiming(
            position: 30,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(-2)
        )
        let expected = PlaybackTiming(
            position: 70,
            duration: 200,
            anchoredAt: seekReconciliationDate
        )
        let correction = PlaybackTiming(
            position: 65,
            duration: 200,
            anchoredAt: seekReconciliationDate.addingTimeInterval(1)
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000185")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: seekReconciliationTrack),
            timing: prior
        )

        _ = startSeek(&state, id: commandID, expected: expected)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: engineTimingEnvelope(revision: 3, timing: correction)
        )
        #expect(
            (state.pendingCommands[.seek]?.latestAuthoritativeTiming) == (correction),
            "the correction is retained in the original engine generation"
        )

        _ = PlaybackReducer.reduce(
            &state,
            envelope: engineTimingEnvelope(
                revision: 1,
                timing: PlaybackTiming(position: 66, duration: 200, anchoredAt: correction.anchoredAt),
                account: 1,
                engine: 2
            )
        )
        #expect((state.engineEpoch) == (2), "the new engine generation is adopted")
        #expect((state.pendingCommands[.seek]) == nil, "a new engine generation drops the old seek")

        let afterGenerationAdvance = state
        #expect(
            (PlaybackReducer.reduce(
                &state,
                envelope: seekReconciliationEnvelope(
                    account: 1,
                    engine: 1,
                    source: .command,
                    event: .commandFinished(
                        id: commandID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Seek was rejected")
                    )
                )
            )) == false,
            "a finish from the old engine generation is stale"
        )
        #expect((state) == (afterGenerationAdvance), "an old finish cannot restore retained timing")
    }
}

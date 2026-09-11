import Testing
import SpottyDomain
import Foundation

private let presentationDate = Date(timeIntervalSince1970: 1_000_000)

private func presentationEnvelope(
    account: UInt64 = 1,
    engine: UInt64 = 1,
    source: PlaybackEventSource,
    revision: UInt64? = nil,
    event: PlaybackEvent
) -> PlaybackEventEnvelope {
    PlaybackEventEnvelope(
        accountEpoch: account,
        engineEpoch: engine,
        source: source,
        revision: revision,
        receivedAt: presentationDate,
        event: event
    )
}

/// The timings every presentation scenario shares. They are pure values derived from
/// `presentationDate`, so each check still builds its own state from them.
private let playingAnchor = presentationDate.addingTimeInterval(-10)
private let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
private let frozenPauseTiming = PlaybackTiming(
    position: interpolatedPlaybackPosition(
        anchor: 40,
        anchoredAt: playingAnchor,
        now: presentationDate,
        isPlaying: true,
        duration: 200
    ),
    duration: 200,
    anchoredAt: presentationDate
)
private let priorSeekTiming = PlaybackTiming(position: 12, duration: 200, anchoredAt: playingAnchor)
private let seekTiming = PlaybackTiming(position: 80, duration: 200, anchoredAt: presentationDate)

@Suite("Playback Command Presentation")
struct PlaybackCommandPresentationTests {
    @Test
    func pauseAndResumeFreezeThenReanchorDisplayedTiming() {
        let pauseID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let resumeID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!

        #expect((frozenPauseTiming.position) == (50), "the pause freeze is the displayed playing position")

        var pauseState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorPlayingTiming
        )
        _ = PlaybackReducer.reduce(
            &pauseState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: pauseID,
                        kind: .transport,
                        expectedTransport: .paused,
                        expectedTiming: frozenPauseTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect((pauseState.transport) == (.paused), "pause applies paused transport atomically")
        #expect((pauseState.timing) == (frozenPauseTiming), "pause freezes timing at the displayed position")
        #expect(
            (pauseState.pendingCommands[.transport]?.rollbackTransport) == (.playing),
            "pause captures the pre-command transport for rollback")
        #expect(
            (pauseState.pendingCommands[.transport]?.rollbackTiming) == (priorPlayingTiming),
            "pause captures the pre-command timing for rollback")

        let afterOptimisticPause = pauseState
        _ = PlaybackReducer.reduce(
            &pauseState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: pauseID, accepted: false, notice: PlaybackNotice(message: "Pause was rejected"))
            )
        )
        #expect((pauseState.transport) == (.playing), "a rejected pause restores the pre-command transport")
        #expect(
            (pauseState.timing) == (priorPlayingTiming), "a rejected pause restores the exact pre-command timing")
        #expect((pauseState.pendingCommands[.transport]) == nil, "a rejected pause clears its pending command")
        #expect(
            (pauseState.timing != afterOptimisticPause.timing) == true,
            "a rejected pause is not a no-op relative to optimism")

        let priorPausedTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: playingAnchor)
        let resumeTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: presentationDate)
        var resumeState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            timing: priorPausedTiming
        )
        _ = PlaybackReducer.reduce(
            &resumeState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: resumeID,
                        kind: .transport,
                        expectedTransport: .playing,
                        expectedTiming: resumeTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect((resumeState.transport) == (.playing), "resume applies playing transport atomically")
        #expect((resumeState.timing) == (resumeTiming), "resume re-anchors timing from now without moving position")
        _ = PlaybackReducer.reduce(
            &resumeState,
            envelope: presentationEnvelope(
                source: .command, event: .commandFinished(id: resumeID, accepted: true, notice: nil))
        )
        #expect((resumeState.timing) == (resumeTiming), "an accepted resume keeps the re-anchored timing")
        #expect((resumeState.transport) == (.playing), "an accepted resume keeps playing")
    }

    @Test
    func seekPresentsAcceptedStaleAndSupersededPositions() {
        let seekID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let acceptedSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let staleSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
        let matchingSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!
        let mismatchedSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000038")!
        let supersededSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000036")!
        let replacementSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000037")!

        var seekState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &seekState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: seekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect((seekState.transport) == (.playing), "seek does not change transport")
        #expect((seekState.timing) == (seekTiming), "seek applies optimistic timing")
        #expect(
            (seekState.pendingCommands[.seek]?.rollbackTiming) == (priorSeekTiming),
            "seek captures the pre-command timing for rollback")
        _ = PlaybackReducer.reduce(
            &seekState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: seekID, accepted: false, notice: PlaybackNotice(message: "Seek was rejected"))
            )
        )
        #expect((seekState.timing) == (priorSeekTiming), "a rejected seek restores the exact pre-command timing")
        #expect((seekState.pendingCommands[.seek]) == nil, "a rejected seek clears its pending command")

        var acceptedSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &acceptedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: acceptedSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &acceptedSeek,
            envelope: presentationEnvelope(
                source: .command, event: .commandFinished(id: acceptedSeekID, accepted: true, notice: nil))
        )
        #expect((acceptedSeek.timing) == (seekTiming), "an accepted seek keeps the optimistic timing")
        #expect((acceptedSeek.pendingCommands[.seek]) == nil, "an accepted seek clears its pending command")

        let clearedTrackSeekID = UUID(uuidString: "00000000-0000-0000-0000-00000000003B")!
        var clearedTrackSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &clearedTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: clearedTrackSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        let stoppedTiming = PlaybackTiming(
            position: 0, duration: 0, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &clearedTrackSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .stopped,
                        trackURI: nil,
                        timing: stoppedTiming
                    ))
            )
        )
        #expect((clearedTrackSeek.timing) == (stoppedTiming), "a nil-track snapshot adopts the incoming timing")
        #expect(
            (clearedTrackSeek.pendingCommands[.seek]) == nil, "a nil-track snapshot supersedes the pending seek")

        let nilCurrentTrackSeekID = UUID(uuidString: "00000000-0000-0000-0000-00000000003C")!
        var nilCurrentTrackSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: nilCurrentTrackSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(
                source: .user,
                event: .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: nil,
                        transport: .stopped,
                        timing: PlaybackTiming(
                            position: 0,
                            duration: 0,
                            anchoredAt: presentationDate
                        )
                    ))
            )
        )
        #expect(
            (nilCurrentTrackSeek.pendingCommands[.seek]) == nil,
            "a nil current-track event supersedes a seek with no current URI")
        #expect((nilCurrentTrackSeek.timing.position) == (0), "a nil current-track event resets timing")
        let afterNilCurrentTrack = nilCurrentTrackSeek
        let nilCurrentTrackFinish = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: nilCurrentTrackSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((!nilCurrentTrackFinish) == true, "a finish after a nil current-track event is rejected")
        #expect(
            (nilCurrentTrackSeek) == (afterNilCurrentTrack),
            "a nil current-track event cannot restore seek rollback timing")

        var mismatchedSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:seek"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: mismatchedSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        let laggingTiming = PlaybackTiming(
            position: 21, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:seek",
                        timing: laggingTiming
                    ))
            )
        )
        #expect(
            (mismatchedSeek.timing) == (seekTiming), "a lagging engine snapshot cannot undo optimistic seek timing")
        #expect(
            (mismatchedSeek.pendingCommands[.seek]?.id) == (mismatchedSeekID),
            "a lagging engine snapshot does not reconcile the pending seek")
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: mismatchedSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect(
            (mismatchedSeek.timing) == (laggingTiming),
            "a rejected seek after a lagging snapshot restores its latest authoritative timing")

        var matchingSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:seek"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: matchingSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        let confirmedTiming = PlaybackTiming(
            position: 80, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:seek",
                        timing: confirmedTiming
                    ))
            )
        )
        #expect(
            (matchingSeek.timing) == (confirmedTiming), "a matching engine snapshot adopts confirmed seek timing")
        #expect(
            (matchingSeek.pendingCommands[.seek]) == nil, "a matching engine snapshot reconciles the pending seek")
        let afterConfirmedSeek = matchingSeek
        let confirmedFinish = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: matchingSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((!confirmedFinish) == true, "a finish after a matching seek snapshot is rejected")
        #expect((matchingSeek) == (afterConfirmedSeek), "a matching snapshot prevents stale seek rollback")

        let trackSwitchSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000039")!
        var trackSwitchSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:a"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: trackSwitchSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        let trackBTiming = PlaybackTiming(
            position: 0, duration: 180, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:b",
                        timing: trackBTiming
                    ))
            )
        )
        #expect((trackSwitchSeek.timing) == (trackBTiming), "a newer track snapshot adopts the incoming timing")
        #expect(
            (trackSwitchSeek.currentTrack?.uri) == ("spotify:track:b"),
            "a newer track snapshot replaces the current track")
        #expect(
            (trackSwitchSeek.pendingCommands[.seek]) == nil,
            "a newer track snapshot supersedes the old pending seek")
        let afterTrackSwitch = trackSwitchSeek
        let supersededByTrackFinish = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: trackSwitchSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((!supersededByTrackFinish) == true, "a finish after a track switch is rejected")
        #expect(
            (trackSwitchSeek) == (afterTrackSwitch),
            "a track-switched seek cannot restore the previous track's timing")

        let currentTrackSwitchID = UUID(uuidString: "00000000-0000-0000-0000-00000000003A")!
        var currentTrackSwitch = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:a"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: currentTrackSwitchID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .user,
                event: .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(uri: "spotify:track:b"),
                        transport: .playing,
                        timing: priorSeekTiming
                    ))
            )
        )
        #expect(
            (currentTrackSwitch.currentTrack?.uri) == ("spotify:track:b"),
            "a current-track switch keeps the new track")
        #expect(
            (currentTrackSwitch.pendingCommands[.seek]) == nil,
            "a current-track switch supersedes the old pending seek"
        )
        let afterCurrentTrackSwitch = currentTrackSwitch
        let currentTrackFinish = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: currentTrackSwitchID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((!currentTrackFinish) == true, "a finish after a current-track switch is rejected")
        #expect(
            (currentTrackSwitch) == (afterCurrentTrackSwitch),
            "a current-track switch cannot restore the previous track's timing")

        var identitySeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: staleSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                engine: 2,
                source: .engineConnection,
                revision: 1,
                event: .engineConnection(
                    EngineConnectionSnapshot(
                        session: .recovering,
                        owner: .none,
                        localDeviceID: nil
                    ))
            )
        )
        #expect((identitySeek.pendingCommands[.seek]) == nil, "an engine-epoch bump drops the pending seek")
        #expect((identitySeek.timing) == (seekTiming), "an engine-epoch bump does not roll back seek timing")
        let afterEngineBump = identitySeek
        let staleIdentityFinish = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                engine: 1,
                source: .command,
                event: .commandFinished(
                    id: staleSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        #expect((!staleIdentityFinish) == true, "a captured-engine seek finish is rejected after an epoch bump")
        #expect((identitySeek) == (afterEngineBump), "a stale-identity finish cannot roll back seek timing")

        var supersededSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: supersededSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: seekTiming,
                        startedAt: presentationDate
                    ))
            )
        )
        let replacementTiming = PlaybackTiming(
            position: 90, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: replacementSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: replacementTiming,
                        startedAt: presentationDate.addingTimeInterval(1)
                    ))
            )
        )
        let afterReplacementSeek = supersededSeek
        let supersededFinish = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededSeekID, accepted: false, notice: PlaybackNotice(message: "Seek was rejected"))
            )
        )
        #expect((!supersededFinish) == true, "a superseded seek finish is rejected")
        #expect(
            (supersededSeek) == (afterReplacementSeek), "a superseded seek finish cannot roll back the replacement")
        #expect(
            (supersededSeek.pendingCommands[.seek]?.id) == (replacementSeekID),
            "the replacement seek remains pending")
        #expect((supersededSeek.timing) == (replacementTiming), "the replacement seek keeps its optimistic timing")
        #expect(
            (supersededSeek.pendingCommands[.seek]?.rollbackTiming) == (seekTiming),
            "the replacement seek rolls back to the superseded optimistic timing")
    }

    @Test
    func playCommandsPresentTrackChangesUntilTheEngineConfirms() {
        let playID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let nilID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let acceptedID = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
        let rawID = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
        let trackA = CurrentTrack(
            uri: "spotify:track:a",
            title: "A",
            artist: "Artist",
            duration: 200,
            metadataSource: .catalog
        )
        let trackB = CurrentTrack(
            uri: "spotify:track:b",
            title: "B",
            artist: "Artist",
            duration: 180,
            metadataSource: .catalog
        )
        let optimisticTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: presentationDate)
        let laggingATiming = PlaybackTiming(position: 44, duration: 200, anchoredAt: presentationDate)

        func startPlay(
            _ state: inout PlaybackState,
            id: UUID,
            expected: CurrentTrack = trackB
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: id,
                            kind: .transport,
                            expectedTransport: .playing,
                            expectedTiming: PlaybackTiming(
                                position: 0,
                                duration: expected.duration,
                                anchoredAt: presentationDate
                            ),
                            expectedTrack: expected,
                            startedAt: presentationDate
                        ))
                )
            )
        }

        var playingA = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&playingA, id: playID)
        #expect((playingA.currentTrack) == (trackB), "play presents the known target atomically")
        #expect((playingA.transport) == (.playing), "play applies playing transport atomically")
        #expect((playingA.timing) == (optimisticTiming), "play applies target timing atomically")
        #expect(
            (playingA.pendingCommands[.transport]?.rollbackPresentation)
                == (PlaybackPresentationSnapshot(
                    currentTrack: trackA,
                    transport: .playing,
                    timing: priorPlayingTiming
                )), "play captures the exact pre-command presentation")

        _ = PlaybackReducer.reduce(
            &playingA,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: trackA.uri,
                        timing: laggingATiming
                    ))
            )
        )
        #expect((playingA.currentTrack) == (trackB), "a lagging A snapshot keeps the optimistic B track")
        #expect((playingA.timing) == (optimisticTiming), "a lagging A snapshot keeps B timing")
        #expect((playingA.pendingCommands[.transport]?.id) == (playID), "a lagging A snapshot does not confirm B")
        #expect((playingA.transportCommandResolutions[playID]) == nil, "a lagging A snapshot is not a confirmation")

        _ = PlaybackReducer.reduce(
            &playingA,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: playID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((playingA.currentTrack) == (trackA), "a rejected play restores track A")
        #expect((playingA.transport) == (.playing), "a rejected play restores playing")
        #expect((playingA.timing) == (priorPlayingTiming), "a rejected play restores exact prior timing")
        #expect((playingA.pendingCommands[.transport]) == nil, "a rejected play clears its pending command")

        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&confirmed, id: confirmedID)
        _ = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: trackB.uri,
                        timing: PlaybackTiming(position: 1, duration: 180, anchoredAt: presentationDate)
                    ))
            )
        )
        #expect((confirmed.currentTrack?.uri) == (trackB.uri), "an authoritative B snapshot keeps B")
        #expect((confirmed.pendingCommands[.transport]) == nil, "an authoritative B snapshot confirms the command")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "an authoritative B snapshot records confirmation")
        let capturedConfirmation = confirmed.transportCommandResolutions[confirmedID]
        let lateFailure = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((lateFailure) == true, "a late failure after B confirmation is accepted to consume the entry")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == nil,
            "a late failure after B confirmation consumes the resolution")
        #expect(
            (confirmed.transportCommandResolutions.isEmpty) == true,
            "a late failure after B confirmation leaves no resolution map entries")
        let secondConfirmedFinish = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((!secondConfirmedFinish) == true, "a second finish after confirmation consume is rejected")
        #expect((confirmed.currentTrack) == (trackB), "a late failure after B confirmation keeps B")
        #expect((confirmed.timing.position) == (1), "a late failure after B confirmation does not restore A timing")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateFailure,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transport,
                pendingCommandID: confirmed.pendingCommands[.transport]?.id,
                finishedCommandResolution: capturedConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess), "a captured confirmation still reports success after consume-only acceptance")

        var superseded = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&superseded, id: supersededID)
        let trackCTiming = PlaybackTiming(position: 8, duration: 240, anchoredAt: presentationDate)
        _ = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:c",
                        timing: trackCTiming
                    ))
            )
        )
        #expect((superseded.currentTrack?.uri) == ("spotify:track:c"), "an unrelated C snapshot adopts C")
        #expect((superseded.timing) == (trackCTiming), "an unrelated C snapshot adopts C timing")
        #expect(
            (superseded.pendingCommands[.transport]) == nil, "an unrelated C snapshot clears B rollback ownership")
        #expect(
            (superseded.transportCommandResolutions[supersededID]) == (.superseded),
            "an unrelated C snapshot records supersession")
        let capturedSupersession = superseded.transportCommandResolutions[supersededID]
        let supersededFinish = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((supersededFinish) == true, "a late finish after C supersession is accepted to consume the entry")
        #expect(
            (superseded.transportCommandResolutions[supersededID]) == nil,
            "a late finish after C supersession consumes the resolution")
        #expect(
            (superseded.transportCommandResolutions.isEmpty) == true,
            "a late finish after C supersession leaves no resolution map entries")
        #expect(
            (superseded.currentTrack?.uri) == ("spotify:track:c"), "a late finish after C supersession leaves C")
        #expect((superseded.timing) == (trackCTiming), "a late finish after C supersession keeps C timing")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: supersededFinish,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transport,
                pendingCommandID: superseded.pendingCommands[.transport]?.id,
                finishedCommandResolution: capturedSupersession,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert), "a captured supersession stays inert after consume-only acceptance")

        var cleared = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&cleared, id: nilID)
        _ = PlaybackReducer.reduce(
            &cleared,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .stopped,
                        trackURI: nil,
                        timing: PlaybackTiming(anchoredAt: presentationDate)
                    ))
            )
        )
        #expect((cleared.currentTrack) == nil, "a nil snapshot clears the optimistic track")
        #expect((cleared.transport) == (.stopped), "a nil snapshot stops transport")
        #expect((cleared.pendingCommands[.transport]) == nil, "a nil snapshot clears B rollback ownership")
        #expect(
            (cleared.transportCommandResolutions[nilID]) == (.superseded), "a nil snapshot records supersession")

        var accepted = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&accepted, id: acceptedID)
        _ = PlaybackReducer.reduce(
            &accepted,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: acceptedID, accepted: true, notice: nil)
            )
        )
        #expect((accepted.currentTrack) == (trackB), "an accepted play keeps the known target")
        #expect((accepted.transport) == (.playing), "an accepted play keeps playing")
        #expect((accepted.timing) == (optimisticTiming), "an accepted play keeps target timing")
        #expect((accepted.pendingCommands[.transport]) == nil, "an accepted play clears its pending command")

        var raw = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        _ = PlaybackReducer.reduce(
            &raw,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: rawID,
                        kind: .transport,
                        expectedTransport: .playing,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect((raw.currentTrack) == (trackA), "a raw play does not invent a target track")
        #expect((raw.transport) == (.playing), "a raw play still applies playing")
        #expect(
            (raw.pendingCommands[.transport]?.rollbackPresentation) == nil,
            "a raw play has no presentation rollback")
        _ = PlaybackReducer.reduce(
            &raw,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: trackA.uri,
                        timing: laggingATiming
                    ))
            )
        )
        #expect((raw.pendingCommands[.transport]) == nil, "a raw play is still confirmed by matching transport")

        let seekThenPlayID = UUID(uuidString: "00000000-0000-0000-0000-000000000046")!
        let staleSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000047")!
        var seekThenPlay = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        _ = PlaybackReducer.reduce(
            &seekThenPlay,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: staleSeekID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: PlaybackTiming(position: 80, duration: 200, anchoredAt: presentationDate),
                        startedAt: presentationDate
                    ))
            )
        )
        startPlay(&seekThenPlay, id: seekThenPlayID)
        #expect((seekThenPlay.pendingCommands[.seek]) == nil, "a different-track play supersedes a pending seek")
        #expect((seekThenPlay.timing) == (optimisticTiming), "a different-track play keeps target timing at zero")
        #expect((seekThenPlay.currentTrack) == (trackB), "a different-track play still presents B")
        _ = PlaybackReducer.reduce(
            &seekThenPlay,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: trackB.uri,
                        timing: PlaybackTiming(position: 0, duration: 180, anchoredAt: presentationDate)
                    ))
            )
        )
        #expect((seekThenPlay.pendingCommands[.seek]) == nil, "a B snapshot after play does not revive the seek")
        #expect((seekThenPlay.timing) == (optimisticTiming), "a B snapshot after play keeps timing at zero")

        let pauseAfterPlayID = UUID(uuidString: "00000000-0000-0000-0000-000000000048")!
        var supersededThenPause = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&supersededThenPause, id: supersededID)
        _ = PlaybackReducer.reduce(
            &supersededThenPause,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:c",
                        timing: trackCTiming
                    ))
            )
        )
        #expect(
            (supersededThenPause.transportCommandResolutions[supersededID]) == (.superseded),
            "C supersession records the play id as superseded")
        _ = PlaybackReducer.reduce(
            &supersededThenPause,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: pauseAfterPlayID,
                        kind: .transport,
                        expectedTransport: .paused,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect(
            (supersededThenPause.transportCommandResolutions[supersededID]) == (.superseded),
            "a later pause does not drop the superseded play id")
        #expect(
            (supersededThenPause.pendingCommands[.transport]?.id) == (pauseAfterPlayID),
            "a later pause is the pending transport command")
        let capturedPauseSupersession = supersededThenPause.transportCommandResolutions[supersededID]
        let latePlayFinish = PlaybackReducer.reduce(
            &supersededThenPause,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((latePlayFinish) == true, "a late play finish after C then pause consumes the play entry")
        #expect(
            (supersededThenPause.transportCommandResolutions[supersededID]) == nil,
            "a late play finish after C then pause removes the play resolution")
        #expect(
            (supersededThenPause.pendingCommands[.transport]?.id) == (pauseAfterPlayID),
            "a late play finish after C then pause leaves the pause pending")
        #expect(
            (supersededThenPause.currentTrack?.uri) == ("spotify:track:c"),
            "a late play finish after C then pause leaves C")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: latePlayFinish,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transport,
                pendingCommandID: supersededThenPause.pendingCommands[.transport]?.id,
                finishedCommandResolution: capturedPauseSupersession,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert), "a late play finish after C then pause is inert")
        _ = PlaybackReducer.reduce(
            &supersededThenPause,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: pauseAfterPlayID, accepted: true, notice: nil)
            )
        )
        #expect(
            (supersededThenPause.transport) == (.paused),
            "the later pause can still finish after the play entry was consumed")
        #expect(
            (supersededThenPause.pendingCommands[.transport]) == nil, "an accepted pause clears the pending pause")

        let seekDuringPlayID = UUID(uuidString: "00000000-0000-0000-0000-000000000049")!
        let playThenRejectID = UUID(uuidString: "00000000-0000-0000-0000-00000000004A")!
        var seekDuringPlay = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&seekDuringPlay, id: playThenRejectID)
        _ = PlaybackReducer.reduce(
            &seekDuringPlay,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: seekDuringPlayID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: PlaybackTiming(position: 90, duration: 180, anchoredAt: presentationDate),
                        startedAt: presentationDate
                    ))
            )
        )
        #expect(
            (seekDuringPlay.pendingCommands[.seek]?.id) == (seekDuringPlayID),
            "a seek can start while a known-target play is pending")
        _ = PlaybackReducer.reduce(
            &seekDuringPlay,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: playThenRejectID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((seekDuringPlay.currentTrack) == (trackA), "a rejected play restores A after a nested seek")
        #expect(
            (seekDuringPlay.timing) == (priorPlayingTiming),
            "a rejected play restores A's timing after a nested seek")
        #expect((seekDuringPlay.pendingCommands[.seek]) == nil, "a rejected play drops a seek that targeted B")

        let sameURIPlayID = UUID(uuidString: "00000000-0000-0000-0000-00000000004B")!
        let seekSameURIID = UUID(uuidString: "00000000-0000-0000-0000-00000000004C")!
        var sameURI = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&sameURI, id: sameURIPlayID, expected: trackA)
        _ = PlaybackReducer.reduce(
            &sameURI,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: seekSameURIID,
                        kind: .seek,
                        expectedTransport: nil,
                        expectedTiming: PlaybackTiming(position: 90, duration: 200, anchoredAt: presentationDate),
                        startedAt: presentationDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &sameURI,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: sameURIPlayID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        #expect((sameURI.currentTrack) == (trackA), "a rejected same-URI play restores A")
        #expect((sameURI.timing) == (priorPlayingTiming), "a rejected same-URI play restores A's timing")
        #expect((sameURI.pendingCommands[.seek]) == nil, "a rejected same-URI play drops the nested seek")
    }

    @Test
    func shuffleAndOptionsPresentOptimisticFlagsUntilConfirmed() {
        let shuffleID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let acceptedID = UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
        let laterOptionsID = UUID(uuidString: "00000000-0000-0000-0000-000000000053")!
        let repeatID = UUID(uuidString: "00000000-0000-0000-0000-000000000054")!

        func startShuffle(_ state: inout PlaybackState, id: UUID, expected: Bool) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: id,
                            kind: .options,
                            expectedTransport: nil,
                            expectedShuffle: expected,
                            startedAt: presentationDate
                        ))
                )
            )
        }

        func engineShuffle(
            _ state: inout PlaybackState,
            shuffle: Bool,
            revision: UInt64,
            repeatMode: RepeatMode? = nil
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .enginePlayback,
                    revision: revision,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: presentationDate),
                            shuffle: shuffle,
                            repeatMode: repeatMode
                        ))
                )
            )
        }

        var rejected = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true)
        )
        startShuffle(&rejected, id: shuffleID, expected: false)
        #expect((rejected.options.shuffle) == (false), "shuffle applies the requested value atomically")
        #expect(
            (rejected.pendingCommands[.options]?.rollbackShuffle) == (true),
            "shuffle captures the exact pre-command value")
        #expect(
            (rejected.pendingCommands[.options]?.expectedShuffle) == (false), "shuffle records the requested target"
        )
        engineShuffle(&rejected, shuffle: true, revision: 1)
        #expect((rejected.options.shuffle) == (false), "a lagging on snapshot keeps optimistic off")
        #expect(
            (rejected.pendingCommands[.options]?.id) == (shuffleID), "a lagging on snapshot does not confirm off")
        #expect(
            (rejected.transportCommandResolutions[shuffleID]) == nil, "a lagging on snapshot is not a confirmation")
        _ = PlaybackReducer.reduce(
            &rejected,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: shuffleID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update shuffle")
                )
            )
        )
        #expect((rejected.options.shuffle) == (true), "a rejected shuffle restores the exact prior value")
        #expect((rejected.pendingCommands[.options]) == nil, "a rejected shuffle clears its pending command")

        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true)
        )
        startShuffle(&confirmed, id: confirmedID, expected: false)
        engineShuffle(&confirmed, shuffle: false, revision: 1)
        #expect((confirmed.options.shuffle) == (false), "an authoritative off snapshot keeps off")
        #expect((confirmed.pendingCommands[.options]) == nil, "an authoritative off snapshot confirms the command")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "an authoritative off snapshot records confirmation")
        let capturedConfirmation = confirmed.transportCommandResolutions[confirmedID]
        let lateFailure = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update shuffle")
                )
            )
        )
        #expect((lateFailure) == true, "a late failure after shuffle confirmation is accepted to consume the entry")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == nil,
            "a late failure after shuffle confirmation consumes the resolution")
        #expect((confirmed.options.shuffle) == (false), "a late failure after shuffle confirmation keeps off")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateFailure,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .options,
                pendingCommandID: confirmed.pendingCommands[.options]?.id,
                finishedCommandResolution: capturedConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess),
            "a captured shuffle confirmation still reports success after consume-only acceptance")

        var accepted = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: false)
        )
        startShuffle(&accepted, id: acceptedID, expected: true)
        _ = PlaybackReducer.reduce(
            &accepted,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: acceptedID, accepted: true, notice: nil)
            )
        )
        #expect((accepted.options.shuffle) == (true), "an accepted shuffle keeps the requested value")
        #expect((accepted.pendingCommands[.options]) == nil, "an accepted shuffle clears its pending command")

        var laterOptions = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true, repeatMode: .off)
        )
        startShuffle(&laterOptions, id: confirmedID, expected: false)
        engineShuffle(&laterOptions, shuffle: false, revision: 1)
        #expect(
            (laterOptions.transportCommandResolutions[confirmedID]) == (.confirmed),
            "shuffle confirmation records the shuffle id")
        _ = PlaybackReducer.reduce(
            &laterOptions,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: laterOptionsID,
                        kind: .options,
                        expectedTransport: nil,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect(
            (laterOptions.transportCommandResolutions[confirmedID]) == (.confirmed),
            "a later options command does not drop the confirmed shuffle id")
        #expect(
            (laterOptions.pendingCommands[.options]?.id) == (laterOptionsID),
            "a later options command is the pending options command")
        #expect(
            (laterOptions.pendingCommands[.options]?.rollbackShuffle) == (nil as Bool?),
            "a later options command does not invent shuffle rollback")
        #expect((laterOptions.options.shuffle) == (false), "a later options command keeps confirmed off")
        let capturedLaterConfirmation = laterOptions.transportCommandResolutions[confirmedID]
        let lateShuffleFinish = PlaybackReducer.reduce(
            &laterOptions,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update shuffle")
                )
            )
        )
        #expect(
            (lateShuffleFinish) == true,
            "a late shuffle finish after a later options command consumes the shuffle entry")
        #expect(
            (laterOptions.transportCommandResolutions[confirmedID]) == nil,
            "a late shuffle finish after a later options command removes the shuffle resolution")
        #expect(
            (laterOptions.pendingCommands[.options]?.id) == (laterOptionsID),
            "a late shuffle finish after a later options command leaves that command pending")
        #expect(
            (laterOptions.options.shuffle) == (false),
            "a late shuffle finish after a later options command keeps off")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateShuffleFinish,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .options,
                pendingCommandID: laterOptions.pendingCommands[.options]?.id,
                finishedCommandResolution: capturedLaterConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess), "a late shuffle finish after a later options command still reports success")
        _ = PlaybackReducer.reduce(
            &laterOptions,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: laterOptionsID, accepted: true, notice: nil)
            )
        )
        #expect(
            (laterOptions.options.shuffle) == (false),
            "the later options command can still finish after the shuffle entry was consumed")
        #expect(
            (laterOptions.pendingCommands[.options]) == nil,
            "an accepted later options command clears pending options")

        var repeatPending = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true, repeatMode: .off)
        )
        _ = PlaybackReducer.reduce(
            &repeatPending,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: repeatID,
                        kind: .options,
                        expectedTransport: nil,
                        startedAt: presentationDate
                    ))
            )
        )
        engineShuffle(&repeatPending, shuffle: false, revision: 1, repeatMode: .track)
        #expect((repeatPending.options.shuffle) == (false), "a repeat options command still adopts engine shuffle")
        #expect(
            (repeatPending.options.repeatMode) == (.track), "a repeat options command still adopts engine repeat")
        #expect(
            (repeatPending.pendingCommands[.options]?.id) == (repeatID),
            "a shuffle sample does not confirm a repeat options command")
        #expect(
            (repeatPending.transportCommandResolutions[repeatID]) == nil,
            "a shuffle sample does not record confirmation for a repeat command")
        _ = PlaybackReducer.reduce(
            &repeatPending,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: repeatID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect(
            (repeatPending.options.shuffle) == (false), "a rejected repeat options command does not restore shuffle"
        )
        #expect(
            (repeatPending.options.repeatMode) == (.track),
            "a rejected repeat options command does not restore repeat")

        let restoreID = UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
        var restored = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true, repeatMode: .off)
        )
        startShuffle(&restored, id: restoreID, expected: false)
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: presentationEnvelope(
                source: .user,
                event: .options(PlaybackOptions(shuffle: true, repeatMode: .track))
            )
        )
        #expect((restored.options.shuffle) == (false), "a restoring .options event keeps optimistic off")
        #expect((restored.options.repeatMode) == (.track), "a restoring .options event still adopts repeat")
        #expect(
            (restored.pendingCommands[.options]?.id) == (restoreID),
            "a restoring .options event does not confirm off")
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: restoreID, accepted: true, notice: nil)
            )
        )
        #expect(
            (restored.options.shuffle) == (false), "an accepted shuffle after a restoring .options event keeps off")
        #expect(
            (restored.options.repeatMode) == (.track),
            "an accepted shuffle after a restoring .options event keeps adopted repeat")

        let matchingUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000056")!
        var matchingUser = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true, repeatMode: .off)
        )
        startShuffle(&matchingUser, id: matchingUserID, expected: false)
        _ = PlaybackReducer.reduce(
            &matchingUser,
            envelope: presentationEnvelope(
                source: .user,
                event: .options(PlaybackOptions(shuffle: false, repeatMode: .track))
            )
        )
        #expect((matchingUser.options.shuffle) == (false), "a matching user .options event keeps optimistic off")
        #expect((matchingUser.options.repeatMode) == (.track), "a matching user .options event still adopts repeat")
        #expect(
            (matchingUser.pendingCommands[.options]?.id) == (matchingUserID),
            "a matching user .options event does not confirm off")
        #expect(
            (matchingUser.transportCommandResolutions[matchingUserID]) == nil,
            "a matching user .options event is not a confirmation")
        engineShuffle(&matchingUser, shuffle: false, revision: 1)
        #expect(
            (matchingUser.options.shuffle) == (false),
            "an engine sample after a matching user .options event keeps off"
        )
        #expect(
            (matchingUser.pendingCommands[.options]) == nil,
            "an engine sample after a matching user .options event confirms shuffle")
        #expect(
            (matchingUser.transportCommandResolutions[matchingUserID]) == (.confirmed),
            "an engine sample after a matching user .options event records confirmation")

        let rejectUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000057")!
        var rejectUser = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true)
        )
        startShuffle(&rejectUser, id: rejectUserID, expected: false)
        _ = PlaybackReducer.reduce(
            &rejectUser,
            envelope: presentationEnvelope(
                source: .user,
                event: .options(PlaybackOptions(shuffle: false))
            )
        )
        _ = PlaybackReducer.reduce(
            &rejectUser,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: rejectUserID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update shuffle")
                )
            )
        )
        #expect(
            (rejectUser.options.shuffle) == (true),
            "rejection after only a matching user .options event restores on")
        #expect(
            (rejectUser.pendingCommands[.options]) == nil,
            "rejection after only a matching user .options event clears pending")
        #expect(
            (rejectUser.transportCommandResolutions[rejectUserID]) == nil,
            "rejection after only a matching user .options event has no confirmation")
    }

    @Test
    func repeatTransitionsPresentEachRequestedModeUntilConfirmed() {
        let offToContextID = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
        let contextToTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let trackToOffID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
        let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000074")!
        let lagID = UUID(uuidString: "00000000-0000-0000-0000-000000000075")!
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000076")!
        let intermediateID = UUID(uuidString: "00000000-0000-0000-0000-000000000077")!

        func startRepeat(_ state: inout PlaybackState, id: UUID, expected: RepeatFlags) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: id,
                            kind: .options,
                            expectedTransport: nil,
                            expectedRepeatFlags: expected,
                            startedAt: presentationDate
                        ))
                )
            )
        }

        func engineRepeat(
            _ state: inout PlaybackState,
            flags: RepeatFlags,
            revision: UInt64
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .enginePlayback,
                    revision: revision,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: presentationDate),
                            shuffle: false,
                            repeatMode: RepeatMode(context: flags.context, track: flags.track),
                            repeatFlags: flags
                        ))
                )
            )
        }

        func assertCycle(
            from: RepeatMode,
            id: UUID,
            label: String
        ) {
            var state = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                options: PlaybackOptions(repeatMode: from)
            )
            startRepeat(&state, id: id, expected: from.next.flags)
            #expect(
                (state.options.repeatFlags) == (from.next.flags), "\(label) applies the requested flags atomically")
            #expect((state.options.repeatMode) == (from.next), "\(label) displays the next mode")
            #expect(
                (state.pendingCommands[.options]?.rollbackRepeatFlags) == (from.flags),
                "\(label) captures the exact pre-command flags")
            #expect(
                (state.pendingCommands[.options]?.expectedRepeatFlags) == (from.next.flags),
                "\(label) records the requested target")
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandFinished(
                        id: id,
                        accepted: false,
                        notice: PlaybackNotice(message: "Could not update repeat")
                    )
                )
            )
            #expect(
                (state.options.repeatFlags) == (from.flags), "\(label) rejection restores the exact prior flags")
            #expect((state.options.repeatMode) == (from), "\(label) rejection restores the prior mode")
            #expect((state.pendingCommands[.options]) == nil, "\(label) rejection clears its pending command")
        }

        assertCycle(from: .off, id: offToContextID, label: "off → context")
        assertCycle(from: .context, id: contextToTrackID, label: "context → track")
        assertCycle(from: .track, id: trackToOffID, label: "track → off")

        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(repeatMode: .off)
        )
        startRepeat(&confirmed, id: confirmedID, expected: RepeatMode.context.flags)
        engineRepeat(&confirmed, flags: RepeatMode.context.flags, revision: 1)
        #expect((confirmed.options.repeatMode) == (.context), "an authoritative context snapshot keeps context")
        #expect(
            (confirmed.pendingCommands[.options]) == nil, "an authoritative context snapshot confirms the command")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "an authoritative context snapshot records confirmation")
        let capturedConfirmation = confirmed.transportCommandResolutions[confirmedID]
        let lateFailure = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect((lateFailure) == true, "a late failure after repeat confirmation is accepted to consume the entry")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == nil,
            "a late failure after repeat confirmation consumes the resolution")
        #expect(
            (confirmed.options.repeatMode) == (.context), "a late failure after repeat confirmation keeps context")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateFailure,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .options,
                pendingCommandID: confirmed.pendingCommands[.options]?.id,
                finishedCommandResolution: capturedConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess),
            "a captured repeat confirmation still reports success after consume-only acceptance"
        )

        var superseded = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(repeatMode: .off)
        )
        startRepeat(&superseded, id: supersededID, expected: RepeatMode.context.flags)
        engineRepeat(&superseded, flags: RepeatMode.track.flags, revision: 1)
        #expect((superseded.options.repeatMode) == (.track), "unrelated authoritative track supersedes context")
        #expect(
            (superseded.pendingCommands[.options]) == nil, "unrelated authoritative track drops the pending command"
        )
        #expect(
            (superseded.transportCommandResolutions[supersededID]) == (.superseded),
            "unrelated authoritative track records supersession")
        let capturedSupersession = superseded.transportCommandResolutions[supersededID]
        let lateSuperseded = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect(
            (lateSuperseded) == true, "a late failure after repeat supersession is accepted to consume the entry")
        #expect((superseded.options.repeatMode) == (.track), "a late failure after repeat supersession keeps track")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateSuperseded,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .options,
                pendingCommandID: superseded.pendingCommands[.options]?.id,
                finishedCommandResolution: capturedSupersession,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert), "a captured repeat supersession stays inert after consume-only acceptance")

        var lagging = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(repeatMode: .off)
        )
        startRepeat(&lagging, id: lagID, expected: RepeatMode.context.flags)
        engineRepeat(&lagging, flags: RepeatMode.off.flags, revision: 1)
        #expect((lagging.options.repeatMode) == (.context), "a lagging off snapshot keeps optimistic context")
        #expect(
            (lagging.pendingCommands[.options]?.id) == (lagID), "a lagging off snapshot does not confirm context")
        #expect((lagging.transportCommandResolutions[lagID]) == nil, "a lagging off snapshot is not a confirmation")
        _ = PlaybackReducer.reduce(
            &lagging,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: lagID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect(
            (lagging.options.repeatMode) == (.off), "a rejected repeat after a lagging prior sample restores off")

        var userOptions = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(shuffle: true, repeatMode: .off)
        )
        startRepeat(&userOptions, id: userID, expected: RepeatMode.context.flags)
        _ = PlaybackReducer.reduce(
            &userOptions,
            envelope: presentationEnvelope(
                source: .user,
                event: .options(
                    PlaybackOptions(shuffle: false, repeatMode: .context, repeatFlags: RepeatMode.context.flags))
            )
        )
        #expect(
            (userOptions.options.repeatMode) == (.context),
            "a matching user .options event keeps optimistic context")
        #expect((userOptions.options.shuffle) == (false), "a matching user .options event still adopts shuffle")
        #expect(
            (userOptions.pendingCommands[.options]?.id) == (userID),
            "a matching user .options event does not confirm context")
        #expect(
            (userOptions.transportCommandResolutions[userID]) == nil,
            "a matching user .options event is not a confirmation")
        _ = PlaybackReducer.reduce(
            &userOptions,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: userID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect(
            (userOptions.options.repeatMode) == (.off),
            "rejection after only a matching user .options event restores off")

        var intermediate = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(repeatMode: .context)
        )
        startRepeat(&intermediate, id: intermediateID, expected: RepeatMode.track.flags)
        engineRepeat(&intermediate, flags: RepeatMode.off.flags, revision: 1)
        #expect((intermediate.options.repeatMode) == (.off), "context → track intermediate off is visible")
        #expect(
            (intermediate.pendingCommands[.options]?.id) == (intermediateID),
            "context → track intermediate off stays pending")
        #expect(
            (intermediate.transportCommandResolutions[intermediateID]) == nil,
            "context → track intermediate off is not confirmation")
        _ = PlaybackReducer.reduce(
            &intermediate,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: intermediateID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        #expect(
            (intermediate.options.repeatMode) == (.context),
            "context → track intermediate off then rejection restores context")
        #expect(
            (intermediate.options.repeatFlags) == (RepeatMode.context.flags),
            "context → track intermediate off then rejection restores context flags")
    }

    @Test
    func transferPresentsOwnershipUntilItIsConfirmedOrRolledBack() {
        let transferID = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let acceptedID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
        let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000064")!
        let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000065")!
        let noneID = UUID(uuidString: "00000000-0000-0000-0000-000000000066")!
        let noneRollbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000067")!
        let ownerA = PlaybackOwner.remote(
            PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true))
        let deviceB = PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: false)
        let expectedB = PlaybackOwner.uncertain(deviceB)
        let remoteB = PlaybackOwner.remote(
            PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true))
        let renamedB = PlaybackOwner.remote(
            PlaybackDevice(id: "speaker-b", name: "Kitchen", type: "speaker", isActive: true))
        let ownerC = PlaybackOwner.remote(
            PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true))
        let localMac = PlaybackOwner.local(PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true))
        let deviceD = PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker", isActive: false)

        func startTransfer(
            _ state: inout PlaybackState,
            id: UUID,
            expected: PlaybackOwner,
            startedAt: Date = presentationDate
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: id,
                            kind: .transfer,
                            expectedTransport: nil,
                            expectedOwner: expected,
                            startedAt: startedAt
                        ))
                )
            )
        }

        func connectionOwner(
            _ state: inout PlaybackState,
            owner: PlaybackOwner,
            revision: UInt64
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .engineConnection,
                    revision: revision,
                    event: .engineConnection(
                        EngineConnectionSnapshot(
                            session: .ready,
                            owner: owner,
                            localDeviceID: "mac"
                        ))
                )
            )
        }

        func devicesOwner(
            _ state: inout PlaybackState,
            devices: [PlaybackDevice],
            revision: UInt64,
            lastRemoteDeviceID: String? = "speaker-a"
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .engineDevices,
                    revision: revision,
                    event: .devices(
                        PlaybackDeviceSnapshot(
                            devices: devices,
                            localDeviceID: "mac",
                            revision: revision,
                            lastRemoteDeviceID: lastRemoteDeviceID
                        ))
                )
            )
        }

        var rejected = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&rejected, id: transferID, expected: expectedB)
        #expect((rejected.owner) == (expectedB), "transfer applies the uncertain target atomically")
        #expect(
            (rejected.pendingCommands[.transfer]?.rollbackOwner) == (Optional(ownerA)),
            "transfer captures the exact prior owner")
        #expect(
            (rejected.pendingCommands[.transfer]?.expectedOwner) == (Optional(expectedB)),
            "transfer records the requested target owner")
        connectionOwner(&rejected, owner: ownerA, revision: 1)
        #expect((rejected.owner) == (expectedB), "a lagging prior-owner connection keeps the target")
        #expect(
            (rejected.pendingCommands[.transfer]?.id) == (transferID),
            "a lagging prior-owner connection does not confirm")
        #expect(
            (rejected.transportCommandResolutions[transferID]) == nil,
            "a lagging prior-owner connection is not a confirmation")
        _ = PlaybackReducer.reduce(
            &rejected,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: transferID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect((rejected.owner) == (ownerA), "a rejected transfer restores the exact prior owner")
        #expect((rejected.pendingCommands[.transfer]) == nil, "a rejected transfer clears its pending command")

        var laggingDevices = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&laggingDevices, id: transferID, expected: expectedB)
        devicesOwner(
            &laggingDevices,
            devices: [
                PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                deviceB,
            ],
            revision: 1
        )
        #expect((laggingDevices.owner) == (expectedB), "a lagging prior-owner devices snapshot keeps the target")
        #expect(
            (laggingDevices.pendingCommands[.transfer]?.id) == (transferID),
            "a lagging prior-owner devices snapshot does not confirm")
        _ = PlaybackReducer.reduce(
            &laggingDevices,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: transferID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect((laggingDevices.owner) == (ownerA), "lagging devices then rejection restores the exact prior owner")

        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&confirmed, id: confirmedID, expected: expectedB)
        connectionOwner(&confirmed, owner: remoteB, revision: 1)
        #expect((confirmed.owner) == (remoteB), "an authoritative target connection adopts identified B")
        #expect(
            (confirmed.pendingCommands[.transfer]) == nil, "an authoritative target connection confirms the command"
        )
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "an authoritative target connection records confirmation")
        let capturedConfirmation = confirmed.transportCommandResolutions[confirmedID]
        let lateFailure = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect(
            (lateFailure) == true, "a late failure after transfer confirmation is accepted to consume the entry")
        #expect(
            (confirmed.transportCommandResolutions[confirmedID]) == nil,
            "a late failure after transfer confirmation consumes the resolution")
        #expect((confirmed.owner) == (remoteB), "a late failure after transfer confirmation keeps B")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateFailure,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transfer,
                pendingCommandID: confirmed.pendingCommands[.transfer]?.id,
                finishedCommandResolution: capturedConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess),
            "a captured transfer confirmation still reports success after consume-only acceptance")

        var renamed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&renamed, id: confirmedID, expected: expectedB)
        connectionOwner(&renamed, owner: renamedB, revision: 1)
        #expect((renamed.owner) == (renamedB), "a same-id renamed target still confirms")
        #expect((renamed.pendingCommands[.transfer]) == nil, "a same-id renamed target confirms the command")
        #expect(
            (renamed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "a same-id renamed target records confirmation")

        var devicesConfirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&devicesConfirmed, id: confirmedID, expected: expectedB)
        devicesOwner(
            &devicesConfirmed,
            devices: [
                PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker"),
                PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true),
            ],
            revision: 1
        )
        #expect((devicesConfirmed.owner) == (remoteB), "an active-B devices snapshot confirms the transfer")
        #expect(
            (devicesConfirmed.pendingCommands[.transfer]) == nil,
            "an active-B devices snapshot clears the pending transfer")
        #expect(
            (devicesConfirmed.transportCommandResolutions[confirmedID]) == (.confirmed),
            "an active-B devices snapshot records confirmation")

        var uncertainTarget = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&uncertainTarget, id: transferID, expected: expectedB)
        connectionOwner(&uncertainTarget, owner: expectedB, revision: 1)
        #expect((uncertainTarget.owner) == (expectedB), "an uncertain target copy keeps the admitted owner")
        #expect(
            (uncertainTarget.pendingCommands[.transfer]?.id) == (transferID),
            "an uncertain target copy does not confirm")
        #expect(
            (uncertainTarget.transportCommandResolutions[transferID]) == nil,
            "an uncertain target copy is not a confirmation")
        _ = PlaybackReducer.reduce(
            &uncertainTarget,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: transferID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect((uncertainTarget.owner) == (ownerA), "rejection after only an uncertain target copy restores A")

        var accepted = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA
        )
        startTransfer(&accepted, id: acceptedID, expected: expectedB)
        _ = PlaybackReducer.reduce(
            &accepted,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: acceptedID, accepted: true, notice: nil)
            )
        )
        #expect(
            (accepted.owner) == (expectedB), "an accepted transfer without a snapshot keeps the admitted target")
        #expect((accepted.pendingCommands[.transfer]) == nil, "an accepted transfer clears its pending command")

        var superseded = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&superseded, id: supersededID, expected: expectedB)
        connectionOwner(&superseded, owner: ownerC, revision: 1)
        #expect((superseded.owner) == (ownerC), "an unrelated owner supersedes the optimistic target")
        #expect((superseded.pendingCommands[.transfer]) == nil, "an unrelated owner clears the pending transfer")
        #expect(
            (superseded.transportCommandResolutions[supersededID]) == (.superseded),
            "an unrelated owner records supersession")
        let capturedSupersession = superseded.transportCommandResolutions[supersededID]
        let lateSuperseded = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect((lateSuperseded) == true, "a late failure after unrelated supersession consumes the entry")
        #expect((superseded.owner) == (ownerC), "a late failure after unrelated supersession keeps C")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateSuperseded,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transfer,
                pendingCommandID: superseded.pendingCommands[.transfer]?.id,
                finishedCommandResolution: capturedSupersession,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert), "a captured transfer supersession stays inert after a late failure")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: true,
                operationSucceeded: true,
                requiresReconnect: false,
                commandKind: .transfer,
                pendingCommandID: nil,
                finishedCommandResolution: .superseded,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.inert), "accepted completion after unrelated supersession stays inert")

        var localSupersede = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&localSupersede, id: localID, expected: expectedB)
        connectionOwner(&localSupersede, owner: localMac, revision: 1)
        #expect((localSupersede.owner) == (localMac), "an unrelated local owner supersedes the remote target")
        #expect(
            (localSupersede.transportCommandResolutions[localID]) == (.superseded),
            "an unrelated local owner records supersession")
        _ = PlaybackReducer.reduce(
            &localSupersede,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: localID, accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B"))
            )
        )
        #expect((localSupersede.owner) == (localMac), "a late failure after local supersession keeps this Mac")

        var noneSupersede = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&noneSupersede, id: noneID, expected: expectedB)
        connectionOwner(&noneSupersede, owner: .none, revision: 1)
        #expect((noneSupersede.owner) == (.none), "an unrelated empty owner supersedes the remote target")
        #expect(
            (noneSupersede.transportCommandResolutions[noneID]) == (.superseded),
            "an unrelated empty owner records supersession")
        _ = PlaybackReducer.reduce(
            &noneSupersede,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: noneID, accepted: true, notice: nil)
            )
        )
        #expect((noneSupersede.owner) == (.none), "accepted completion after empty supersession keeps none")

        var noneRollback = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .none,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&noneRollback, id: noneRollbackID, expected: expectedB)
        #expect((noneRollback.owner) == (expectedB), "a transfer from none still presents the target")
        #expect(
            (noneRollback.pendingCommands[.transfer]?.rollbackOwner) == (Optional(PlaybackOwner.none)),
            "a transfer from none captures empty rollback")
        connectionOwner(&noneRollback, owner: .none, revision: 1)
        #expect((noneRollback.owner) == (expectedB), "a lagging empty prior owner keeps the target")
        #expect(
            (noneRollback.pendingCommands[.transfer]?.id) == (noneRollbackID),
            "a lagging empty prior owner keeps the pending command")
        #expect(
            (noneRollback.transportCommandResolutions[noneRollbackID]) == nil,
            "a lagging empty prior owner is not a resolution")
        _ = PlaybackReducer.reduce(
            &noneRollback,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: noneRollbackID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect((noneRollback.owner) == (.none), "rejection after a lagging empty snapshot restores none")

        var laterTransfer = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA,
            currentTrack: CurrentTrack(uri: "spotify:track:a")
        )
        startTransfer(&laterTransfer, id: confirmedID, expected: expectedB)
        connectionOwner(&laterTransfer, owner: remoteB, revision: 1)
        startTransfer(&laterTransfer, id: laterID, expected: .uncertain(deviceD))
        #expect(
            (laterTransfer.transportCommandResolutions[confirmedID]) == (.confirmed),
            "a later transfer does not drop the confirmed id")
        #expect(
            (laterTransfer.pendingCommands[.transfer]?.id) == (laterID),
            "a later transfer is the pending transfer command")
        #expect(
            (laterTransfer.pendingCommands[.transfer]?.rollbackOwner) == (Optional(remoteB)),
            "a later transfer captures confirmed B as rollback")
        #expect((laterTransfer.owner) == (PlaybackOwner.uncertain(deviceD)), "a later transfer presents D")
        let capturedLaterConfirmation = laterTransfer.transportCommandResolutions[confirmedID]
        let lateFirstFinish = PlaybackReducer.reduce(
            &laterTransfer,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker B")
                )
            )
        )
        #expect(
            (lateFirstFinish) == true,
            "a late first transfer finish after a later transfer consumes the first entry")
        #expect(
            (laterTransfer.transportCommandResolutions[confirmedID]) == nil,
            "a late first transfer finish removes the first resolution")
        #expect(
            (laterTransfer.pendingCommands[.transfer]?.id) == (laterID),
            "a late first transfer finish leaves the later command pending")
        #expect((laterTransfer.owner) == (PlaybackOwner.uncertain(deviceD)), "a late first transfer finish keeps D")
        #expect(
            (playbackCommandFollowUp(
                finishAccepted: lateFirstFinish,
                operationSucceeded: false,
                requiresReconnect: false,
                commandKind: .transfer,
                pendingCommandID: laterTransfer.pendingCommands[.transfer]?.id,
                finishedCommandResolution: capturedLaterConfirmation,
                capturedLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 1),
                isTearingDown: false
            )) == (.reportSuccess), "a late first transfer finish still reports success for the confirmed id")
        _ = PlaybackReducer.reduce(
            &laterTransfer,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: laterID, accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to Speaker D"))
            )
        )
        #expect((laterTransfer.owner) == (remoteB), "a rejected later transfer restores confirmed B")

        var localTransfer = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: ownerA
        )
        _ = PlaybackReducer.reduce(
            &localTransfer,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: localID,
                        kind: .transfer,
                        expectedTransport: nil,
                        startedAt: presentationDate
                    ))
            )
        )
        #expect((localTransfer.owner) == (ownerA), "transfer-to-this-Mac does not invent an owner target")
        #expect(
            (localTransfer.pendingCommands[.transfer]?.rollbackOwner) == nil,
            "transfer-to-this-Mac does not capture owner rollback")
        connectionOwner(&localTransfer, owner: ownerA, revision: 1)
        #expect((localTransfer.owner) == (ownerA), "transfer-to-this-Mac still adopts connection owner A")
        #expect(
            (localTransfer.pendingCommands[.transfer]?.id) == (localID),
            "a lagging A snapshot does not confirm a local transfer")
        _ = PlaybackReducer.reduce(
            &localTransfer,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: localID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not move playback to this Mac")
                )
            )
        )
        #expect((localTransfer.owner) == (ownerA), "a rejected local transfer leaves owner A")
    }
}

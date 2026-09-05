import Testing
import SpottyDomain
import Foundation

private let traceDate = Date(timeIntervalSince1970: 1_000_000)

private func envelope(
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
        receivedAt: traceDate,
        event: event
    )
}

private func enginePlaybackEvent(
    transport: PlaybackTransportState,
    trackURI: String? = "spotify:track:current"
) -> PlaybackEvent {
    .enginePlayback(
        EnginePlaybackSnapshot(
            transport: transport,
            trackURI: trackURI,
            timing: PlaybackTiming(anchoredAt: traceDate)
        )
    )
}

private func item(
    _ suffix: String,
    occurrence: Int = 0,
    provider: String = "web-api",
    uid: String = ""
) -> PlaybackQueueItem {
    let uri = "spotify:track:\(suffix)"
    return PlaybackQueueItem(uri: uri, provider: provider, occurrence: occurrence, uid: uid)
}

private func queue(
    _ entries: [PlaybackQueueItem],
    source: PlaybackQueueSource,
    completeness: PlaybackQueueCompleteness,
    revision: UInt64,
    contextURI: String? = nil
) -> PlaybackQueueSnapshot {
    PlaybackQueueSnapshot(
        entries: entries,
        source: source,
        completeness: completeness,
        revision: revision,
        receivedAt: traceDate.addingTimeInterval(TimeInterval(revision)),
        contextURI: contextURI
    )
}

private let localComputer = PlaybackDevice(id: "local", name: "Spotty", type: "computer")
private let inactivePhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
private let activePhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
private let activeLocal = PlaybackDevice(id: "local", name: "Spotty", type: "computer", isActive: true)

@discardableResult
private func reduceDevices(
    _ state: inout PlaybackState,
    devices: [PlaybackDevice],
    localDeviceID: String? = "local",
    lastRemoteDeviceID: String? = nil,
    revision: UInt64,
    engine: UInt64 = 1,
    account: UInt64 = 1
) -> Bool {
    PlaybackReducer.reduce(
        &state,
        envelope: envelope(
            account: account,
            engine: engine,
            source: .engineDevices,
            revision: revision,
            event: .devices(
                PlaybackDeviceSnapshot(
                    devices: devices,
                    localDeviceID: localDeviceID,
                    revision: revision,
                    lastRemoteDeviceID: lastRemoteDeviceID
                ))
        )
    )
}

@Suite("Playback Reducer")
struct PlaybackReducerTests {
    @Test
    func testPlaybackReducer() {
        do {
            let remote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
            var state = PlaybackState(
                accountEpoch: 4,
                engineEpoch: 7,
                session: .ready,
                owner: .remote(remote),
                transport: .paused,
                currentTrack: CurrentTrack(uri: "spotify:track:current", title: "Current")
            )

            let beforeStaleAccount = state
            let staleAccountAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(account: 3, engine: 99, source: .account, event: .session(.failed("stale")))
            )
            #expect((!staleAccountAccepted) == true, "an old account callback is rejected")
            #expect((state) == (beforeStaleAccount), "an old account callback cannot mutate state")

            let beforeStaleEngine = state
            let staleEngineAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 4,
                    engine: 6,
                    source: .enginePlayback,
                    event: enginePlaybackEvent(transport: .playing)
                )
            )
            #expect((!staleEngineAccepted) == true, "a pre-restart engine callback is rejected")
            #expect((state) == (beforeStaleEngine), "a pre-restart engine callback cannot mutate state")

            let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 4,
                    engine: 7,
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: pendingID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
                )
            )
            #expect((state.pendingCommands[.transport]) != nil, "the characterization starts with a pending command")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 4, engine: 8, source: .engineConnection, revision: 1, event: .session(.recovering))
            )
            #expect((state.engineEpoch) == (8), "a new engine epoch is adopted")
            #expect((state.pendingCommands.isEmpty) == true, "a new engine epoch clears old pending commands")
            #expect(
                (state.sourceRevisions[.engineConnection]) == (1), "the new engine begins a fresh revision namespace")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(account: 5, engine: 1, source: .account, revision: 1, event: .session(.connecting))
            )
            #expect((state.accountEpoch) == (5), "a new account epoch is adopted")
            #expect((state.engineEpoch) == (1), "engine epochs restart within a new account")
            #expect((state.session) == (.connecting), "the new account event is applied")
            #expect((state.owner) == (.none), "a new account cannot inherit playback ownership")
            #expect((state.currentTrack) == nil, "a new account cannot inherit the prior track")
            #expect((state.pendingCommands.isEmpty) == true, "a new account cannot inherit pending commands")
        }

        do {
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            let firstAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 10,
                    event: enginePlaybackEvent(transport: .playing)
                )
            )
            #expect((firstAccepted) == true, "the first revision is accepted")
            #expect((state.sourceRevisions[.enginePlayback]) == (10), "accepted revisions are recorded")

            let afterFirst = state
            let olderAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 9,
                    event: enginePlaybackEvent(transport: .paused)
                )
            )
            #expect((!olderAccepted) == true, "an older source revision is rejected")
            #expect((state) == (afterFirst), "an older source revision changes nothing")

            let duplicateAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 10,
                    event: enginePlaybackEvent(transport: .paused)
                )
            )
            #expect((!duplicateAccepted) == true, "a duplicate source revision is rejected")
            #expect((state) == (afterFirst), "a duplicate source revision changes nothing")

            let independentAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .engineQueue, revision: 1, event: .notice(PlaybackNotice(message: "queue observed")))
            )
            #expect((independentAccepted) == true, "independent sources have independent revisions")
            #expect((state.sourceRevisions[.enginePlayback]) == (10), "the playback revision remains intact")
            #expect((state.sourceRevisions[.engineQueue]) == (1), "the queue revision is tracked separately")

            let beforeInvalidCommandResult = state
            let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            let unknownAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command, revision: 5, event: .commandFinished(id: unknownID, accepted: true, notice: nil))
            )
            #expect((!unknownAccepted) == true, "an acknowledgement for no pending command is rejected")
            #expect((state) == (beforeInvalidCommandResult), "a rejected acknowledgement is transactionally inert")

            state.devices = PlaybackDeviceSnapshot(
                devices: [PlaybackDevice(id: "new", name: "New", type: "computer")],
                localDeviceID: "new",
                revision: 8
            )
            let beforeStaleDevices = state
            let staleDevicesAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .engineDevices,
                    revision: 1,
                    event: .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "old", name: "Old", type: "computer")],
                            localDeviceID: "old",
                            revision: 7
                        ))
                )
            )
            #expect((!staleDevicesAccepted) == true, "a stale embedded device revision is rejected")
            #expect((state) == (beforeStaleDevices), "a stale device event cannot consume its envelope revision")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .account, revision: 20, event: .reset(session: .signedOut))
            )
            let afterReset = state
            let staleAfterResetAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .account, revision: 19, event: .session(.ready))
            )
            #expect((!staleAfterResetAccepted) == true, "reset retains its revision barrier")
            #expect((state) == (afterReset), "a stale pre-reset event cannot revive the session")
        }

        do {
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 4,
                    event: enginePlaybackEvent(transport: .playing)
                )
            )
            let beforeQuery = state

            #expect(
                (PlaybackReducer.accepts(
                    state,
                    accountEpoch: 1,
                    engineEpoch: 1,
                    source: .enginePlayback,
                    revision: 5
                )) == true, "a newer playback revision would be accepted")
            #expect((state) == (beforeQuery), "an acceptance query does not record the revision")

            #expect(
                (!PlaybackReducer.accepts(
                    state,
                    accountEpoch: 1,
                    engineEpoch: 1,
                    source: .enginePlayback,
                    revision: 4
                )) == true, "a duplicate playback revision would be rejected")
            #expect((state) == (beforeQuery), "a rejection query is also inert")

            #expect(
                (PlaybackReducer.accepts(
                    state,
                    accountEpoch: 1,
                    engineEpoch: 2,
                    source: .enginePlayback,
                    revision: 1
                )) == true, "a higher engine epoch opens a fresh revision namespace for the query")
            #expect((state.engineEpoch) == (1), "a higher-epoch query does not adopt the epoch")
            #expect(
                (state.sourceRevisions[.enginePlayback]) == (4),
                "a higher-epoch query does not clear recorded revisions")
        }

        do {
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            state.devices = PlaybackDeviceSnapshot(
                devices: [PlaybackDevice(id: "old", name: "Old", type: "computer")],
                localDeviceID: "old",
                revision: 8
            )

            let restartedDevicesAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    engine: 2,
                    source: .engineDevices,
                    revision: 1,
                    event: .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "restarted", name: "Restarted", type: "computer")],
                            localDeviceID: "restarted",
                            revision: 1
                        ))
                )
            )
            #expect((restartedDevicesAccepted) == true, "a new engine epoch accepts a restarted device revision")
            #expect((state.engineEpoch) == (2), "the restarted engine epoch is adopted")
            #expect((state.devices.revision) == (1), "the new engine's device snapshot replaces the prior revision")
            #expect((state.devices.localDeviceID) == ("restarted"), "the new engine's active device is adopted")
        }

        do {
            let pauseID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, transport: .playing)

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: pauseID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
                )
            )
            #expect((state.transport) == (.paused), "a pending pause updates the presentation immediately")
            #expect((state.pendingCommands[.transport]?.id) == (pauseID), "the pause command is tracked by kind")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: enginePlaybackEvent(transport: .playing)
                )
            )
            #expect((state.transport) == (.paused), "a contradictory stale snapshot cannot undo the optimistic pause")
            #expect(
                (state.pendingCommands[.transport]?.id) == (pauseID),
                "the stale contradiction does not clear the pending command")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 2,
                    event: enginePlaybackEvent(transport: .paused)
                )
            )
            #expect((state.transport) == (.paused), "a matching authoritative snapshot keeps the expected state")
            #expect(
                (state.pendingCommands[.transport]) == nil, "a matching authoritative snapshot reconciles the command")

            let afterReconcile = state
            let lateFinishAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .command, event: .commandFinished(id: pauseID, accepted: true, notice: nil))
            )
            #expect((!lateFinishAccepted) == true, "a late finish after snapshot reconciliation is rejected")
            #expect((state) == (afterReconcile), "a late finish cannot mutate already-reconciled state")

            let resumeID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: resumeID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
                )
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .command, event: .commandFinished(id: resumeID, accepted: true, notice: nil))
            )
            #expect((state.pendingCommands[.transport]) == nil, "an accepted acknowledgement clears its exact command")
            #expect((state.transport) == (.playing), "an accepted acknowledgement keeps the optimistic result")

            let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
            let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: supersededID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
                )
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: replacementID, kind: .transport, expectedTransport: .playing,
                            startedAt: traceDate.addingTimeInterval(1)))
                )
            )
            let afterReplacement = state
            let supersededAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command, event: .commandFinished(id: supersededID, accepted: true, notice: nil))
            )
            #expect((!supersededAccepted) == true, "an acknowledgement for a superseded command is rejected")
            #expect((state) == (afterReplacement), "a superseded acknowledgement cannot clear the replacement")
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command, event: .commandFinished(id: replacementID, accepted: true, notice: nil))
            )
            #expect(
                (state.pendingCommands[.transport]) == nil, "the replacement command reconciles by its own identity")

            let rejectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: rejectedID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
                )
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandFinished(
                        id: rejectedID, accepted: false, notice: PlaybackNotice(message: "Pause failed")))
            )
            #expect((state.pendingCommands[.transport]) == nil, "a rejected acknowledgement clears its command")
            #expect((state.transport) == (.playing), "a rejected acknowledgement rolls back its optimistic transport")
            #expect((state.notice?.message) == ("Pause failed"), "a rejected acknowledgement surfaces its notice")

            let recoveryID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: recoveryID,
                            kind: .transport,
                            expectedTransport: .paused,
                            startedAt: traceDate
                        ))
                )
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command, event: .commandFinished(id: recoveryID, accepted: true, notice: nil))
            )
            #expect(
                (state.notice?.message) == ("Pause failed"),
                "an accepted acknowledgement does not clear an unrelated prior notice")
            #expect((state.transport) == (.paused), "an accepted acknowledgement keeps its optimistic transport")
        }

        do {
            let optionsID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
            var state = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                options: PlaybackOptions(repeatMode: .context)
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: optionsID,
                            kind: .options,
                            expectedTransport: nil,
                            startedAt: traceDate
                        ))
                )
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 7,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: traceDate),
                            shuffle: false,
                            repeatMode: .track
                        ))
                )
            )
            #expect(
                (state.options.repeatMode) == (.track),
                "an engine snapshot can update repeat while a shuffle-less options command is pending")
            #expect(
                (state.pendingCommands[.options]?.id) == (optionsID),
                "an engine snapshot does not confirm a shuffle-less options command")
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .command,
                    event: .commandFinished(
                        id: optionsID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Could not update repeat")
                    )
                )
            )
            #expect((state.pendingCommands[.options]) == nil, "a rejected options acknowledgement clears its command")
            #expect(
                (state.options.repeatMode) == (.track),
                "a rejected options acknowledgement without expected repeat does not roll back repeat")
            #expect(
                (state.notice?.message) == ("Could not update repeat"),
                "a rejected options acknowledgement still surfaces its notice")
            #expect(
                (state.sourceRevisions[.enginePlayback]) == (7),
                "engine playback revision is recorded for identity-safe rollback")
            #expect(
                (state.options.repeatFlags) == (RepeatMode.track.flags),
                "an engine snapshot without raw flags uses the display mode flags")

            let bothTrueID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
            var flagged = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = PlaybackReducer.reduce(
                &flagged,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: traceDate),
                            shuffle: false,
                            repeatMode: .track,
                            repeatFlags: RepeatFlags(context: true, track: true)
                        ))
                )
            )
            #expect((flagged.options.repeatMode) == (.track), "a both-true snapshot still displays as track")
            #expect(
                (flagged.options.repeatFlags) == (RepeatFlags(context: true, track: true)),
                "a both-true snapshot retains the raw context bit")
            _ = PlaybackReducer.reduce(
                &flagged,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: bothTrueID,
                            kind: .options,
                            expectedTransport: nil,
                            expectedRepeatFlags: RepeatMode.off.flags,
                            startedAt: traceDate
                        ))
                )
            )
            #expect(
                (flagged.pendingCommands[.options]?.rollbackRepeatFlags) == (RepeatFlags(context: true, track: true)),
                "repeat start captures both-true raw flags")
            #expect((flagged.options.repeatFlags) == (RepeatMode.off.flags), "repeat start applies canonical off flags")
            #expect((flagged.options.repeatMode) == (RepeatMode.off), "repeat start displays off")
            _ = PlaybackReducer.reduce(
                &flagged,
                envelope: envelope(
                    source: .command,
                    event: .commandFinished(
                        id: bothTrueID, accepted: false, notice: PlaybackNotice(message: "Could not update repeat"))
                )
            )
            #expect(
                (flagged.options.repeatFlags) == (RepeatFlags(context: true, track: true)),
                "a rejected repeat finish restores captured both-true flags")
            #expect((flagged.options.repeatMode) == (.track), "a rejected repeat finish restores track display")

            var restored = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            let priorBothTrue = RepeatFlags(context: true, track: true)
            let intermediateFlags = RepeatFlags(context: false, track: true)
            let restoreID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
            _ = PlaybackReducer.reduce(
                &restored,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: traceDate),
                            shuffle: false,
                            repeatMode: .track,
                            repeatFlags: priorBothTrue
                        ))
                )
            )
            _ = PlaybackReducer.reduce(
                &restored,
                envelope: envelope(
                    source: .command,
                    event: .commandStarted(
                        PendingPlaybackCommand(
                            id: restoreID,
                            kind: .options,
                            expectedTransport: nil,
                            expectedRepeatFlags: RepeatMode.off.flags,
                            startedAt: traceDate
                        ))
                )
            )
            #expect((restored.options.repeatMode) == (.off), "optimistic both-true track → off displays off")
            _ = PlaybackReducer.reduce(
                &restored,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 2,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: traceDate),
                            shuffle: false,
                            repeatMode: .track,
                            repeatFlags: intermediateFlags
                        ))
                )
            )
            #expect((restored.options.repeatMode) == (.track), "intermediate (false, true) still displays as track")
            #expect(
                (restored.options.repeatFlags) == (intermediateFlags),
                "intermediate snapshot replaces optimistic off flags"
            )
            #expect(
                (restored.pendingCommands[.options]?.id) == (restoreID), "an intermediate snapshot does not confirm off"
            )
            #expect(
                (restored.transportCommandResolutions[restoreID]) == nil,
                "an intermediate snapshot is not confirmation or supersession")
            _ = PlaybackReducer.reduce(
                &restored,
                envelope: envelope(
                    source: .command,
                    event: .commandFinished(
                        id: restoreID,
                        accepted: false,
                        notice: PlaybackNotice(message: "Could not update repeat")
                    )
                )
            )
            #expect((restored.options.repeatMode) == (.track), "restored repeat mode is track")
            #expect(
                (restored.options.repeatFlags) == (priorBothTrue), "restored raw flags are the captured both-true pair")
            #expect(
                (RepeatTransitionPlan.planning(from: restored.options.repeatFlags, to: RepeatMode.off.flags).mutations)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: false),
                    ]), "a later track → off from restored flags plans both mutations")
            #expect(
                (RepeatTransitionPlan.planning(from: intermediateFlags, to: RepeatMode.off.flags).mutations)
                    == ([RepeatFlagMutation(flag: .track, enabled: false)]),
                "ordinary (false, true) track → off remains one mutation")
        }

        do {
            let remote = PlaybackDevice(id: "desktop", name: "Other Mac", type: "computer")
            let track = CurrentTrack(
                uri: "spotify:track:paused", title: "Paused Track", artist: "Artist", duration: 240,
                metadataSource: .connect)
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, currentTrack: track)
            let trace = TraceHarness(initialState: state) { state, event in
                _ = PlaybackReducer.reduce(&state, envelope: event)
            }
            let states = trace.replay([
                envelope(source: .engineDevices, revision: 1, event: .owner(.remote(remote))),
                envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing,
                            trackURI: track.uri,
                            timing: PlaybackTiming(position: 0, duration: track.duration, anchoredAt: traceDate)
                        ))
                ),
                envelope(
                    source: .enginePlayback,
                    revision: 2,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: track.uri,
                            timing: PlaybackTiming(position: 0, duration: track.duration, anchoredAt: traceDate)
                        ))
                ),
            ])
            state = states.last ?? state
            #expect((state.owner) == (.remote(remote)), "paused playback retains the remote owner")
            #expect((state.transport) == (.paused), "remote pause is represented as paused, not stopped")
            #expect((state.currentTrack) == (track), "remote pause retains now-playing metadata")
        }

        do {
            let pausedURI = "spotify:track:paused-remote"
            let cluster = [localComputer, inactivePhone]

            var launch = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = reduceDevices(&launch, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
            #expect((launch.owner) == (.none), "devices-first with no track is none")
            #expect(
                (launch.devices.lastRemoteDeviceID) == ("phone"),
                "the last-remote payload is stamped for later URI adoption")
            _ = PlaybackReducer.reduce(
                &launch,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: pausedURI,
                            timing: PlaybackTiming(anchoredAt: traceDate)
                        ))
                )
            )
            #expect(
                (launch.owner) == (.uncertain(inactivePhone)), "a later URI adopts the stamped last-remote candidate")
            #expect(
                (connectCommandRoute(owner: launch.owner, localDeviceID: "local"))
                    == (.remote(from: "local", to: "phone")),
                "devices-then-track stays remote-routable")
            _ = PlaybackReducer.reduce(
                &launch,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 2,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .stopped,
                            trackURI: nil,
                            timing: PlaybackTiming(anchoredAt: traceDate)
                        ))
                )
            )
            #expect((launch.owner) == (.none), "clearing the URI drops an uncertain last-remote owner")

            var missing = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = reduceDevices(&missing, devices: cluster, lastRemoteDeviceID: "missing-speaker", revision: 1)
            _ = PlaybackReducer.reduce(
                &missing,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: pausedURI,
                            timing: PlaybackTiming(position: 0, duration: 180, anchoredAt: traceDate)
                        ))
                )
            )
            #expect(
                (missing.owner) == (.uncertain(nil)), "a stale last-remote after devices-then-track is uncertain(nil)")
            #expect(
                (connectCommandRoute(owner: missing.owner, localDeviceID: "local")) == (.waitingForLocalIdentity),
                "a stale last-remote never becomes local")

            var withTrack = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                currentTrack: CurrentTrack(uri: pausedURI)
            )
            _ = reduceDevices(&withTrack, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
            #expect(
                (withTrack.owner) == (.uncertain(inactivePhone)),
                "a no-active snapshot that already has a track uses last-remote")

            var namedPrevious = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                owner: .remote(PlaybackDevice(id: "phone", name: "Old Phone", type: "smartphone")),
                currentTrack: CurrentTrack(uri: pausedURI)
            )
            _ = reduceDevices(&namedPrevious, devices: cluster, revision: 1)
            #expect(
                (namedPrevious.owner) == (.uncertain(inactivePhone)),
                "a previous remote candidate refreshes from the device list")

            var noTrack = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, owner: .remote(inactivePhone))
            _ = reduceDevices(&noTrack, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
            #expect((noTrack.owner) == (.none), "no current track clears ownership even with a last remote")

            var activeLocalState = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                currentTrack: CurrentTrack(uri: pausedURI)
            )
            _ = reduceDevices(
                &activeLocalState,
                devices: [activeLocal, inactivePhone],
                lastRemoteDeviceID: "phone",
                revision: 1
            )
            #expect(
                (activeLocalState.owner) == (.local(activeLocal)),
                "an active local device wins over last-remote fallback")

            var activeRemoteState = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = reduceDevices(
                &activeRemoteState,
                devices: [localComputer, activePhone],
                lastRemoteDeviceID: "phone",
                revision: 1
            )
            #expect((activeRemoteState.owner) == (.remote(activePhone)), "an active remote device is remote ownership")

            let connectionRemote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
            var connected = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            _ = reduceDevices(&connected, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
            _ = PlaybackReducer.reduce(
                &connected,
                envelope: envelope(
                    source: .engineConnection,
                    revision: 1,
                    event: .engineConnection(
                        EngineConnectionSnapshot(
                            session: .ready,
                            owner: .remote(connectionRemote),
                            localDeviceID: "local"
                        ))
                )
            )
            _ = PlaybackReducer.reduce(
                &connected,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 1,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: pausedURI,
                            timing: PlaybackTiming(anchoredAt: traceDate)
                        ))
                )
            )
            #expect(
                (connected.owner) == (.remote(connectionRemote)),
                "a later URI does not weaken an identified remote owner from connection")

            var gated = PlaybackState(
                accountEpoch: 4,
                engineEpoch: 7,
                session: .ready,
                owner: .none,
                currentTrack: CurrentTrack(uri: pausedURI),
                devices: PlaybackDeviceSnapshot(devices: cluster, localDeviceID: "local", revision: 3)
            )
            _ = reduceDevices(
                &gated,
                devices: cluster,
                lastRemoteDeviceID: "phone",
                revision: 4,
                engine: 7,
                account: 4
            )
            let afterAccepted = gated
            #expect(
                (!reduceDevices(
                    &gated,
                    devices: [localComputer, activePhone],
                    lastRemoteDeviceID: "phone",
                    revision: 3,
                    engine: 7,
                    account: 4
                )) == true, "a stale device revision is rejected")
            #expect((gated) == (afterAccepted), "a stale device revision is inert")
            #expect(
                (!reduceDevices(
                    &gated,
                    devices: [localComputer, activePhone],
                    lastRemoteDeviceID: "phone",
                    revision: 5,
                    engine: 6,
                    account: 4
                )) == true, "a stale engine epoch is rejected")
            #expect((gated) == (afterAccepted), "a stale engine epoch is inert")
            #expect(
                (!reduceDevices(
                    &gated,
                    devices: [localComputer, activePhone],
                    lastRemoteDeviceID: "phone",
                    revision: 5,
                    engine: 7,
                    account: 3
                )) == true, "a stale account epoch is rejected")
            #expect((gated) == (afterAccepted), "a stale account epoch is inert")
        }

        do {
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .connecting)
            let remote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .engineConnection,
                    revision: 10,
                    event: .engineConnection(
                        EngineConnectionSnapshot(
                            session: .ready,
                            owner: .remote(remote),
                            localDeviceID: "spotty"
                        ))
                )
            )
            #expect((state.session) == (.ready), "connection snapshot changes session and owner together")
            #expect((state.owner) == (.remote(remote)), "connection snapshot owns the remote device")
            #expect((state.devices.localDeviceID) == ("spotty"), "connection snapshot carries the local route identity")

            let timing = PlaybackTiming(position: 42, duration: 180, anchoredAt: traceDate)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 20,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .paused,
                            trackURI: "spotify:track:atomic",
                            timing: timing,
                            shuffle: true,
                            repeatMode: .context
                        ))
                )
            )
            #expect((state.currentTrack?.uri) == ("spotify:track:atomic"), "one playback event installs track identity")
            #expect((state.transport) == (.paused), "one playback event installs transport")
            #expect((state.timing) == (timing), "one playback event installs timing")
            #expect((state.options.shuffle) == (true), "one playback event installs shuffle")
            #expect((state.options.repeatMode) == (.context), "one playback event installs repeat")

            let afterFresh = state
            let staleAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .enginePlayback,
                    revision: 19,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing,
                            trackURI: "spotify:track:stale",
                            timing: PlaybackTiming(position: 0, duration: 1, anchoredAt: traceDate),
                            shuffle: false,
                            repeatMode: .off
                        ))
                )
            )
            #expect((!staleAccepted) == true, "a stale atomic snapshot is rejected as one unit")
            #expect((state) == (afterFresh), "a stale atomic snapshot cannot partially mutate state")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .engineDevices,
                    revision: 30,
                    event: .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")],
                            localDeviceID: "spotty",
                            revision: 30
                        ))
                )
            )
            #expect(
                (state.owner) == (.uncertain(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"))),
                "an inactive paused device becomes an explicit uncertain candidate")
        }

        do {
            let oldTrack = CurrentTrack(
                uri: "spotify:track:old",
                title: "Old title",
                artist: "Old artist",
                duration: 100,
                metadataSource: .catalog
            )
            var state = PlaybackState(
                accountEpoch: 1,
                engineEpoch: 1,
                session: .ready,
                transport: .playing,
                currentTrack: oldTrack,
                timing: PlaybackTiming(position: 90, duration: 100, anchoredAt: traceDate)
            )
            let newTrack = CurrentTrack(
                uri: "spotify:track:new",
                title: "New title",
                artist: "New artist",
                duration: 240,
                metadataSource: .catalog
            )
            let newTiming = PlaybackTiming(position: 0, duration: 240, anchoredAt: traceDate)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .user,
                    event: .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: newTrack,
                            transport: .paused,
                            timing: newTiming
                        ))
                )
            )
            #expect((state.currentTrack) == (newTrack), "one presentation event installs the complete track")
            #expect((state.transport) == (.paused), "one presentation event installs transport")
            #expect((state.timing) == (newTiming), "one presentation event installs timing")

            let beforeStaleMetadata = state
            let staleAccepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .metadata,
                    event: .trackMetadata(
                        PlaybackTrackMetadata(
                            uri: oldTrack.uri,
                            title: "Stale",
                            artist: "Stale",
                            artworkURL: nil,
                            duration: 1,
                            source: .connect
                        ))
                )
            )
            #expect((!staleAccepted) == true, "metadata for a previous track is rejected")
            #expect((state) == (beforeStaleMetadata), "rejected metadata is transactionally inert")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    source: .metadata,
                    event: .trackMetadata(
                        PlaybackTrackMetadata(
                            uri: newTrack.uri,
                            title: "Resolved",
                            artist: "Resolved artist",
                            artworkURL: URL(string: "https://example.com/art.jpg"),
                            duration: 245,
                            source: .connect
                        ))
                )
            )
            #expect((state.currentTrack?.title) == ("Resolved"), "metadata fields arrive as one coherent value")
            #expect((state.currentTrack?.metadataSource) == (.connect), "metadata provenance is retained")
            #expect((state.timing.duration) == (245), "metadata duration updates playback timing atomically")

            let beforeStaleMetadataAccount = state
            let staleMetadataAccount = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 0,
                    source: .metadata,
                    event: .trackMetadata(
                        PlaybackTrackMetadata(
                            uri: newTrack.uri,
                            title: "Late",
                            artist: "Late",
                            artworkURL: nil,
                            duration: 1,
                            source: .connect
                        ))
                )
            )
            #expect((!staleMetadataAccount) == true, "metadata from a previous account is rejected")
            #expect((state) == (beforeStaleMetadataAccount), "stale-account metadata is inert")

            let beforeStaleMetadataEngine = state
            let staleMetadataEngine = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    engine: 0,
                    source: .metadata,
                    event: .trackMetadata(
                        PlaybackTrackMetadata(
                            uri: newTrack.uri,
                            title: "Late engine",
                            artist: "Late engine",
                            artworkURL: nil,
                            duration: 1,
                            source: .connect
                        ))
                )
            )
            #expect((!staleMetadataEngine) == true, "metadata from a previous engine is rejected")
            #expect((state) == (beforeStaleMetadataEngine), "stale-engine metadata is inert")
        }

        do {
            var state = PlaybackState(
                accountEpoch: 2,
                engineEpoch: 3,
                session: .ready,
                transport: .playing,
                currentTrack: CurrentTrack(uri: "spotify:track:now", title: "Now", metadataSource: .catalog),
                timing: PlaybackTiming(position: 10, duration: 200, anchoredAt: traceDate)
            )

            let accepted = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2,
                    engine: 3,
                    source: .user,
                    event: .timing(position: 42, duration: 200, anchoredAt: traceDate)
                )
            )
            #expect((accepted) == true, "a same-lifetime position refresh is accepted")
            #expect((state.timing.position) == (42), "accepted timing replaces the anchored position")

            let beforeStaleAccount = state
            let staleAccount = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 1,
                    engine: 3,
                    source: .user,
                    event: .timing(position: 99, duration: 200, anchoredAt: traceDate)
                )
            )
            #expect((!staleAccount) == true, "a stale-account position refresh is rejected")
            #expect((state) == (beforeStaleAccount), "a stale-account position refresh is inert")

            let beforeStaleEngine = state
            let staleEngine = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2,
                    engine: 2,
                    source: .user,
                    event: .timing(position: 99, duration: 200, anchoredAt: traceDate)
                )
            )
            #expect((!staleEngine) == true, "a stale-engine position refresh is rejected")
            #expect((state) == (beforeStaleEngine), "a stale-engine position refresh is inert")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2,
                    engine: 3,
                    source: .user,
                    event: .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: state.currentTrack,
                            transport: .paused,
                            timing: state.timing
                        ))
                )
            )
            #expect((state.timing.anchoredAt) == (traceDate), "pause transport keeps the existing timing anchor")

            let seekAt = traceDate.addingTimeInterval(30)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2,
                    engine: 3,
                    source: .user,
                    event: .timing(position: 80, duration: 200, anchoredAt: seekAt)
                )
            )
            #expect((state.timing.anchoredAt) == (seekAt), "seek replaces the pause anchor")

            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2,
                    engine: 3,
                    source: .enginePlayback,
                    revision: 7,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing,
                            trackURI: "spotify:track:now",
                            timing: PlaybackTiming(
                                position: 81, duration: 200, anchoredAt: seekAt.addingTimeInterval(1))
                        ))
                )
            )
            #expect(
                (state.timing.anchoredAt) == (seekAt.addingTimeInterval(1)),
                "engine timing uses the snapshot anchor, not the source revision")
            #expect(
                (state.sourceRevisions[.enginePlayback]) == (7),
                "engine playback records the backend revision separately")
        }

        do {
            var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
            let provisionalEmpty = queue([], source: .provisional, completeness: .partial, revision: 100)
            let exact = queue([item("a"), item("b")], source: .webAPI, completeness: .complete, revision: 1)

            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 1, event: .queue(provisionalEmpty)))
            #expect((state.queue.entries.isEmpty) == true, "a first provisional empty queue can characterize absence")
            #expect((state.queue.source) == (.provisional), "the provisional source remains explicit")

            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 2, event: .queue(exact)))
            #expect((state.queue) == (exact), "an exact queue outranks a higher-revision provisional queue")

            let laterProvisionalEmpty = queue([], source: .provisional, completeness: .complete, revision: 999)
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 3, event: .queue(laterProvisionalEmpty)))
            #expect((state.queue) == (exact), "a later provisional empty cannot erase an exact queue")

            let connectQueue = queue(
                [item("connect", occurrence: 4, provider: "queue", uid: "occ-connect")],
                source: .connect,
                completeness: .complete,
                revision: 2
            )
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 4, event: .queue(connectQueue)))
            #expect(
                (state.queue.entries.map(\.uri)) == (connectQueue.entries.map(\.uri)),
                "a complete Connect snapshot owns occurrence order over Web API")
            #expect((state.queue.source) == (.connect), "Connect remains the ordering source")
            #expect((state.queue.entries.first?.occurrence) == (4), "Connect keeps its typed occurrence")
            #expect((state.queue.entries.first?.uid) == ("occ-connect"), "Connect keeps its occurrence uid")

            let webReorder = queue(
                [item("c"), item("a")],
                source: .webAPI,
                completeness: .complete,
                revision: 50
            )
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 5, event: .queue(webReorder)))
            #expect(
                (state.queue.entries.map(\.uri)) == (connectQueue.entries.map(\.uri)),
                "a same-context Web refresh cannot reorder complete Connect occurrences")
            #expect((state.queue.source) == (.connect), "Web refresh does not take ownership of Connect order")
            #expect(
                (state.queue.entries.first?.occurrence) == (4), "Web refresh does not replace Connect typed occurrence")
            #expect(
                (state.queue.entries.first?.uid) == ("occ-connect"),
                "Web refresh does not replace Connect occurrence uid")
            #expect(
                (state.queue.revision) == (connectQueue.revision),
                "a high-revision Web refresh does not overwrite the Connect ordering revision")
            #expect(
                (state.queue.receivedAt) == (connectQueue.receivedAt),
                "a high-revision Web refresh does not overwrite Connect receivedAt")

            let exactNewer = queue([item("c")], source: .webAPI, completeness: .complete, revision: 2)
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 6, event: .queue(exactNewer)))
            #expect(
                (state.queue.entries.map(\.uri)) == (connectQueue.entries.map(\.uri)),
                "a newer Web snapshot still cannot replace complete Connect order")

            let exactStale = queue([item("stale")], source: .connect, completeness: .complete, revision: 1)
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 7, event: .queue(exactStale)))
            #expect(
                (state.queue.entries.map(\.uri)) == (connectQueue.entries.map(\.uri)),
                "an older Connect queue-source revision is ignored")

            let lowerCompleteness = queue([], source: .connect, completeness: .metadataOnly, revision: 2)
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 8, event: .queue(lowerCompleteness)))
            #expect(
                (state.queue.entries.map(\.uri)) == (connectQueue.entries.map(\.uri)),
                "equal-revision metadata cannot downgrade an exact URI queue")

            let duplicates = queue(
                [
                    item("same", occurrence: 0, provider: "queue"), item("same", occurrence: 1, provider: "queue"),
                    item("tail", occurrence: 2, provider: "queue"),
                ],
                source: .connect,
                completeness: .complete,
                revision: 3
            )
            _ = PlaybackReducer.reduce(
                &state, envelope: envelope(source: .engineQueue, revision: 9, event: .queue(duplicates)))
            #expect(
                (state.queue.entries.map(\.uri))
                    == (["spotify:track:same", "spotify:track:same", "spotify:track:tail"]),
                "duplicate queue uris preserve source order")
            #expect((state.queue.revision) == (3), "the later Connect occurrence list keeps its own revision")
            #expect(
                (state.queue.entries.map(\.occurrence)) == ([0, 1, 2]),
                "duplicate queue rows retain typed occurrence order"
            )
            let duplicateIDs = state.queue.entries.map(\.id)
            #expect(
                (duplicateIDs.count == 3 && Set(duplicateIDs).count == duplicateIDs.count) == true,
                "duplicate queue occurrences retain distinct identities")

            var newContext = queue(
                [item("new-context", provider: "queue")],
                source: .connect,
                completeness: .complete,
                revision: 1,
                contextURI: "spotify:track:new"
            )
            newContext.receivedAt = traceDate.addingTimeInterval(100)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .engineQueue, revision: 10, event: .queue(newContext))
            )
            #expect((state.queue) == (newContext), "a new playback context resets old Web queue precedence")

            var olderOtherContext = queue(
                [item("late-old")],
                source: .webAPI,
                completeness: .complete,
                revision: 99,
                contextURI: "spotify:track:old"
            )
            olderOtherContext.receivedAt = newContext.receivedAt.addingTimeInterval(-1)
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(source: .engineQueue, revision: 11, event: .queue(olderOtherContext))
            )
            #expect((state.queue) == (newContext), "an older queue from another context cannot return late")

            let beforeStaleAccountQueue = state
            let staleAccountQueue = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 0,
                    source: .engineQueue,
                    revision: 12,
                    event: .queue(
                        queue([item("stale-account")], source: .webAPI, completeness: .complete, revision: 100))
                )
            )
            #expect((!staleAccountQueue) == true, "a stale-account queue snapshot is rejected")
            #expect((state) == (beforeStaleAccountQueue), "a stale-account queue snapshot is inert")

            let beforeStaleEngineQueue = state
            let staleEngineQueue = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    engine: 0,
                    source: .engineQueue,
                    revision: 12,
                    event: .queue(
                        queue([item("stale-engine")], source: .webAPI, completeness: .complete, revision: 100))
                )
            )
            #expect((!staleEngineQueue) == true, "a stale-engine queue snapshot is rejected")
            #expect((state) == (beforeStaleEngineQueue), "a stale-engine queue snapshot is inert")
        }

        do {
            let command = PendingPlaybackCommand(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                kind: .transport,
                expectedTransport: .paused,
                startedAt: traceDate
            )
            var state = PlaybackState(
                accountEpoch: 2,
                engineEpoch: 3,
                session: .ready,
                owner: .remote(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")),
                transport: .playing,
                currentTrack: CurrentTrack(uri: "spotify:track:old"),
                timing: PlaybackTiming(position: 80, duration: 200, anchoredAt: traceDate),
                options: PlaybackOptions(shuffle: true, repeatMode: .track),
                queue: queue([item("old")], source: .webAPI, completeness: .complete, revision: 9),
                devices: PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")], localDeviceID: "local",
                    revision: 4),
                pendingCommands: [.transport: command],
                notice: PlaybackNotice(message: "Old notice"),
                sourceRevisions: [.enginePlayback: 50]
            )
            _ = PlaybackReducer.reduce(
                &state,
                envelope: envelope(
                    account: 2, engine: 3, source: .account, revision: 2, event: .reset(session: .signedOut))
            )
            #expect((state.accountEpoch) == (2), "reset keeps the current account epoch")
            #expect((state.engineEpoch) == (3), "reset keeps the current engine epoch")
            #expect((state.session) == (.signedOut), "reset installs the requested session phase")
            #expect((state.owner) == (.none), "reset clears ownership")
            #expect((state.transport) == (.stopped), "reset stops transport")
            #expect((state.currentTrack) == nil, "reset clears the current track")
            #expect((state.timing.position) == (0), "reset clears timing")
            #expect((state.queue.entries.isEmpty) == true, "reset clears the queue")
            #expect((state.devices.devices.isEmpty) == true, "reset clears devices")
            #expect((state.pendingCommands.isEmpty) == true, "reset clears every pending command")
            #expect((state.notice) == nil, "reset clears notices")
            #expect((state.sourceRevisions) == ([.account: 2]), "reset retains only its own revision barrier")
        }
    }
}

@Test func queuePlaylistContextFollowsAcceptedPlayback() {
    var state = PlaybackState(accountEpoch: 1)
    func event(_ context: String?, trackURI: String? = "spotify:track:current") -> PlaybackEvent {
        .enginePlayback(
            EnginePlaybackSnapshot(
                transport: .paused, trackURI: trackURI,
                timing: PlaybackTiming(anchoredAt: traceDate), contextURI: context
            ))
    }
    #expect(
        PlaybackReducer.reduce(
            &state, envelope: envelope(source: .enginePlayback, revision: 2, event: event("spotify:playlist:one"))))
    #expect(state.playbackContextURI == "spotify:playlist:one")
    #expect(
        !PlaybackReducer.reduce(
            &state, envelope: envelope(source: .enginePlayback, revision: 1, event: event("spotify:playlist:stale"))))
    #expect(state.playbackContextURI == "spotify:playlist:one")
    #expect(PlaybackReducer.reduce(&state, envelope: envelope(source: .enginePlayback, revision: 3, event: event(nil))))
    #expect(state.playbackContextURI == "spotify:playlist:one", "local timing samples omit context")
    #expect(PlaybackReducer.reduce(&state, envelope: envelope(source: .enginePlayback, revision: 4, event: event(""))))
    #expect(state.playbackContextURI == nil, "an explicit empty remote context clears the playlist link")
    #expect(
        PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .enginePlayback, revision: 5,
                event: event("spotify:playlist:two", trackURI: nil))))
    #expect(state.playbackContextURI == "spotify:playlist:two")
    #expect(
        PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .enginePlayback, revision: 6,
                event: event(nil, trackURI: nil))))
    #expect(state.playbackContextURI == "spotify:playlist:two", "trackless samples cannot clear omitted context")

}

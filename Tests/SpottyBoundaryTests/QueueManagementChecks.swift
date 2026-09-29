@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyEngineAdapter
@testable import SpottySessionRuntime
import SpottyRuntimeContracts

@MainActor
private func seedReady(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
}

@MainActor
private func seedRemoteOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [
                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                ],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedLocalOwner(_ player: PlaybackStore) {
    player.withRuntime { seedLocalOwner($0) }
}

@SessionRuntimeActor
private func seedLocalOwner(_ player: PlaybackSessionRuntime) {
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .owner(.local(PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedAuthoritativeQueue(_ player: PlaybackStore, revision: UInt64 = 4) async {
    let duplicate = "spotify:track:dup"
    let other = "spotify:track:other"
    let entries = [
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 0, uid: "q0"),
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 1, uid: "q1"),
        QueueEntry(uri: other, provider: "queue", occurrence: 2, uid: "q2"),
    ]
    let next = [
        QueueProtocolTrack(uri: duplicate, uid: "q0", provider: "queue"),
        QueueProtocolTrack(uri: duplicate, uid: "q1", provider: "queue"),
        QueueProtocolTrack(uri: other, uid: "q2", provider: "queue"),
        QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
        QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "a0", provider: "autoplay"),
    ]
    let prev = [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")]
    await player.queueService.reset(accountEpoch: player.accountEpoch)
    if let accepted = await player.queueService.acceptConnect(
        HarnessFixtures.queueState(
            revision: revision,
            generation: player.engineGeneration,
            trackURI: "spotify:track:now",
            next: next,
            prev: prev,
            queueRevision: "rev-\(revision)"),
        accountEpoch: player.accountEpoch, fallbackTrackURI: nil)
    {
        player.queueMutation = accepted.mutation
    }
    _ = player.send(
        .queue(
            PlaybackQueueSnapshot(
                entries: entries,
                source: .connect,
                completeness: .complete,
                revision: revision,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                contextURI: "spotify:track:now"
            )),
        source: .engineQueue,
        revision: revision,
        engineEpoch: player.engineGeneration,
        accountEpoch: player.accountEpoch
    )
}

@MainActor
private func yieldPasses(_ count: Int = 8) async {
    for _ in 0..<count { await Task.yield() }
}

@MainActor
private func invokeKeyboardQueueDelete(player: PlaybackStore, selectedIDs: Set<String>) {
    let selectedCount = QueueMutationSelection.orderedUpcoming(
        selectedIDs: selectedIDs,
        in: player.queueNextEntries
    ).count
    guard
        QueueMutationSelection.keyboardCommand(
            deleteOrBackspace: true,
            selectedUpcomingCount: selectedCount,
            isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: selectedIDs)
        ) == .removeUpcomingOccurrences
    else {
        return
    }
    player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
}

private func connectQueueEnvelope(
    sequence: UInt64,
    revision: UInt64,
    sessionGeneration: UInt64
) -> RustPlaybackEventEnvelope {
    RustPlaybackEventEnvelope(
        sequence: sequence,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
        event: .queue(connectQueueState(revision: revision, sessionGeneration: sessionGeneration))
    )
}

private func connectQueueState(revision: UInt64, sessionGeneration: UInt64) -> RustQueueState {
    let next = [
        ("spotify:track:dup", "q0"),
        ("spotify:track:other", "q2"),
    ]
    return RustQueueState(
        revision: revision,
        sessionGeneration: sessionGeneration,
        track: RustQueueState.Item(
            uri: "spotify:track:now",
            provider: "context",
            uid: "occ-now"
        ),
        protocolNextTracks: next.map {
            QueueProtocolTrack(uri: $0.0, uid: $0.1, provider: "queue")
        },
        protocolPrevTracks: [],
        queueRevision: "rev-\(revision)",
        disallowSetQueue: false,
        disallowRemovingFromNextTracks: false
    )
}

private final class SplitQueueDeadlineClock: PlaybackClock, @unchecked Sendable {
    let first = HarnessClock.parked()
    let later = HarnessClock.parked()
    private let lock = NSLock()
    private var firstDeadlineAvailable = true

    func now() -> Date { first.now() }
    func sleep(seconds: TimeInterval) async throws {
        let useFirst = lock.withLock {
            guard seconds == 8, firstDeadlineAvailable else { return false }
            firstDeadlineAvailable = false
            return true
        }
        try await (useFirst ? first : later).sleep(seconds: seconds)
    }
}

@Suite("Queue Management")
struct QueueManagementTests {
    enum HistoryRetirement: CaseIterable {
        case none, beforeObservation, afterObservation
    }

    @Test @MainActor
    func observationTimeoutDoesNotCancelRemainingBatchDispatch() async throws {
        let clock = SplitQueueDeadlineClock()
        let remote = HarnessRemote(send: .park)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: clock),
            feedback: TransientFeedbackPresenter(clock: clock))
        defer {
            player.effects.cancelAccountScoped()
            _ = remote.completePark(success: false)
            clock.first.releaseAll()
            clock.later.releaseAll()
        }
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        player.addToQueue(uris: ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
        try await requireEventually { remote.sendCount == 1 && remote.parkedSendCount == 1 }
        let firstID = player.state.intents.last!.command.id
        #expect(await waitUntil { clock.first.waiterCount == 1 })
        remote.completePark(success: true)
        try await requireEventually { remote.sendCount == 2 && remote.parkedSendCount == 1 }
        let firstDeadline = player.effects.settlement(of: .commandDeadline(firstID))
        clock.first.releaseAll()
        await firstDeadline?.wait()
        #expect(player.state.intents.first?.outcome == .timedOut)
        remote.completePark(success: true)
        try await requireEventually { remote.sendCount == 3 && remote.parkedSendCount == 1 }
        remote.completePark(success: true)
        #expect(await waitUntil { player.feedback.message?.text == "Queue requests sent for 3 songs" })
        await player.shutdownForTermination()
    }

    @Test @MainActor
    func ambiguousEarlierAppendCannotDonateItsOccurrenceToAnOverlappingRequest() async throws {
        let clock = HarnessClock.parked()
        let remote = HarnessRemote(send: .park)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: clock),
            feedback: TransientFeedbackPresenter(clock: clock))
        defer {
            player.effects.cancelAccountScoped()
            _ = remote.completePark(success: false)
            clock.releaseAll()
        }
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let uri = "spotify:track:new"
        player.addToQueue(uris: [uri])
        try await requireEventually { remote.sendCount == 1 && remote.parkedSendCount == 1 }
        player.addToQueue(uris: [uri])
        #expect(await waitUntil { player.state.intents.filter { $0.command.kind == .queue }.count == 2 })
        remote.completePark(success: false)
        try await requireEventually { remote.sendCount == 2 && remote.parkedSendCount == 1 }
        var observed = player.state.queue
        observed.entries.append(QueueEntry(uri: uri, provider: "queue", uid: "ambiguous"))
        observed.revision += 1
        observed.receivedAt = clock.now()
        #expect(player.send(.queue(observed), source: .engineQueue, revision: observed.revision))
        // The single occurrence could belong to the first append whose acknowledgement failed.
        #expect(player.state.intents.last?.outcome == .dispatched)
        remote.completePark(success: true)
        #expect(await waitUntil { player.state.intents.last?.outcome == .sent })
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true]) @MainActor
    func confirmedRemovalCannotHoldAdmissionAfterItsDeadline(retireHistory: Bool) async throws {
        let clock = HarnessClock.parked()
        let remote = HarnessRemote(send: .park)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: clock),
            feedback: TransientFeedbackPresenter(clock: clock))
        defer {
            player.effects.cancelAccountScoped()
            _ = remote.completePark(success: false)
            clock.releaseAll()
        }
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        player.removeUpcomingQueueOccurrences(selectedIDs: [player.queueNextEntries[0].id])
        try await requireEventually { remote.sendCount == 1 && remote.parkedSendCount == 1 }
        let id = try #require(player.state.intents.last?.command.id)
        let deadline = try #require(player.effects.settlement(of: .commandDeadline(id)))
        var observed = player.state.queue
        observed.entries.removeFirst()
        observed.revision += 1
        observed.receivedAt = clock.now()
        #expect(player.send(.queue(observed), source: .engineQueue, revision: observed.revision))
        #expect(player.state.intents.last?.outcome == .observedConfirmed)
        if retireHistory { player.withRuntime { fillPlaybackIntentHistory($0) } }
        #expect(await waitUntil { clock.waiterCount > 0 })
        clock.releaseAll()
        await deadline.wait()
        #expect(player.queueReplacementToken == nil)
        #expect(
            player.state.intents.first { $0.command.id == id }?.outcome == (retireHistory ? nil : .observedConfirmed))
        #expect(player.state.transportCommandResolutions[id] == nil)
        #expect(player.feedback.message == nil)
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true], HistoryRetirement.allCases) @MainActor
    func observedQueueChangeSurvivesLateTransportFailure(removal: Bool, retirement: HistoryRetirement) async throws {
        let clock = HarnessClock.parked()
        let remote = HarnessRemote(send: .park)
        let feedback = TransientFeedbackPresenter(clock: clock)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: clock),
            feedback: feedback)
        defer {
            player.effects.cancelAccountScoped()
            _ = remote.completePark(success: false)
            clock.releaseAll()
        }
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        var observed = player.state.queue
        let addedURI = "spotify:track:added"
        if removal {
            player.removeUpcomingQueueOccurrences(selectedIDs: [player.queueNextEntries[0].id])
            observed.entries.removeFirst()
        } else {
            player.addToQueue(uris: [addedURI])
            observed.entries.append(QueueEntry(uri: addedURI, provider: "queue", uid: "added"))
        }
        try await requireEventually { remote.sendCount == 1 && remote.parkedSendCount == 1 }
        let id = try #require(player.state.intents.last?.command.id)
        let worker = try #require(
            player.effects.settlements().first {
                if removal { return $0.key == .queueReplacement }
                if case .queueCommand = $0.key { return true }
                return false
            }?.value)
        if retirement == .beforeObservation { player.withRuntime { fillPlaybackIntentHistory($0) } }
        observed.revision += 1
        observed.receivedAt = clock.now()
        #expect(player.send(.queue(observed), source: .engineQueue, revision: observed.revision))
        if retirement == .afterObservation { player.withRuntime { fillPlaybackIntentHistory($0) } }
        let expectedHistoryOutcome: PlaybackIntentOutcome? = retirement == .none ? .observedConfirmed : nil
        #expect(player.state.intents.first { $0.command.id == id }?.outcome == expectedHistoryOutcome)
        #expect(player.state.transportCommandResolutions[id] == .confirmed)
        remote.completePark(success: false)
        await worker.wait()
        #expect(feedback.message?.kind == .success)
        #expect(player.state.intents.first { $0.command.id == id }?.outcome == expectedHistoryOutcome)
        #expect(player.state.transportCommandResolutions[id] == nil)
        #expect(player.state.queue.entries == observed.entries)
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true])
    @MainActor
    func anOrderedMultiTrackAddFinishesWithoutAPlaybackNotice(useRemote: Bool) async {
        let engine = HarnessEngine()
        let remote = HarnessRemote(send: .succeed)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(engine: engine, remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        if useRemote { seedRemoteOwner(player) } else { seedLocalOwner(player) }
        let uris = ["spotify:track:one", "spotify:track:one", "spotify:track:two"]
        player.addToQueue(uris: uris)
        // Dispatch is observed before the coordinator finishes and publishes the batch result.
        #expect((await waitUntil { feedback.message != nil }) == true, "ordered add finished")
        let localURIs = engine.operations.compactMap { operation -> String? in
            if case let .addToQueue(uri) = operation { return uri }
            return nil
        }
        #expect(localURIs == (useRemote ? [] : uris))
        #expect(remote.commands.compactMap(\.track?.uri) == (useRemote ? uris : []))
        #expect(remote.commands.allSatisfy { $0.endpoint == .addToQueue })
        #expect(
            (feedback.message?.text) == ("Queue requests sent for 3 songs"), "multi-add reports a batch success")
        #expect((player.transientCommandError) == (nil), "multi-add success is not a playback notice")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func handoffSkipsQueuedAddToQueueItems() async throws {
        let parked = HarnessRemote(send: .park)
        let clock = HarnessClock.parked()
        let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: parked, clock: clock),
            feedback: feedback)
        defer {
            player.effects.cancelAccountScoped()
            _ = parked.completePark(success: false)
            clock.releaseAll()
        }
        seedRemoteOwner(player)
        player.addToQueue(uris: ["spotify:track:first", "spotify:track:second", "spotify:track:third"])
        try await requireEventually { parked.sendCount == 1 && parked.parkedSendCount == 1 }

        // The first command has crossed the dispatch boundary. Handoff must invalidate only
        // the queued permits, so the remaining URIs are not sent to the old remote target.
        seedLocalOwner(player)
        parked.completePark(success: true)
        await yieldPasses(20)
        #expect((parked.sendCount) == (1), "handoff skips queued add_to_queue items")
        #expect((feedback.message) == nil, "a skipped remainder does not report stale feedback")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func aReplacementIsAdmittedBeforeHandoffInvalidatesIt() async throws {
        let parked = HarnessRemote(send: .park)
        let clock = HarnessClock.parked()
        let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: parked, clock: clock),
            feedback: feedback)
        defer {
            player.effects.cancelAccountScoped()
            _ = parked.completePark(success: false)
            clock.releaseAll()
        }
        seedRemoteOwner(player)
        player.addToQueue(uris: ["spotify:track:blocking"])
        try await requireEventually { parked.sendCount == 1 && parked.parkedSendCount == 1 }
        await seedAuthoritativeQueue(player)
        let removalID = player.queueNextEntries[0].id
        let replacement = player.withRuntime { runtime in
            runtime.removeUpcomingQueueOccurrences(selectedIDs: [removalID])
            let settlement = runtime.effects.settlement(of: .queueReplacement)
            // A suspended remote request leaves its actor reentrant. Invalidate the replacement
            // in this admission turn, before its effect can dispatch through that same actor.
            seedLocalOwner(runtime)
            return settlement
        }
        #expect(replacement != nil, "the replacement is admitted before handoff")
        parked.completePark(success: true)
        await replacement?.wait()
        player.withRuntime { _ in }
        #expect((parked.sendCount) == (1), "stale set_queue is never dispatched after handoff")
        #expect((player.queueReplacementToken) == nil, "stale replacement releases its token")
        #expect((feedback.message) == nil, "stale replacement does not report feedback")
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true])
    @MainActor
    func aPartialAddReportsTheCommandsThatCompletedBeforeFailure(useRemote: Bool) async {
        let engine = HarnessEngine()
        let calls = HarnessCounters()
        engine.onExecute = { _ in
            calls.record("execute")
            return calls.count("execute") <= 2 ? .ok : .error
        }
        let remote = HarnessRemote(send: .failAfter(2))
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(engine: engine, remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        if useRemote { seedRemoteOwner(player) } else { seedLocalOwner(player) }
        let before = player.queueNextEntries
        player.addToQueue(uris: ["spotify:track:one", "spotify:track:two", "spotify:track:three"])
        #expect((await waitUntil { feedback.message?.kind == .informational }) == true, "partial add finished")
        #expect(remote.sendCount == (useRemote ? 3 : 0))
        #expect(engine.count(.execute) == (useRemote ? 0 : 3))
        #expect(
            (feedback.message?.text) == ("Queue requests sent for 2 of 3 songs"),
            "partial add reports completed versus requested")
        #expect((player.queueNextEntries) == (before), "partial add does not rewrite presentation")
        await player.shutdownForTermination()

        let none = HarnessRemote(send: .fail)
        let noneEngine = HarnessEngine(executeResult: .error)
        let noneFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let nonePlayer = PlaybackStore(
            environment: HarnessEnvironment.make(engine: noneEngine, remote: none, clock: HarnessClock.parked()),
            feedback: noneFeedback)
        if useRemote { seedRemoteOwner(nonePlayer) } else { seedLocalOwner(nonePlayer) }
        nonePlayer.addToQueue(uris: ["spotify:track:one", "spotify:track:two"])
        #expect((await waitUntil { noneFeedback.message?.kind == .failure }) == true, "zero-success add finished")
        #expect(none.sendCount == (useRemote ? 1 : 0))
        #expect(noneEngine.count(.execute) == (useRemote ? 0 : 1))
        #expect(
            (noneFeedback.message?.text) == ("Could not add those tracks to the queue."),
            "zero completed commands keep the batch failure message")
        await nonePlayer.shutdownForTermination()
    }

    @Test
    @MainActor
    func theQueueProjectionKeepsTypedOccurrencesAndUIDs() async {
        let remote = HarnessRemote(send: .succeed)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let secondDuplicate = player.queueNextEntries[1].id
        let before = player.queueNextEntries
        #expect((before.map(\.occurrence)) == ([0, 1, 2]), "projection keeps typed upcoming occurrences")
        #expect((before.map(\.uid)) == (["q0", "q1", "q2"]), "projection keeps occurrence uids")
        player.removeUpcomingQueueOccurrences(selectedIDs: [secondDuplicate])
        #expect(
            (await waitUntil { feedback.message?.text == "Queue removal request sent" }) == true,
            "set_queue completed and reported feedback"
        )
        #expect((remote.sendCount) == (1), "set_queue was sent")
        let command = remote.commands.first
        #expect((command?.endpoint) == (.setQueue), "removal uses set_queue")
        #expect(
            (command?.nextTracks?.map(\.uid)) == (["q0", "q2", "", "a0"]),
            "removal keeps the first duplicate occurrence")
        #expect((command?.prevTracks?.map(\.uid)) == (["p0"]), "removal preserves prev_tracks")
        #expect((player.queueNextEntries) == (before), "success does not locally rewrite presentation")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func nowPlayingRefusalAndEmptyHistorySelectionSendNothing() async {
        let remote = HarnessRemote(send: .succeed)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let upcoming = player.queueNextEntries
        #expect(
            (player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])) == true,
            "Delete is enabled for a complete remote upcoming selection")
        #expect(
            (QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 1,
                isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])
            )) == (.removeUpcomingOccurrences), "keyboard routing matches enablement")
        player.removeUpcomingQueueOccurrences(selectedIDs: ["now-playing"])
        #expect(
            (feedback.message?.text) == (QueueMutationRefusal.nowPlayingOrHistory.feedbackMessage),
            "now-playing cannot be removed")
        #expect((remote.sendCount) == (0), "now-playing refusal does not send a command")
        player.removeUpcomingQueueOccurrences(selectedIDs: Set(player.history.map(\.id)))
        #expect((remote.sendCount == 0) == true, "empty history selection is a no-op or not a mutation")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func partialProvenanceLeavesPresentationIntactForALocalOwner() async {
        let remote = HarnessRemote(send: .succeed)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let id = player.queueNextEntries[0].id
        let before = player.queueNextEntries

        player.queueMutation?.completeness = .partial
        player.removeUpcomingQueueOccurrences(selectedIDs: [id])
        #expect(
            (feedback.message?.text) == (QueueMutationRefusal.incompleteProvenance.feedbackMessage),
            "partial provenance explains and does not mutate")
        #expect((player.queueNextEntries) == (before), "partial provenance leaves presentation intact")

        player.queueMutation?.completeness = .complete
        player.queueMutation?.disallowSetQueue = true
        player.removeUpcomingQueueOccurrences(selectedIDs: [id])
        #expect(
            (feedback.message?.text) == (QueueMutationRefusal.restricted.feedbackMessage),
            "restricted snapshots explain and do not mutate")

        let localFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let local = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: localFeedback)
        seedLocalOwner(local)
        await seedAuthoritativeQueue(local)
        let localID = local.queueNextEntries[0].id
        let localBefore = local.queueNextEntries
        local.removeUpcomingQueueOccurrences(selectedIDs: [localID])
        #expect(
            (localFeedback.message?.text) == (QueueMutationRefusal.localOwnerUnsupported.feedbackMessage),
            "local owner is disabled with a typed explanation")
        #expect((remote.sendCount) == (0), "local owner does not send set_queue")
        #expect((local.queueNextEntries) == (localBefore), "local owner leaves presentation intact")
        await player.shutdownForTermination()
        await local.shutdownForTermination()
    }

    @Test
    @MainActor
    func aRejectedSetQueueDoesNotRewritePresentation() async throws {
        let failing = HarnessRemote(send: .fail)
        let failFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let rejected = PlaybackStore(
            environment: HarnessEnvironment.make(remote: failing, clock: HarnessClock.parked()),
            feedback: failFeedback)
        seedRemoteOwner(rejected)
        await seedAuthoritativeQueue(rejected)
        let rejectedID = rejected.queueNextEntries[0].id
        let rejectedBefore = rejected.queueNextEntries
        rejected.removeUpcomingQueueOccurrences(selectedIDs: [rejectedID])
        #expect((await waitUntil { failFeedback.message?.kind == .failure }) == true, "rejected set_queue finished")
        #expect((rejected.queueNextEntries) == (rejectedBefore), "rejection does not rewrite presentation")
        #expect(
            (failFeedback.message?.text) == ("Spotify couldn’t update the queue."),
            "rejection uses a typed queue failure")
        await rejected.shutdownForTermination()

        let parked = HarnessRemote(send: .park)
        let cancelFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let cancelled = PlaybackStore(
            environment: HarnessEnvironment.make(remote: parked, clock: HarnessClock.parked()),
            feedback: cancelFeedback)
        defer {
            cancelled.effects.cancelAccountScoped()
            _ = parked.completePark(success: false)
        }
        seedRemoteOwner(cancelled)
        await seedAuthoritativeQueue(cancelled)
        let cancelID = cancelled.queueNextEntries[0].id
        let cancelBefore = cancelled.queueNextEntries
        cancelled.removeUpcomingQueueOccurrences(selectedIDs: [cancelID])
        try await requireEventually { parked.sendCount == 1 && parked.parkedSendCount == 1 }
        let cancelledReplacement = cancelled.effects.settlement(of: .queueReplacement)
        cancelled.effects.cancelAccountScoped()
        _ = parked.completePark(success: false)
        await cancelledReplacement?.wait()
        #expect((cancelFeedback.message) == nil, "cancelled removal reports no mutation feedback")
        #expect((cancelled.queueNextEntries) == (cancelBefore), "cancelled removal does not locally edit")
        await cancelled.shutdownForTermination()

        let staleRemote = HarnessRemote(send: .park)
        let staleFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let stale = PlaybackStore(
            environment: HarnessEnvironment.make(remote: staleRemote, clock: HarnessClock.parked()),
            feedback: staleFeedback)
        defer {
            stale.effects.cancelAccountScoped()
            _ = staleRemote.completePark(success: false)
        }
        seedRemoteOwner(stale)
        await seedAuthoritativeQueue(stale)
        let staleID = stale.queueNextEntries[0].id
        stale.removeUpcomingQueueOccurrences(selectedIDs: [staleID])
        try await requireEventually { staleRemote.sendCount == 1 && staleRemote.parkedSendCount == 1 }
        let staleReplacement = stale.effects.settlement(of: .queueReplacement)
        stale.accountStore.advanceEpoch()
        #expect(staleRemote.completePark(success: true))
        await staleReplacement?.wait()
        #expect((staleFeedback.message) == nil, "stale-account removal reports no mutation feedback")
        await stale.shutdownForTermination()

        let missingFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let missing = PlaybackStore(
            environment: HarnessEnvironment.make(
                remote: HarnessRemote(send: .succeed), clock: HarnessClock.parked()),
            feedback: missingFeedback)
        seedRemoteOwner(missing)
        await seedAuthoritativeQueue(missing)
        let beforeMissing = missing.queueNextEntries
        missing.removeUpcomingQueueOccurrences(selectedIDs: ["0-missing-spotify:track:nope"])
        #expect(
            (missingFeedback.message?.text) == (QueueMutationRefusal.staleIdentities.feedbackMessage),
            "stale identities explain and do not mutate")
        #expect((missing.queueNextEntries) == (beforeMissing), "stale identities leave presentation intact")
        await missing.shutdownForTermination()
    }

    @Test
    @MainActor
    func aSecondInFlightRemovalDoesNotSendAnotherSetQueue() async throws {
        let parked = HarnessRemote(send: .park)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: parked, clock: HarnessClock.parked()),
            feedback: feedback)
        defer {
            player.effects.cancelAccountScoped()
            _ = parked.completePark(success: false)
        }
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let firstID = player.queueNextEntries[0].id
        let secondID = player.queueNextEntries[1].id
        let before = player.queueNextEntries
        player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
        try await requireEventually { parked.sendCount == 1 && parked.parkedSendCount == 1 }
        #expect(
            (!player.canRemoveUpcomingQueue(selectedIDs: [secondID])) == true,
            "an in-flight replacement disables further removal")
        #expect(
            (QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 1,
                isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [secondID])
            )) == nil, "keyboard Delete is gated while a replacement is in flight")
        invokeKeyboardQueueDelete(player: player, selectedIDs: [secondID])
        player.removeUpcomingQueueOccurrences(selectedIDs: [secondID])
        await yieldPasses()
        #expect((parked.sendCount) == (1), "a second in-flight removal does not send another set_queue")
        #expect((feedback.message) == nil, "a second in-flight removal does not toast")
        #expect((player.queueNextEntries) == (before), "in-flight overlap does not edit presentation")
        parked.completePark(success: true)
        #expect(
            (await waitUntil { feedback.message?.text == "Queue removal request sent" }) == true,
            "the first replacement finished")
        #expect((player.queueReplacementToken) == nil, "a finished replacement releases the in-flight gate")
        #expect(
            (player.queueMutation?.next.map(\.uid)) == (["q1", "q2", "", "a0"]),
            "committed mutation excludes the occurrence Spotify already dropped")
        #expect(
            (!player.canRemoveUpcomingQueue(selectedIDs: [firstID])) == true,
            "stale visible selection cannot remove until Connect reconciles")
        player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
        #expect(
            (feedback.message?.text) == (QueueMutationRefusal.incompleteProvenance.feedbackMessage),
            "a follow-up from the stale visible list fails closed")
        #expect((parked.sendCount) == (1), "fail-closed follow-up does not send another set_queue")
        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func closingTheInspectorDoesNotCancelSetQueue() async throws {
        let parked = HarnessRemote(send: .park)
        let replacementFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let replacement = PlaybackStore(
            environment: HarnessEnvironment.make(remote: parked, clock: HarnessClock.parked()),
            feedback: replacementFeedback
        )
        defer {
            replacement.effects.cancelAccountScoped()
            _ = parked.completePark(success: false)
        }
        seedRemoteOwner(replacement)
        await seedAuthoritativeQueue(replacement)
        let removalID = replacement.queueNextEntries[0].id
        replacement.removeUpcomingQueueOccurrences(selectedIDs: [removalID])
        try await requireEventually { parked.sendCount == 1 && parked.parkedSendCount == 1 }
        replacement.cancelQueueRefresh()
        await yieldPasses()
        #expect((parked.sendCount) == (1), "closing the inspector does not cancel set_queue")
        #expect((replacementFeedback.message) == nil, "inspector close does not toast a cancelled replacement")
        parked.completePark(success: true)
        #expect(
            (await waitUntil { replacementFeedback.message?.text == "Queue removal request sent" }) == true,
            "replacement still completes after inspector close")
        #expect(
            (replacement.queueMutation?.next.map(\.uid)) == (["q1", "q2", "", "a0"]),
            "inspector close did not drop the committed mutation")
        await replacement.shutdownForTermination()

    }

    #if DEBUG
        @Test
        @MainActor
        func closingTheInspectorDoesNotCancelConnectIntake() async throws {
            let acceptFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
            let acceptHook = QueueServiceTestHook()
            defer { acceptHook.close() }
            let accept = PlaybackStore(
                environment: HarnessEnvironment.make(
                    remote: HarnessRemote(send: .succeed), clock: HarnessClock.parked(), queueServiceHook: acceptHook),
                feedback: acceptFeedback
            )
            seedRemoteOwner(accept)
            await accept.queueService.reset(accountEpoch: accept.accountEpoch)
            await acceptHook.parkNextConnectAccept()
            accept.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 1,
                    sessionGeneration: accept.engineGeneration
                )
            )
            try await requireEventually(description: "connect accept parked before inspector close") {
                await acceptHook.connectAcceptIsParked()
            }
            accept.cancelQueueRefresh()
            await yieldPasses()
            #expect(
                (await acceptHook.connectAcceptIsParked()) == true,
                "closing the inspector does not cancel Connect intake")
            await acceptHook.resumeConnectAccept()
            #expect(
                (await waitUntil { accept.queueMutation?.next.map(\.uid) == ["q0", "q2"] }) == true,
                "Connect accept still applies after inspector close")
            await accept.shutdownForTermination()

        }
    #endif

    #if DEBUG
        @Test
        @MainActor
        func accountTeardownCancelsReplacementAndConnectIntake() async throws {
            let teardownRemote = HarnessRemote(send: .park)
            let teardownFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
            let teardownHook = QueueServiceTestHook()
            defer { teardownHook.close() }
            let teardown = PlaybackStore(
                environment: HarnessEnvironment.make(
                    remote: teardownRemote, clock: HarnessClock.parked(),
                    queueServiceHook: teardownHook),
                feedback: teardownFeedback
            )
            defer {
                teardown.effects.cancelAccountScoped()
                _ = teardownRemote.completePark(success: false)
            }
            seedRemoteOwner(teardown)
            await seedAuthoritativeQueue(teardown)
            teardown.removeUpcomingQueueOccurrences(selectedIDs: [teardown.queueNextEntries[0].id])
            try await requireEventually {
                teardownRemote.sendCount == 1 && teardownRemote.parkedSendCount == 1
            }
            await teardownHook.parkNextConnectAccept()
            teardown.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 8,
                    sessionGeneration: teardown.engineGeneration
                )
            )
            try await requireEventually(description: "teardown accept parked") {
                await teardownHook.connectAcceptIsParked()
            }
            teardown.queueMutation = nil
            teardown.effects.cancelAccountScoped()
            await yieldPasses(20)
            #expect((teardownFeedback.message) == nil, "account teardown cancels replacement feedback")
            teardownRemote.completePark(success: true)
            await yieldPasses()
            #expect(
                (teardown.queueMutation) == nil,
                "account teardown does not restore replacement mutation from a cancelled task")
            await teardown.shutdownForTermination()
        }
    #endif

    #if DEBUG
        @Test
        @MainActor
        func epochInvalidationAfterTheCommitHopDoesNotRestoreMutation() async throws {
            let remote = HarnessRemote(send: .succeed)
            let epochFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
            let epochHook = QueueServiceTestHook()
            defer { epochHook.close() }
            let epochPlayer = PlaybackStore(
                environment: HarnessEnvironment.make(
                    remote: remote, clock: HarnessClock.parked(),
                    queueServiceHook: epochHook),
                feedback: epochFeedback
            )
            seedRemoteOwner(epochPlayer)
            await seedAuthoritativeQueue(epochPlayer)
            await epochHook.parkNextCommittedReplacement()
            epochPlayer.removeUpcomingQueueOccurrences(selectedIDs: [epochPlayer.queueNextEntries[0].id])
            #expect((await waitUntil { remote.sendCount == 1 }) == true, "set_queue reached the remote")
            try await requireEventually(description: "committed replacement parked after the actor hop") {
                await epochHook.committedReplacementIsParked()
            }
            epochPlayer.accountStore.advanceEpoch()
            epochPlayer.withRuntime { runtime in
                runtime.send(
                    .session(runtime.state.session), source: .account, engineEpoch: runtime.engineGeneration &+ 1)
            }
            epochPlayer.queueMutation = nil
            await epochHook.resumeCommittedReplacement()
            await yieldPasses()
            #expect((epochPlayer.queueMutation) == nil, "epoch invalidation after commit hop does not restore mutation")
            #expect((epochFeedback.message) == nil, "epoch invalidation after commit hop does not toast success")
            await epochPlayer.shutdownForTermination()

            let cancelRemote = HarnessRemote(send: .succeed)
            let cancelFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
            let cancelHook = QueueServiceTestHook()
            defer { cancelHook.close() }
            let cancelPlayer = PlaybackStore(
                environment: HarnessEnvironment.make(
                    remote: cancelRemote, clock: HarnessClock.parked(),
                    queueServiceHook: cancelHook),
                feedback: cancelFeedback
            )
            seedRemoteOwner(cancelPlayer)
            await seedAuthoritativeQueue(cancelPlayer)
            await cancelHook.parkNextCommittedReplacement()
            cancelPlayer.removeUpcomingQueueOccurrences(selectedIDs: [cancelPlayer.queueNextEntries[0].id])
            try await requireEventually(description: "cancelled committed replacement parked") {
                await cancelHook.committedReplacementIsParked()
            }
            cancelPlayer.queueMutation = nil
            cancelPlayer.effects.cancelAccountScoped()
            await yieldPasses(20)
            #expect((cancelPlayer.queueMutation) == nil, "cancelled committed replacement does not restore mutation")
            #expect((cancelFeedback.message) == nil, "cancelled committed replacement does not toast")
            #expect(
                (cancelPlayer.queueReplacementToken) == nil,
                "cancelled committed replacement releases the in-flight gate")
            await cancelPlayer.shutdownForTermination()
        }
    #endif

    @Test
    @MainActor
    func restrictedKeyboardDeleteDoesNotSendSetQueue() async {
        let remote = HarnessRemote(send: .succeed)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let allowedID = player.queueNextEntries[0].id
        invokeKeyboardQueueDelete(player: player, selectedIDs: [allowedID])
        #expect(
            (await waitUntil { remote.sendCount == 1 }) == true, "allowed keyboard Delete sends set_queue")

        invokeKeyboardQueueDelete(player: player, selectedIDs: [])
        #expect((remote.sendCount) == (1), "empty keyboard selection does not send another command")

        player.queueMutation?.disallowSetQueue = true
        let restrictedBefore = feedback.message?.text
        invokeKeyboardQueueDelete(player: player, selectedIDs: [player.queueNextEntries[1].id])
        #expect((remote.sendCount) == (1), "restricted keyboard Delete does not send set_queue")
        #expect((feedback.message?.text) == (restrictedBefore), "restricted keyboard Delete does not toast")
        await player.shutdownForTermination()

        let localFeedback = TransientFeedbackPresenter(clock: HarnessClock.parked(), duration: 4)
        let local = PlaybackStore(
            environment: HarnessEnvironment.make(remote: remote, clock: HarnessClock.parked()),
            feedback: localFeedback)
        seedLocalOwner(local)
        await seedAuthoritativeQueue(local)
        invokeKeyboardQueueDelete(player: local, selectedIDs: [local.queueNextEntries[0].id])
        #expect((remote.sendCount) == (1), "local-owner keyboard Delete does not send set_queue")
        #expect((localFeedback.message) == nil, "local-owner keyboard Delete does not toast")
        await local.shutdownForTermination()
    }

}

/// Advance the diagnostic history through real admissions without starting unrelated I/O.
@SessionRuntimeActor
private func fillPlaybackIntentHistory(_ runtime: PlaybackSessionRuntime) {
    for _ in 0..<128 {
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
        #expect(
            runtime.send(.queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command)
        )
        #expect(runtime.send(.queueIntentFinished(id: command.id, accepted: false), source: .command))
    }
}

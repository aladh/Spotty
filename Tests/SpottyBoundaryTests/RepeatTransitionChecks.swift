import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime
import SpottyRuntimeContracts
@testable import SpottyEngineAdapter

private enum RepeatCheckFailure: Error { case boom }

private struct RepeatSend: Equatable, Sendable {
    let endpoint: SpotifyConnectCommand.Kind
    let enabled: Bool?
}

// Kept bespoke: applies `RepeatTransitionPlan` mutation-by-mutation and records the resulting
// `RepeatFlagMutation`s alongside per-mutation fail counts, which `HarnessEngine` has no concept of.
private final class RepeatLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let failAtCount: Int?
    private let compensationFails: Bool
    private var storedMutations: [RepeatFlagMutation] = []
    private var storedOperations: [LocalPlaybackOperation] = []

    init(failAtCount: Int? = nil, compensationFails: Bool = false) {
        self.failAtCount = failAtCount
        self.compensationFails = compensationFails
    }

    var mutations: [RepeatFlagMutation] {
        lock.lock()
        defer { lock.unlock() }
        return storedMutations
    }

    var operations: [LocalPlaybackOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        lock.lock()
        storedOperations.append(operation)
        lock.unlock()
        guard case let .repeatOptions(plan) = operation else {
            return .ok
        }
        let counter = RepeatMutationCounter()
        return RepeatTransitionApplication.apply(plan) { mutation in
            self.record(mutation, plan: plan, counter: counter)
        }
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    private func record(
        _ mutation: RepeatFlagMutation,
        plan: RepeatTransitionPlan,
        counter: RepeatMutationCounter
    ) -> PlaybackEngineResult {
        lock.lock()
        storedMutations.append(mutation)
        counter.value += 1
        let count = counter.value
        lock.unlock()
        if let failAtCount, count == failAtCount { return .error }
        if compensationFails, count > plan.mutations.count { return .error }
        return .ok
    }
}

private final class RepeatMutationCounter: @unchecked Sendable {
    var value = 0
}

// Kept bespoke: fails only at specific send counts and holds after a specific send count (rather
// than after every send), and records sends as `RepeatSend` (endpoint + boolean) — none of which
// `HarnessRemote`'s `SendBehavior` expresses.
private actor ScriptedRepeatRemote: RemotePlaybackClient {
    private let failAtCounts: Set<Int>
    private let sleepUntilCancelled: Bool
    private let holdAfterCount: Int?
    private var hold: CheckedContinuation<Void, Never>?
    private(set) var sends: [RepeatSend] = []
    private(set) var completedSends = 0

    init(
        failAtCounts: Set<Int> = [],
        sleepUntilCancelled: Bool = false,
        holdAfterCount: Int? = nil
    ) {
        self.failAtCounts = failAtCounts
        self.sleepUntilCancelled = sleepUntilCancelled
        self.holdAfterCount = holdAfterCount
    }

    func send(_ command: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sends.append(RepeatSend(endpoint: command.endpoint, enabled: booleanValue(command)))
        defer { completedSends += 1 }
        if sleepUntilCancelled {
            try await HarnessClock.parked().sleep(seconds: 60)
            return
        }
        if sends.count == holdAfterCount {
            await withCheckedContinuation { continuation in
                hold = continuation
            }
        }
        if failAtCounts.contains(sends.count) {
            throw RepeatCheckFailure.boom
        }
    }

    func releaseHold() {
        hold?.resume()
        hold = nil
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Metadata",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        )
    }

    private func booleanValue(_ command: SpotifyConnectCommand) -> Bool? {
        switch command.value {
        case let .boolean(enabled): enabled
        default: nil
        }
    }
}

@MainActor
private func seedReadyRemote(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
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
}

@MainActor
private func seedReadyLocal(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [
                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)
                ],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
}

@MainActor
private func sendRepeatSnapshot(
    _ player: PlaybackStore,
    mode: RepeatMode,
    flags: RepeatFlags? = nil,
    revision: UInt64
) {
    _ = player.send(
        .enginePlayback(
            EnginePlaybackSnapshot(
                transport: .paused,
                trackURI: nil,
                timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)),
                shuffle: false,
                repeatMode: mode,
                repeatFlags: flags ?? mode.flags
            )),
        source: .enginePlayback,
        revision: revision
    )
}

// Runtime command settlement and MainActor publication are independent. Rollback and notice
// checks must observe both, rather than treating the raw pending slot as a UI delivery barrier.
@MainActor
private func waitForRepeatCompletion(
    _ player: PlaybackStore,
    mode: RepeatMode,
    notice: String? = nil
) async -> Bool {
    await waitUntil {
        player.state.pendingCommands[.options] == nil
            && player.repeatMode == mode
            && player.transientCommandError == notice
    }
}

// A confirming or superseding snapshot can consume the pending slot before the held request
// returns. Retain its exact registration so late-failure assertions run after that completion.
@MainActor
private func captureRepeatCompletion(_ player: PlaybackStore) -> PlaybackEffectSettlement? {
    let completion = player.state.pendingCommands[.options].flatMap {
        player.effects.settlement(of: .command($0.id))
    }
    #expect(completion != nil, "the held repeat command has an effect registration")
    return completion
}

@Suite("Repeat Transition")
struct RepeatTransitionTests {
    @Test
    @MainActor
    func testRepeatTransition() async {
        do {
            func record(
                from: RepeatMode,
                to: RepeatMode,
                failAtCount: Int? = nil,
                compensationFails: Bool = false
            ) -> (calls: [RepeatFlagMutation], result: PlaybackEngineResult) {
                var calls: [RepeatFlagMutation] = []
                var count = 0
                let plan = RepeatTransitionPlan.planning(from: from.flags, to: to.flags)
                let result = RepeatTransitionApplication.apply(plan) { mutation in
                    count += 1
                    calls.append(mutation)
                    if count == failAtCount { return .error }
                    if compensationFails, count > plan.mutations.count { return .error }
                    return .ok
                }
                return (calls, result)
            }

            let offToContext = record(from: .off, to: .context)
            #expect(
                (offToContext.calls) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
                "local off → context sends only context on")
            #expect((offToContext.result) == (.ok), "local off → context succeeds")

            let contextToTrack = record(from: .context, to: .track)
            #expect(
                (contextToTrack.calls)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: true),
                    ]), "local context → track sends context off then track on")
            #expect((contextToTrack.result) == (.ok), "local context → track succeeds")

            let trackToOff = record(from: .track, to: .off)
            #expect(
                (trackToOff.calls) == ([RepeatFlagMutation(flag: .track, enabled: false)]),
                "local track → off sends only track off")
            #expect((trackToOff.result) == (.ok), "local track → off succeeds")

            let firstStep = record(from: .off, to: .context, failAtCount: 1)
            #expect(
                (firstStep.calls) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
                "local first-step failure performs no compensation")
            #expect((firstStep.result) == (.error), "local first-step failure is an error")

            let secondStep = record(from: .context, to: .track, failAtCount: 2)
            #expect(
                (secondStep.calls)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: true),
                        RepeatFlagMutation(flag: .context, enabled: true),
                    ]), "local second-step failure attempts compensation")
            #expect((secondStep.result) == (.error), "local second-step failure remains an error")

            let compensationFailure = record(from: .context, to: .track, failAtCount: 2, compensationFails: true)
            #expect(
                (compensationFailure.calls)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: true),
                        RepeatFlagMutation(flag: .context, enabled: true),
                    ]), "local compensation failure still records the rollback attempt")
            #expect((compensationFailure.result) == (.error), "local compensation failure does not claim success")
        }

        do {
            struct Case: Sendable {
                let from: RepeatMode
                let expected: [RepeatSend]
                let label: String
            }
            let cases: [Case] = [
                Case(
                    from: .off,
                    expected: [RepeatSend(endpoint: .repeatContext, enabled: true)],
                    label: "off → context"
                ),
                Case(
                    from: .context,
                    expected: [
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: true),
                    ],
                    label: "context → track"
                ),
                Case(
                    from: .track,
                    expected: [RepeatSend(endpoint: .repeatTrack, enabled: false)],
                    label: "track → off"
                ),
            ]
            for item in cases {
                let remote = ScriptedRepeatRemote()
                let player = HarnessEnvironment.makePlaybackStore(
                    HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
                )
                seedReadyRemote(player)
                player.setRepeatMode(item.from)
                player.cycleRepeat()
                let finished = await waitForRepeatCompletion(player, mode: item.from.next)
                #expect((finished) == true, "\(item.label) finishes")
                #expect((await remote.sends) == (item.expected), "\(item.label) sends")
                #expect((player.repeatMode) == (item.from.next), "\(item.label) keeps the optimistic mode")
                #expect((player.transientCommandError) == nil, "\(item.label) has no command notice")
                #expect(
                    (await remote.sends.count) == (item.expected.count),
                    "\(item.label) command count matches changed flags"
                )
                await player.shutdownForTermination()
            }
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [1])
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.cycleRepeat()
            let finished = await waitForRepeatCompletion(player, mode: .off, notice: "Could not update repeat")
            #expect((finished) == true, "first-step failure finishes")
            #expect(
                (await remote.sends) == ([RepeatSend(endpoint: .repeatContext, enabled: true)]),
                "first-step failure sends only the required mutation")
            #expect((player.repeatMode) == (RepeatMode.off), "first-step failure rolls back the optimistic mode")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "first-step failure reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [2])
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.setRepeatMode(.context)
            player.cycleRepeat()
            let finished = await waitForRepeatCompletion(player, mode: .context, notice: "Could not update repeat")
            #expect((finished) == true, "second-step failure finishes")
            #expect(
                (await remote.sends)
                    == ([
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: true),
                        RepeatSend(endpoint: .repeatContext, enabled: true),
                    ]), "second-step failure records best-effort compensation")
            #expect(
                (player.repeatMode) == (RepeatMode.context),
                "second-step failure rolls back to the captured previous mode")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "second-step failure reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [2, 3])
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.setRepeatMode(.context)
            player.cycleRepeat()
            let finished = await waitForRepeatCompletion(player, mode: .context, notice: "Could not update repeat")
            #expect((finished) == true, "compensation failure finishes")
            #expect(
                (await remote.sends)
                    == ([
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: true),
                        RepeatSend(endpoint: .repeatContext, enabled: true),
                    ]), "compensation failure still attempted the rollback send")
            #expect((player.repeatMode) == (RepeatMode.context), "compensation failure does not claim success")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "compensation failure reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let local = RepeatLocalEngine(failAtCount: 2)
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: local, remote: ScriptedRepeatRemote())
            )
            seedReadyLocal(player)
            player.setRepeatMode(.context)
            player.cycleRepeat()
            let finished = await waitForRepeatCompletion(player, mode: .context, notice: "Could not update repeat")
            #expect((finished) == true, "local second-step failure finishes")
            #expect(
                (local.mutations)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: true),
                        RepeatFlagMutation(flag: .context, enabled: true),
                    ]), "local engine records compensation in documented order")
            #expect(
                (player.repeatMode) == (RepeatMode.context), "local second-step failure rolls back the optimistic mode")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "local second-step failure reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.cycleRepeat()
            let held = await waitUntil { await remote.sends.count == 1 }
            #expect((held) == true, "repeat send is held before failure")
            #expect((player.repeatMode) == (RepeatMode.context), "optimistic repeat is context before the snapshot")
            let completion = captureRepeatCompletion(player)
            sendRepeatSnapshot(player, mode: .context, revision: 3)
            #expect((player.repeatMode) == (RepeatMode.context), "engine snapshot keeps context repeat")
            await remote.releaseHold()
            await completion?.wait()
            let finished = await waitForRepeatCompletion(player, mode: .context)
            #expect((finished) == true, "stale failure completion arrives")
            #expect(
                (player.repeatMode) == (RepeatMode.context),
                "a later failure does not clobber the engine repeat snapshot")
            #expect((player.transientCommandError) == nil, "confirmed repeat then failure has no command notice")
            await player.shutdownForTermination()
        }

        do {
            let bothTrueRemote = ScriptedRepeatRemote()
            let bothTruePlayer = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: bothTrueRemote)
            )
            seedReadyRemote(bothTruePlayer)
            bothTruePlayer.setRepeat(mode: .track, flags: RepeatFlags(context: true, track: true))
            #expect((bothTruePlayer.repeatMode) == (RepeatMode.track), "both-true still displays as track")
            #expect(
                (bothTruePlayer.state.options.repeatFlags) == (RepeatFlags(context: true, track: true)),
                "both-true raw flags are retained on options")
            bothTruePlayer.cycleRepeat()
            let bothFinished = await waitForRepeatCompletion(bothTruePlayer, mode: .off)
            #expect((bothFinished) == true, "both-true track → off finishes")
            #expect(
                (await bothTrueRemote.sends)
                    == ([
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: false),
                    ]), "both-true track → off clears both flags")
            #expect((bothTruePlayer.repeatMode) == (RepeatMode.off), "both-true track → off shows off")
            await bothTruePlayer.shutdownForTermination()

            let ordinaryRemote = ScriptedRepeatRemote()
            let ordinaryPlayer = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: ordinaryRemote)
            )
            seedReadyRemote(ordinaryPlayer)
            ordinaryPlayer.setRepeatMode(.track)
            ordinaryPlayer.cycleRepeat()
            let ordinaryFinished = await waitForRepeatCompletion(ordinaryPlayer, mode: .off)
            #expect((ordinaryFinished) == true, "ordinary track → off finishes")
            #expect(
                (await ordinaryRemote.sends) == ([RepeatSend(endpoint: .repeatTrack, enabled: false)]),
                "ordinary track → off still sends only track off")
            await ordinaryPlayer.shutdownForTermination()
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 2)
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.setRepeatMode(.context)
            player.cycleRepeat()
            let held = await waitUntil { await remote.sends.count == 2 }
            #expect((held) == true, "second mutation is held after context-off")
            sendRepeatSnapshot(
                player,
                mode: .off,
                flags: RepeatFlags(context: false, track: false),
                revision: 4
            )
            #expect((player.repeatMode) == (RepeatMode.off), "intermediate engine sample shows off")
            await remote.releaseHold()
            let finished = await waitForRepeatCompletion(player, mode: .context, notice: "Could not update repeat")
            #expect((finished) == true, "compensated second-step failure finishes")
            #expect(
                (await remote.sends)
                    == ([
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: true),
                        RepeatSend(endpoint: .repeatContext, enabled: true),
                    ]), "compensation still ran after the intermediate off snapshot")
            #expect(
                (player.repeatMode) == (RepeatMode.context),
                "intermediate off plus successful compensation restores context UI")
            #expect(
                (player.state.options.repeatFlags) == (RepeatMode.context.flags),
                "restored context flags match the captured previous pair")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "the failed command still reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let remote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 1)
            let player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            let priorBothTrue = RepeatFlags(context: true, track: true)
            let intermediateFlags = RepeatFlags(context: false, track: true)
            player.setRepeat(mode: .track, flags: priorBothTrue)
            player.cycleRepeat()
            let held = await waitUntil { await remote.sends.count == 1 }
            #expect((held) == true, "first both-off mutation is held after context-off")
            sendRepeatSnapshot(player, mode: .track, flags: intermediateFlags, revision: 7)
            #expect((player.repeatMode) == (RepeatMode.track), "intermediate both-true step still displays as track")
            #expect(
                (player.state.options.repeatFlags) == (intermediateFlags),
                "intermediate raw flags are context off, track on")
            await remote.releaseHold()
            let finished = await waitForRepeatCompletion(player, mode: .track, notice: "Could not update repeat")
            #expect((finished) == true, "compensated both-true second-step failure finishes")
            #expect(
                (await remote.sends)
                    == ([
                        RepeatSend(endpoint: .repeatContext, enabled: false),
                        RepeatSend(endpoint: .repeatTrack, enabled: false),
                        RepeatSend(endpoint: .repeatContext, enabled: true),
                    ]), "compensation restores context after the intermediate track snapshot")
            #expect((player.repeatMode) == (RepeatMode.track), "store restored previous track after compensation")
            #expect(
                (player.state.options.repeatFlags) == (priorBothTrue), "store restored captured both-true raw flags")
            #expect(
                (RepeatTransitionPlan.planning(from: player.state.options.repeatFlags, to: RepeatMode.off.flags)
                    .mutations)
                    == ([
                        RepeatFlagMutation(flag: .context, enabled: false),
                        RepeatFlagMutation(flag: .track, enabled: false),
                    ]), "a later track → off from restored flags plans both mutations")
            #expect(
                (player.transientCommandError) == ("Could not update repeat"),
                "the failed command still reports Could not update repeat")
            await player.shutdownForTermination()
        }

        do {
            let targetRemote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 2)
            let targetPlayer = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: targetRemote)
            )
            seedReadyRemote(targetPlayer)
            targetPlayer.setRepeatMode(.context)
            targetPlayer.cycleRepeat()
            let targetHeld = await waitUntil { await targetRemote.sends.count == 2 }
            #expect((targetHeld) == true, "target snapshot is injected before second-step failure")
            let targetCompletion = captureRepeatCompletion(targetPlayer)
            sendRepeatSnapshot(targetPlayer, mode: .track, revision: 5)
            await targetRemote.releaseHold()
            await targetCompletion?.wait()
            let targetFinished = await waitForRepeatCompletion(targetPlayer, mode: .track)
            #expect((targetFinished) == true, "target snapshot failure finishes")
            #expect((targetPlayer.repeatMode) == (RepeatMode.track), "a later target track snapshot remains track")
            #expect(
                (targetPlayer.transientCommandError) == nil,
                "confirmed target repeat then failure has no command notice")
            await targetPlayer.shutdownForTermination()

            let unrelatedRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
            let unrelatedPlayer = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: unrelatedRemote)
            )
            seedReadyRemote(unrelatedPlayer)
            unrelatedPlayer.cycleRepeat()
            let unrelatedHeld = await waitUntil { await unrelatedRemote.sends.count == 1 }
            #expect((unrelatedHeld) == true, "unrelated snapshot is injected before first-step failure")
            let unrelatedCompletion = captureRepeatCompletion(unrelatedPlayer)
            sendRepeatSnapshot(unrelatedPlayer, mode: .track, revision: 6)
            await unrelatedRemote.releaseHold()
            await unrelatedCompletion?.wait()
            let unrelatedFinished = await waitForRepeatCompletion(unrelatedPlayer, mode: .track)
            #expect((unrelatedFinished) == true, "unrelated snapshot failure finishes")
            #expect(
                (unrelatedPlayer.repeatMode) == (RepeatMode.track),
                "unrelated newer authoritative track remains preserved")
            #expect((unrelatedPlayer.transientCommandError) == nil, "superseded repeat then failure stays inert")
            await unrelatedPlayer.shutdownForTermination()
        }

        do {
            let sleeping = ScriptedRepeatRemote(sleepUntilCancelled: true)
            let cancelStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: sleeping)
            )
            seedReadyRemote(cancelStore)
            cancelStore.cycleRepeat()
            let sendStarted = await waitUntil { await sleeping.sends.count == 1 }
            #expect((sendStarted) == true, "cancelled repeat send started")
            #expect(
                (cancelStore.state.pendingCommands[.options] != nil) == true,
                "remote repeat is pending before cancellation"
            )
            if let commandID = cancelStore.state.pendingCommands[.options]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancellationSettled = await waitForRepeatCompletion(cancelStore, mode: .off)
            #expect((cancellationSettled) == true, "cancelled repeat settles")
            #expect((cancelStore.repeatMode) == (RepeatMode.off), "cancelled repeat restores the captured mode")
            #expect((cancelStore.transientCommandError) == nil, "cancelled repeat has no notice")
            await cancelStore.shutdownForTermination()

            let teardownRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
            let teardownStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: teardownRemote)
            )
            seedReadyRemote(teardownStore)
            teardownStore.cycleRepeat()
            let teardownSendStarted = await waitUntil { await teardownRemote.sends.count == 1 }
            #expect((teardownSendStarted) == true, "teardown repeat send started")
            #expect((teardownStore.state.pendingCommands[.options] != nil) == true, "repeat is pending before teardown")
            await teardownStore.shutdownForTermination()
            let teardownSettled = await waitUntil { await teardownRemote.completedSends == 1 }
            #expect((teardownSettled) == true, "teardown repeat transport exits")
            #expect(
                (teardownStore.state.pendingCommands[.options]) == nil, "teardown leaves no pending options command")
            #expect((teardownStore.transientCommandError) == nil, "teardown repeat has no command notice")
        }

        do {
            let failing = RepeatLocalEngine(failAtCount: 1)
            let failed = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: failing, remote: ScriptedRepeatRemote())
            )
            seedReadyLocal(failed)
            failed.cycleRepeat()
            #expect(
                (failed.repeatMode) == (RepeatMode.context), "local off → context presents context before completion")
            let failedFinished = await waitForRepeatCompletion(failed, mode: .off, notice: "Could not update repeat")
            #expect((failedFinished) == true, "local first-step failure finishes")
            #expect(
                (failing.mutations) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
                "local first-step failure performs no compensation")
            #expect((failed.repeatMode) == (RepeatMode.off), "local first-step failure rolls back the optimistic mode")
            #expect(
                (failed.transientCommandError) == ("Could not update repeat"),
                "local first-step failure reports Could not update repeat")
            await failed.shutdownForTermination()

            let succeeding = RepeatLocalEngine()
            let accepted = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: succeeding, remote: ScriptedRepeatRemote())
            )
            seedReadyLocal(accepted)
            accepted.cycleRepeat()
            let acceptedFinished = await waitForRepeatCompletion(accepted, mode: .context)
            #expect((acceptedFinished) == true, "local off → context success finishes")
            #expect(
                (succeeding.mutations) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
                "local off → context success sends only context on")
            #expect((accepted.repeatMode) == (RepeatMode.context), "local off → context success keeps context")
            #expect((accepted.transientCommandError) == nil, "local off → context success has no command notice")
            await accepted.shutdownForTermination()
        }

        do {
            let laggingRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
            let lagging = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: laggingRemote)
            )
            seedReadyRemote(lagging)
            lagging.cycleRepeat()
            let lagHeld = await waitUntil { await laggingRemote.sends.count == 1 }
            #expect((lagHeld) == true, "lagging repeat send is held")
            sendRepeatSnapshot(lagging, mode: .off, revision: 2)
            #expect((lagging.repeatMode) == (RepeatMode.context), "a lagging off snapshot keeps optimistic context")
            #expect((lagging.state.pendingCommands[.options]) != nil, "a lagging off snapshot keeps rollback ownership")
            await laggingRemote.releaseHold()
            let lagFinished = await waitForRepeatCompletion(lagging, mode: .off, notice: "Could not update repeat")
            #expect((lagFinished) == true, "lagging prior then rejection finishes")
            #expect((lagging.repeatMode) == (RepeatMode.off), "lagging prior then rejection restores off")
            #expect(
                (lagging.transientCommandError) == ("Could not update repeat"),
                "lagging prior then rejection reports Could not update repeat")
            await lagging.shutdownForTermination()

            let userRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
            let userStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: userRemote)
            )
            seedReadyRemote(userStore)
            userStore.cycleRepeat()
            let userHeld = await waitUntil { await userRemote.sends.count == 1 }
            #expect((userHeld) == true, "user options repeat send is held")
            _ = userStore.send(
                .options(PlaybackOptions(shuffle: true, repeatMode: .context, repeatFlags: RepeatMode.context.flags)),
                source: .user
            )
            #expect(
                (userStore.repeatMode) == (RepeatMode.context), "a matching user options event keeps optimistic context"
            )
            #expect((userStore.state.options.shuffle) == (true), "a matching user options event still adopts shuffle")
            #expect(
                (userStore.state.pendingCommands[.options]) != nil,
                "a matching user options event keeps the pending repeat command")
            #expect(
                (userStore.state.transportCommandResolutions.isEmpty) == true,
                "a matching user options event does not record confirmation")
            await userRemote.releaseHold()
            let userFinished = await waitForRepeatCompletion(userStore, mode: .off, notice: "Could not update repeat")
            #expect((userFinished) == true, "user options then rejection finishes")
            #expect(
                (userStore.repeatMode) == (RepeatMode.off),
                "rejection after only a matching user options event restores off")
            await userStore.shutdownForTermination()

            let staleRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
            let staleStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: staleRemote)
            )
            seedReadyRemote(staleStore)
            staleStore.cycleRepeat()
            let stalePending = await waitUntil { staleStore.state.pendingCommands[.options] != nil }
            #expect((stalePending) == true, "repeat is pending before an engine-epoch bump")
            let optimisticRepeat = staleStore.repeatMode
            _ = staleStore.send(
                .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                revision: 1,
                engineEpoch: staleStore.engineGeneration + 1
            )
            #expect(
                (staleStore.state.pendingCommands[.options]) == nil, "an engine-epoch bump drops the pending repeat")
            #expect((staleStore.repeatMode) == (optimisticRepeat), "an engine-epoch bump does not roll back context")
            #expect(
                (staleStore.state.transportCommandResolutions.isEmpty) == true,
                "an engine-epoch bump clears repeat confirmation state")
            await staleStore.shutdownForTermination()

            let accountRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
            let accountStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: accountRemote)
            )
            seedReadyRemote(accountStore)
            accountStore.cycleRepeat()
            let accountPending = await waitUntil { accountStore.state.pendingCommands[.options] != nil }
            #expect((accountPending) == true, "repeat is pending before an account-epoch bump")
            accountStore.accountStore.advanceEpoch()
            _ = accountStore.send(
                .reset(session: .signedOut), source: .account, accountEpoch: accountStore.accountEpoch)
            #expect((accountStore.state.pendingCommands[.options]) == nil, "an account-epoch bump drops pending repeat")
            #expect((accountStore.state.session) == (PlaybackSessionPhase.signedOut), "an account-epoch bump signs out")
            #expect(
                (accountStore.repeatMode) == (RepeatMode.off), "an account-epoch bump does not keep signed-in repeat")
            await accountStore.shutdownForTermination()

            let joining = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: ScriptedRepeatRemote())
            )
            _ = joining.send(.session(.ready), source: .account)
            _ = joining.send(
                .owner(.uncertain(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
                source: .command
            )
            let joiningBefore = joining.state
            joining.cycleRepeat()
            #expect(
                (joining.state.options.repeatMode) == (joiningBefore.options.repeatMode),
                "route refusal leaves repeat unchanged")
            #expect((joining.state.pendingCommands.isEmpty) == true, "route refusal does not start a pending repeat")
            await joining.shutdownForTermination()

            let duplicateRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
            let duplicateStore = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: RepeatLocalEngine(), remote: duplicateRemote)
            )
            seedReadyRemote(duplicateStore)
            duplicateStore.cycleRepeat()
            let repeatPending = await waitUntil { duplicateStore.state.pendingCommands[.options] != nil }
            #expect((repeatPending) == true, "the first repeat is pending before a duplicate")
            let afterFirstRepeat = duplicateStore.state
            duplicateStore.cycleRepeat()
            #expect(
                (duplicateStore.state.options) == (afterFirstRepeat.options),
                "a duplicate repeat does not change options")
            #expect(
                (duplicateStore.state.pendingCommands[.options]?.id)
                    == (afterFirstRepeat.pendingCommands[.options]?.id),
                "a duplicate repeat keeps the original command")
            if let commandID = duplicateStore.state.pendingCommands[.options]?.id {
                duplicateStore.effects.cancel(.command(commandID))
            }
            await duplicateStore.shutdownForTermination()
        }

    }
}

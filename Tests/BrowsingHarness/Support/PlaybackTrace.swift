import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottySessionRuntime

struct PlaybackTraceCheckpoint: Codable, Sendable {
    let name: String
    let elapsedMilliseconds: Double
    let engineGeneration: UInt64
    let commandCount: Int
    let intentOutcome: String?
    let admissionToDispatchMilliseconds: Double?
    let admissionToSettlementMilliseconds: Double?
    let actionToStateFeedbackMilliseconds: Double?
}

/// A finite scenario through production action entry points. Conditions, not scheduler turns,
/// determine readiness; the wall deadline only turns a liveness bug into an actionable report.
@MainActor
struct PlaybackTrace {
    static func run(player: PlaybackStore, world: BrowsingWorld) async throws -> [PlaybackTraceCheckpoint] {
        var checkpoints: [PlaybackTraceCheckpoint] = []
        func checkpoint(
            _ name: String, since started: ContinuousClock.Instant,
            intent: PlaybackIntent? = nil, feedbackMilliseconds: Double? = nil
        ) {
            let elapsed = started.duration(to: .now)
            checkpoints.append(
                PlaybackTraceCheckpoint(
                    name: name,
                    elapsedMilliseconds: Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1e15,
                    engineGeneration: player.engineGeneration, commandCount: world.playback.snapshot().commandCount,
                    intentOutcome: intent.map { String(describing: $0.outcome) },
                    admissionToDispatchMilliseconds: intent.flatMap { intent in
                        intent.dispatchedAt.map { $0.timeIntervalSince(intent.command.startedAt) * 1_000 }
                    },
                    admissionToSettlementMilliseconds: intent.flatMap { intent in
                        intent.settledAt.map { $0.timeIntervalSince(intent.command.startedAt) * 1_000 }
                    },
                    actionToStateFeedbackMilliseconds: feedbackMilliseconds))
        }
        try await until("playback.ready") { player.isConnected && player.canTogglePlayback && player.duration > 0 }
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        }
        var started = ContinuousClock.now
        player.togglePlayback()
        var feedbackMilliseconds = milliseconds(since: started)
        try await until("playback.play-confirmed") {
            world.playback.snapshot().playing && player.state.pendingCommands.isEmpty && player.isPlaying
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "play.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        player.togglePlayback()
        feedbackMilliseconds = milliseconds(since: started)
        try await until("playback.pause-confirmed") {
            !world.playback.snapshot().playing && player.state.pendingCommands.isEmpty && !player.isPlaying
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "pause.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        player.seek(to: 0.5)
        feedbackMilliseconds = milliseconds(since: started)
        try await until("playback.seek-confirmed") {
            world.playback.snapshot().positionMS == 90_000 && player.state.pendingCommands.isEmpty
                && abs(player.position - 90) < 0.1
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "seek.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        let beforeRejected = world.playback.snapshot().rejectedCount
        world.playback.inject(.reject)
        player.seek(to: 0.8)
        try await until("playback.seek-rejected") {
            world.playback.snapshot().rejectedCount > beforeRejected && player.state.pendingCommands.isEmpty
                && abs(player.position - 90) < 0.1
        }
        checkpoint("seek.rejected", since: started, intent: player.state.intents.last)

        // Hold a successful remote observation across a newer local handoff. Delivering the old
        // revision afterward must not restore the remote owner or its older position.
        started = .now
        let beforeHeld = world.playback.snapshot().commandCount
        world.playback.inject(.holdObservation)
        player.seek(to: 0.25)
        try await until("playback.observation-held") { world.playback.snapshot().commandCount > beforeHeld }
        world.playback.handoff(to: SyntheticPlayback.localID)
        try await until("playback.handoff") { player.isActiveDevice }
        world.playback.releaseHeldObservations(reversed: true)
        let barrierRevision = world.playback.publish()
        try await until("playback.stale-drained") {
            (player.state.sourceRevisions[.engineCluster] ?? 0) >= barrierRevision
        }
        guard player.isActiveDevice else { throw BrowsingFailure.checkpoint("stale-handoff") }
        checkpoint("handoff.stale-observation", since: started)

        started = .now
        let previousGeneration = player.engineGeneration
        let recoveryPosition = world.playback.snapshot().positionMS
        world.playback.setConnected(false)
        _ = await player.coordinator.forceReconnect()
        try await until("playback.recovered") {
            player.isConnected && player.engineGeneration > previousGeneration && player.canTogglePlayback
        }
        guard abs(player.position * 1_000 - Double(recoveryPosition)) < 1 else {
            throw BrowsingFailure.checkpoint("recovery.preserved-position")
        }
        checkpoint("disconnect.recovered", since: started)

        started = .now
        let oldAccount = player.accountEpoch
        let beforeReplacementCommand = world.playback.snapshot().commandCount
        world.playback.inject(.holdObservation)
        player.seek(to: 0.75)
        try await until("playback.account-observation-held") {
            world.playback.snapshot().commandCount > beforeReplacementCommand
        }
        await player.logout()
        guard player.accountEpoch > oldAccount, player.accountStore.phase == .signedOut,
            player.state.currentTrack == nil
        else { throw BrowsingFailure.checkpoint("account.cleared") }
        world.restoreSyntheticAccount()
        await player.restore()
        try await until("account.replacement-ready") { player.isConnected && player.canTogglePlayback }
        world.playback.releaseHeldObservations()
        let replacementBarrier = world.playback.publish()
        try await until("account.old-observation-drained") {
            (player.state.sourceRevisions[.engineCluster] ?? 0) >= replacementBarrier
        }
        guard abs(player.position) < 0.1 else { throw BrowsingFailure.checkpoint("account.stale-position") }
        checkpoint("account.replaced", since: started)
        // Leave a known, playing remote owner for the 5 Hz + browsing workload.
        world.playback.handoff(to: SyntheticPlayback.remoteID)
        try await until("playback.remote-ready") {
            player.commandRoute == .remote(from: SyntheticPlayback.localID, to: SyntheticPlayback.remoteID)
        }
        if !player.isPlaying { player.togglePlayback() }
        try await until("playback.workload-ready") { player.isPlaying && player.state.pendingCommands.isEmpty }
        started = .now
        player.refreshQueue()
        try await until("queue.enriched") {
            player.queueNextEntries.allSatisfy { player.catalog.metadata.knownTrack(for: $0.uri) != nil }
        }
        checkpoint("queue.enriched", since: started)
        return checkpoints
    }

    static func until(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let ready = condition()
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                throw BrowsingFailure.checkpoint(name)
            }
            if ready { return }
            await Task.yield()
        }
    }
}

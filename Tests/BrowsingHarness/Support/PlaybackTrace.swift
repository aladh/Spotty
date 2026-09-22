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
    let resumeBlocked: Bool
    let canTogglePlayback: Bool
    let canStartSelection: Bool
}

/// A finite scenario through production action entry points. Conditions, not scheduler turns,
/// determine readiness; the wall deadline only turns a liveness bug into an actionable report.
@MainActor
struct PlaybackTrace {
    static func run(
        player: PlaybackStore, world: BrowsingWorld, recorder: AcceptanceRecorder? = nil
    ) async throws -> [PlaybackTraceCheckpoint] {
        var checkpoints: [PlaybackTraceCheckpoint] = []
        func wait(_ name: String, _ condition: () -> Bool) async throws {
            let expected = expectations(name)
            do {
                try await until(name, condition)
                recorder?.record(
                    name, expected: expected, observed: AcceptanceRecorder.state(player: player, world: world),
                    passed: true)
            } catch {
                recorder?.record(
                    name, expected: expected, observed: AcceptanceRecorder.state(player: player, world: world),
                    passed: false)
                throw error
            }
        }
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
                    actionToStateFeedbackMilliseconds: feedbackMilliseconds,
                    resumeBlocked: player.state.blockedResumeTarget != nil,
                    canTogglePlayback: player.canTogglePlayback, canStartSelection: player.canStartPlayback))
            if let latest = checkpoints.last { recorder?.retain(latest) }
        }
        try await wait("playback.ready") { player.isConnected && player.canTogglePlayback && player.duration > 0 }
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        }
        var started = ContinuousClock.now
        recorder?.event("action", "playback.toggle")
        player.togglePlayback()
        var feedbackMilliseconds = milliseconds(since: started)
        try await wait("playback.play-confirmed") {
            world.playback.snapshot().playing && player.state.pendingCommands.isEmpty && player.isPlaying
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "play.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        recorder?.event("action", "playback.toggle")
        player.togglePlayback()
        feedbackMilliseconds = milliseconds(since: started)
        try await wait("playback.pause-confirmed") {
            !world.playback.snapshot().playing && player.state.pendingCommands.isEmpty && !player.isPlaying
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "pause.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        recorder?.event("action", "playback.seek", state: ["fraction": "0.5"])
        player.seek(to: 0.5)
        feedbackMilliseconds = milliseconds(since: started)
        try await wait("playback.seek-confirmed") {
            world.playback.snapshot().positionMS == 90_000 && player.state.pendingCommands.isEmpty
                && abs(player.position - 90) < 0.1
                && player.state.intents.last?.outcome == .observedConfirmed
        }
        checkpoint(
            "seek.confirmed", since: started, intent: player.state.intents.last,
            feedbackMilliseconds: feedbackMilliseconds)
        started = .now
        let beforeRejected = world.playback.snapshot().rejectedCount
        recorder?.event("fault", "playback.reject-next-command")
        world.playback.inject(.reject)
        recorder?.event("action", "playback.seek", state: ["fraction": "0.8"])
        player.seek(to: 0.8)
        try await wait("playback.seek-rejected") {
            world.playback.snapshot().rejectedCount > beforeRejected && player.state.pendingCommands.isEmpty
                && abs(player.position - 90) < 0.1
        }
        checkpoint("seek.rejected", since: started, intent: player.state.intents.last)

        // Hold a successful remote observation across a newer local handoff. Delivering the old
        // revision afterward must not restore the remote owner or its older position.
        started = .now
        let beforeHeld = world.playback.snapshot().commandCount
        recorder?.event("fault", "playback.hold-next-observation")
        world.playback.inject(.holdObservation)
        recorder?.event("action", "playback.seek", state: ["fraction": "0.25"])
        player.seek(to: 0.25)
        try await wait("playback.observation-held") { world.playback.snapshot().commandCount > beforeHeld }
        recorder?.event("observation", "playback.local-handoff")
        world.playback.handoff(to: SyntheticPlayback.localID)
        try await wait("playback.handoff") { player.isActiveDevice }
        recorder?.event("fault", "playback.release-old-clusters-reversed")
        world.playback.releaseHeldObservations(reversed: true)
        let barrierRevision = world.playback.publish()
        try await wait("playback.stale-drained") {
            (player.state.sourceRevisions[.engineCluster] ?? 0) >= barrierRevision
        }
        guard player.isActiveDevice else { throw BrowsingFailure.checkpoint("stale-handoff") }
        checkpoint("handoff.stale-observation", since: started)

        started = .now
        let previousGeneration = player.engineGeneration
        let recoveryPosition = world.playback.snapshot().positionMS
        recorder?.event("fault", "playback.disconnect")
        world.playback.setConnected(false)
        recorder?.event("action", "playback.force-reconnect")
        _ = await player.coordinator.forceReconnect()
        try await wait("playback.recovered") {
            player.isConnected && player.engineGeneration > previousGeneration && player.canTogglePlayback
        }
        guard abs(player.position * 1_000 - Double(recoveryPosition)) < 1 else {
            throw BrowsingFailure.checkpoint("recovery.preserved-position")
        }
        checkpoint("disconnect.recovered", since: started)

        // Visible control projections share the real reducer; this single-authority Demo
        // complements (but cannot replace) the retained Spirc/adapter delivery-order traces.
        started = .now
        recorder?.event("fault", "playback.refuse-resume")
        world.playback.inject(.resumeMismatch)
        recorder?.event("action", "playback.toggle")
        player.togglePlayback()
        try await wait("recovery.resume-refused") {
            player.state.blockedResumeTarget != nil && player.state.pendingCommands.isEmpty
                && player.playbackNotice?.kind == .resumeUnavailable && !player.isPlaybackCommandPending
        }
        guard let notice = player.playbackNotice else { throw BrowsingFailure.checkpoint("recovery.notice") }
        recorder?.event("action", "playback.dismiss-resume-notice")
        player.dismissPlaybackNotice(id: notice.id)
        try await wait("recovery.notice-dismissed") { player.playbackNotice == nil }
        guard !player.canTogglePlayback && player.canStartPlayback else {
            throw BrowsingFailure.checkpoint("recovery.dismissal-keeps-block")
        }
        checkpoint("recovery.resume-refused", since: started)
        let selected = CatalogTrack(
            id: "synthetic0x0", uri: "spotify:track:synthetic0x0", title: "Silver Lining",
            artist: "Harbor Lights", album: "Signals at Dusk", duration: 180, artworkURL: nil, addedAt: nil)
        let recoveryAction = CatalogPlaybackAccess(player: player).action(for: selected, behavior: .activateSelection)
        started = .now
        let beforeFailedSelection = world.playback.snapshot().commandCount
        recorder?.event("fault", "playback.reject-next-command")
        world.playback.inject(.reject)
        recorder?.event("action", "playback.select-recovery-track")
        recoveryAction.perform()
        try await wait("recovery.selection-failed") {
            world.playback.snapshot().commandCount > beforeFailedSelection
                && player.state.intents.last?.outcome == .rejected && player.state.pendingCommands.isEmpty
                && recoveryAction.isEnabled
        }
        guard !player.canTogglePlayback && recoveryAction.isEnabled else {
            throw BrowsingFailure.checkpoint("recovery.failure-keeps-selection")
        }
        checkpoint("recovery.selection-failed", since: started, intent: player.state.intents.last)
        started = .now
        recorder?.event("fault", "playback.hold-next-observation")
        world.playback.inject(.holdObservation)
        recorder?.event("action", "playback.select-recovery-track")
        recoveryAction.perform()
        try await wait("recovery.selection-sent") {
            player.state.intents.last?.outcome == .sent && !recoveryAction.isEnabled
        }
        guard player.state.blockedResumeTarget != nil && !recoveryAction.isEnabled else {
            throw BrowsingFailure.checkpoint("recovery.acknowledgement-is-not-confirmation")
        }
        recorder?.event("fault", "playback.release-held-observations")
        world.playback.releaseHeldObservations()
        try await wait("recovery.selection-confirmed") {
            player.state.intents.last?.outcome == .observedConfirmed && player.state.blockedResumeTarget == nil
                && recoveryAction.showsPause && recoveryAction.isEnabled
        }
        checkpoint("recovery.selection-confirmed", since: started, intent: player.state.intents.last)
        recorder?.event("action", "playback.toggle")
        player.togglePlayback()
        try await wait("recovery.paused") { !player.isPlaying && player.canTogglePlayback }

        started = .now
        let oldAccount = player.accountEpoch
        let beforeReplacementCommand = world.playback.snapshot().commandCount
        recorder?.event("fault", "playback.hold-next-observation")
        world.playback.inject(.holdObservation)
        recorder?.event("action", "playback.seek", state: ["fraction": "0.75"])
        player.seek(to: 0.75)
        try await wait("playback.account-observation-held") {
            world.playback.snapshot().commandCount > beforeReplacementCommand
        }
        recorder?.event("action", "account.logout-synthetic")
        await player.logout()
        guard player.accountEpoch > oldAccount, player.accountStore.phase == .signedOut,
            player.state.currentTrack == nil
        else { throw BrowsingFailure.checkpoint("account.cleared") }
        recorder?.event("fault", "account.replace-synthetic")
        world.restoreSyntheticAccount()
        await player.restore()
        try await wait("account.replacement-ready") { player.isConnected && player.canTogglePlayback }
        recorder?.event("fault", "playback.release-held-observations")
        world.playback.releaseHeldObservations()
        let replacementBarrier = world.playback.publish()
        try await wait("account.old-observation-drained") {
            (player.state.sourceRevisions[.engineCluster] ?? 0) >= replacementBarrier
        }
        guard abs(player.position) < 0.1 else { throw BrowsingFailure.checkpoint("account.stale-position") }
        checkpoint("account.replaced", since: started)
        // Leave a known, playing remote owner for the 5 Hz + browsing workload.
        world.playback.handoff(to: SyntheticPlayback.remoteID)
        try await wait("playback.remote-ready") {
            player.commandRoute == .remote(from: SyntheticPlayback.localID, to: SyntheticPlayback.remoteID)
        }
        if !player.isPlaying { player.togglePlayback() }
        try await wait("playback.workload-ready") { player.isPlaying && player.state.pendingCommands.isEmpty }
        started = .now
        recorder?.event("action", "queue.refresh")
        player.refreshQueue()
        try await wait("queue.enriched") {
            player.queueNextEntries.allSatisfy { player.catalog.metadata.knownTrack(for: $0.uri) != nil }
        }
        checkpoint("queue.enriched", since: started)
        return checkpoints
    }

    private static func expectations(_ name: String) -> [String: String] {
        switch name {
        case "playback.ready", "account.replacement-ready":
            return ["connected": "true", "canTogglePlayback": "true"]
        case "playback.play-confirmed":
            return ["playing": "true", "pendingCommands": "0", "intentOutcome": "observedConfirmed"]
        case "playback.pause-confirmed":
            return ["playing": "false", "pendingCommands": "0", "intentOutcome": "observedConfirmed"]
        case "playback.seek-confirmed":
            return ["positionMS": "90000", "pendingCommands": "0", "intentOutcome": "observedConfirmed"]
        case "playback.seek-rejected":
            return ["positionMS": "90000", "pendingCommands": "0", "intentOutcome": "rejected"]
        case "playback.handoff", "playback.stale-drained":
            return ["localOwner": "true"]
        case "playback.recovered":
            return ["connected": "true", "canTogglePlayback": "true", "condition": "new engine generation"]
        case "recovery.resume-refused", "recovery.notice-dismissed":
            return ["resumeBlocked": "true", "canTogglePlayback": "false", "canStartSelection": "true"]
        case "recovery.selection-failed":
            return ["resumeBlocked": "true", "canStartSelection": "true", "intentOutcome": "rejected"]
        case "recovery.selection-sent":
            return ["resumeBlocked": "true", "intentOutcome": "sent"]
        case "recovery.selection-confirmed":
            return ["resumeBlocked": "false", "intentOutcome": "observedConfirmed", "playing": "true"]
        case "recovery.paused":
            return ["playing": "false", "canTogglePlayback": "true"]
        case "account.old-observation-drained":
            return ["positionMS": "0", "condition": "replacement generation delivered after stale account event"]
        case "playback.remote-ready":
            return ["localOwner": "false", "condition": "remote command route available"]
        case "playback.workload-ready":
            return ["playing": "true", "pendingCommands": "0"]
        case "queue.enriched":
            return ["condition": "every next queue entry has catalog metadata"]
        default:
            return ["condition": "command admitted and observation retained at synthetic boundary"]
        }
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

import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottySessionRuntime

struct AcceptanceCheckpoint: Codable, Sendable {
    let name: String
    let expected: [String: String]
    let observed: [String: String]
    let passed: Bool
}

struct AcceptanceTimelineEntry: Codable, Sendable {
    let sequence: Int
    let kind: String
    let name: String
    let state: [String: String]
}

struct AcceptanceRuntimeFailure: Codable, Sendable {
    let code: String
    let checkpoint: String
    let expected: [String: String]
    let observed: [String: String]
}

struct AcceptanceRuntimeReport: Encodable, Sendable {
    struct Isolation: Encodable, Sendable {
        let dependencyMode = "synthetic"
        let forbiddenMutationAttempts: Int
        /// The unsigned test host cannot claim the separately verified Demo sandbox.
        let networkSandboxVerified: Bool?
    }

    let schemaVersion = 1
    let scenarioID: String
    let scenarioVersion: Int
    let passed: Bool
    let failure: AcceptanceRuntimeFailure?
    let checkpoints: [AcceptanceCheckpoint]
    let timeline: [AcceptanceTimelineEntry]
    let isolation: Isolation
    let environment: [String: String]
    let playbackCheckpoints: [PlaybackTraceCheckpoint]
}

/// One recorder owns completed and failed assertions, so an exception cannot discard a partial
/// trace. Expected values name contract state; observations are captured from production stores.
@MainActor
final class AcceptanceRecorder {
    private(set) var checkpoints: [AcceptanceCheckpoint] = []
    private(set) var timeline: [AcceptanceTimelineEntry] = []
    private(set) var failure: AcceptanceRuntimeFailure?
    private(set) var playbackCheckpoints: [PlaybackTraceCheckpoint] = []

    func event(_ kind: String, _ name: String, state: [String: String] = [:]) {
        timeline.append(.init(sequence: timeline.count + 1, kind: kind, name: name, state: state))
    }

    func check(_ name: String, expected: [String: String], observed: [String: String]) throws {
        try Task.checkCancellation()
        let passed = expected.allSatisfy { observed[$0.key] == $0.value }
        record(name, expected: expected, observed: observed, passed: passed)
        guard passed else { throw BrowsingFailure.checkpoint(name) }
    }

    func record(_ name: String, expected: [String: String], observed: [String: String], passed: Bool) {
        checkpoints.append(.init(name: name, expected: expected, observed: observed, passed: passed))
        event("checkpoint", name, state: observed)
        if !passed {
            failure = .init(
                code: Task.isCancelled ? "timeout_or_cancelled" : "checkpoint_failed",
                checkpoint: name, expected: expected, observed: observed)
        }
    }

    func retain(_ checkpoint: PlaybackTraceCheckpoint) { playbackCheckpoints.append(checkpoint) }

    func capture(_ error: any Error, player: PlaybackStore, world: BrowsingWorld) {
        guard failure == nil else { return }
        let name: String
        if case let BrowsingFailure.checkpoint(checkpoint) = error {
            name = checkpoint
        } else {
            name = "runtime.exception"
        }
        var observed = Self.state(player: player, world: world)
        observed["error"] = error.localizedDescription
        record(name, expected: ["condition": "satisfied"], observed: observed, passed: false)
    }

    static func state(player: PlaybackStore, world: BrowsingWorld) -> [String: String] {
        let state = player.state
        let playback = world.playback.snapshot()
        return [
            "session": String(describing: player.accountStore.phase),
            "connected": String(player.isConnected), "playing": String(player.isPlaying),
            "localOwner": String(player.isActiveDevice),
            "positionMS": String(Int((player.position * 1_000).rounded())),
            "authorityPositionMS": String(playback.positionMS),
            "pendingCommands": String(state.pendingCommands.count),
            "intentOutcome": state.intents.last.map { String(describing: $0.outcome) } ?? "none",
            "resumeBlocked": String(state.blockedResumeTarget != nil),
            "canTogglePlayback": String(player.canTogglePlayback),
            "canStartSelection": String(player.canStartPlayback),
            "commandCount": String(playback.commandCount), "rejectedCount": String(playback.rejectedCount),
            "engineGeneration": String(player.engineGeneration), "accountEpoch": String(player.accountEpoch),
            "playbackRevision": String(state.sourceRevisions[.enginePlayback] ?? 0),
            "devicesRevision": String(state.sourceRevisions[.engineDevices] ?? 0),
            "forbiddenMutationAttempts": String(world.snapshot().mutationAttempts),
            "engineInitializationCount": String(world.snapshot().requests["engine.synthetic-initialize"] ?? 0),
        ]
    }
}

/// A narrow, non-shipping boundary mutation verifies the holdout's ability to catch a regression.
/// It cannot be enabled by workload JSON, launch flags, or a production dependency.
enum AcceptanceSeed: Sendable, Equatable {
    case none
    case delayedPlaybackUsesArrivalRevision
}

/// Shared state acceptance used by the signed Demo and the credential-free Swift test host.
/// The existing GUI workload separately establishes window/layout and network-sandbox evidence.
@MainActor
enum AcceptanceScenarioRuntime {
    /// Cancellation bounds cooperative scenario work. A hung dependency is bounded separately
    /// by the outer test-host or Demo launcher watchdog; this task cannot forcibly terminate it.
    static func runWithDeadline(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation,
        timeoutSeconds: Int = 120, networkSandboxVerified: Bool? = nil, seed: AcceptanceSeed = .none
    ) async -> AcceptanceRuntimeReport {
        let run = Task { @MainActor in
            await Self.run(
                player: player, world: world, navigation: navigation,
                networkSandboxVerified: networkSandboxVerified, seed: seed)
        }
        let timeout = Task {
            do {
                try await ContinuousClock().sleep(for: .seconds(timeoutSeconds))
                run.cancel()
            } catch {}
        }
        let report = await run.value
        timeout.cancel()
        return report
    }

    static func run(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation,
        networkSandboxVerified: Bool? = nil, seed: AcceptanceSeed = .none
    ) async -> AcceptanceRuntimeReport {
        let recorder = AcceptanceRecorder()
        if seed == .delayedPlaybackUsesArrivalRevision {
            world.playback.seedDelayedPlaybackArrivalRevisionRegression()
            recorder.event("seed", "delayed-playback-uses-arrival-revision")
        }
        do {
            try world.scenario.validate()
            recorder.event("action", "account.restore")
            await player.restore()
            await player.effects.settlement(of: .catalogLoad)?.wait()
            let signedOut = world.scenario.mode == .signedOut
            try recorder.check(
                signedOut ? "signed-out.ready" : "home.ready",
                expected: ["session": signedOut ? "signedOut" : "ready"],
                observed: AcceptanceRecorder.state(player: player, world: world))
            if signedOut {
                try recorder.check(
                    "signed-out.no-playback",
                    expected: ["commandCount": "0", "connected": "false", "engineInitializationCount": "0"],
                    observed: AcceptanceRecorder.state(player: player, world: world))
            } else {
                try await browse(player: player, world: world, navigation: navigation, recorder: recorder)
                if world.scenario.mode == .playback {
                    _ = try await PlaybackTrace.run(player: player, world: world, recorder: recorder)
                    try await replacementCatalog(player: player, world: world, recorder: recorder)
                    if world.scenario.acceptanceVariation == "stale-observation-reversed" {
                        try await stalePlayback(player: player, world: world, recorder: recorder)
                    }
                }
            }
            try recorder.check(
                "isolation.no-forbidden-mutations", expected: ["forbiddenMutationAttempts": "0"],
                observed: AcceptanceRecorder.state(player: player, world: world))
        } catch {
            recorder.capture(error, player: player, world: world)
        }
        return AcceptanceRuntimeReport(
            scenarioID: world.scenario.acceptanceScenarioID ?? "legacy.\(world.scenario.mode.rawValue)",
            scenarioVersion: world.scenario.acceptanceScenarioVersion ?? 1,
            passed: recorder.failure == nil, failure: recorder.failure,
            checkpoints: recorder.checkpoints, timeline: recorder.timeline,
            isolation: .init(
                forbiddenMutationAttempts: world.snapshot().mutationAttempts,
                networkSandboxVerified: networkSandboxVerified),
            environment: [
                "host": networkSandboxVerified == true ? "signed-demo" : "swift-testing",
                "configuration": BrowsingExecutionConfiguration.current.configuration,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "clock": "state-readiness-with-wall-deadline", "audioOutput": "synthetic-no-device",
                "boundaryMutation": seed == .none ? "none" : "delayed-playback-uses-arrival-revision",
            ],
            playbackCheckpoints: recorder.playbackCheckpoints)
    }

    /// Account replacement in the trace starts a new catalog load independently of playback
    /// readiness. Join that production effect before returning the same player to the GUI loop.
    private static func replacementCatalog(
        player: PlaybackStore, world: BrowsingWorld, recorder: AcceptanceRecorder
    ) async throws {
        let name = "account.replacement-catalog-ready"
        let expected = [
            "session": "ready", "playlistCount": String(world.fixtures.playlists.count),
            "homeSectionCount": world.scenario.expandedLibrary == true ? "4" : "1",
        ]
        func observed() -> [String: String] {
            [
                "session": String(describing: player.accountStore.phase),
                "playlistCount": String(player.catalog.homeLibrary.playlists.count),
                "homeSectionCount": String(player.catalog.homeLibrary.homeSections.count),
            ]
        }
        recorder.event("action", "catalog.await-account-replacement")
        await player.effects.settlement(of: .catalogLoad)?.wait()
        do {
            try await PlaybackTrace.until(name) { observed() == expected }
        } catch {
            recorder.record(name, expected: expected, observed: observed(), passed: false)
            throw error
        }
        try recorder.check(name, expected: expected, observed: observed())
    }

    private static func browse(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation, recorder: AcceptanceRecorder
    ) async throws {
        let items = player.catalog.homeLibrary.playlists
        try recorder.check(
            "browsing.library", expected: ["playlistCount": String(world.fixtures.playlists.count)],
            observed: ["playlistCount": String(items.count)])
        let destinations = Array(items.prefix(2))
        for (index, item) in (destinations + destinations).enumerated() {
            recorder.event("action", "navigation.playlist", state: ["uri": item.uri])
            navigation.select(item)
            await player.catalog.playlistStore.load(item)
            try recorder.check(
                "browsing.playlist.\(index)",
                expected: ["loadedURI": item.uri, "trackCount": String(world.scenario.trackCount), "error": "none"],
                observed: [
                    "loadedURI": player.catalog.playlistStore.loadedURI ?? "none",
                    "trackCount": String(player.catalog.playlistStore.tracks.count),
                    "error": player.catalog.playlistStore.error == nil ? "none" : "present",
                ])
        }
        recorder.event("action", "navigation.home")
        navigation.updateSelection(.destination(.home))
        try recorder.check(
            "browsing.home-returned", expected: ["homeSelected": "true"],
            observed: ["homeSelected": String(navigation.selection == .destination(.home))])
    }

    private static func stalePlayback(
        player: PlaybackStore, world: BrowsingWorld, recorder: AcceptanceRecorder
    ) async throws {
        recorder.event("action", "holdout.pause")
        if player.isPlaying { player.togglePlayback() }
        try await PlaybackTrace.until("holdout.paused") { !player.isPlaying && player.state.pendingCommands.isEmpty }
        recorder.event("action", "holdout.seek-old", state: ["positionMS": "45000"])
        player.seek(to: 0.25)
        try await PlaybackTrace.until("holdout.old-position") {
            player.state.pendingCommands.isEmpty && abs(player.position - 45) < 0.01
        }
        recorder.event("fault", "holdout.retain-partial-playback")
        world.playback.holdPlaybackObservation()
        recorder.event("action", "holdout.seek-new", state: ["positionMS": "135000"])
        player.seek(to: 0.75)
        try await PlaybackTrace.until("holdout.new-position") {
            player.state.pendingCommands.isEmpty && abs(player.position - 135) < 0.01
        }
        recorder.event("fault", "holdout.release-old-partial-playback")
        world.playback.releaseHeldObservations(reversed: true)
        let fence = world.playback.publishDevicesFence()
        try await PlaybackTrace.until("holdout.delivery-fence") {
            (player.state.sourceRevisions[.engineDevices] ?? 0) >= fence
        }
        try recorder.check(
            "holdout.stale-playback-preserves-position",
            expected: ["positionMS": "135000", "authorityPositionMS": "135000", "localOwner": "false"],
            observed: AcceptanceRecorder.state(player: player, world: world))
    }
}

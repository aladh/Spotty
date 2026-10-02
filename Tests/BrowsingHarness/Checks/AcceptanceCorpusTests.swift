import Foundation
import Testing
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
@testable import SpottyBrowsingSupport
@testable import SpottyCore
@testable import SpottySessionRuntime

/// The acceptance job supplies the manifest-resolved corpus. Legacy checks retain their separate
/// coverage; an absent input or representative-only run never executes the holdout mutation proof.
@Suite("Manifest acceptance corpus", .serialized)
@MainActor
struct AcceptanceCorpusTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func invalidTimingRemainsReportable(position: Double) {
        #expect(AcceptanceRecorder.positionMilliseconds(position) == "invalid")
        #expect(AcceptanceRecorder.positionMilliseconds(17.125) == "17125")
    }

    @Test func cancelledCallerCancelsItsScenario() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyCancelledAcceptance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        let task = Task {
            await AcceptanceScenarioRuntime.runWithDeadline(
                player: player, world: world, navigation: CatalogNavigation())
        }
        task.cancel()
        let report = await task.value
        #expect(!report.passed)
        #expect(report.failure?.code == "timeout_or_cancelled")
        #expect(world.snapshot().requests.isEmpty)
        await player.shutdownForTermination()
    }

    @Test(arguments: ["../escape", "UPPER", "with/slash", "trailing\n", String(repeating: "a", count: 81)])
    func scenarioRejectsInvalidEvidenceIdentifiers(identifier: String) {
        var scenario = BrowsingScenario()
        scenario.acceptanceScenarioID = identifier
        scenario.acceptanceScenarioVersion = 1
        scenario.acceptanceTimeoutSeconds = 60
        #expect(throws: (any Error).self) { try scenario.validate() }
    }

    private struct Input: Decodable {
        let id: String
        let version: Int
        let corpus: String
        let scenario: BrowsingScenario
        let timeoutSeconds: Int
    }

    @Test func declaredCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["SPOTTY_ACCEPTANCE_INPUT"] else { return }
        let output = try #require(environment["SPOTTY_ACCEPTANCE_OUTPUT"])
        let scenarios = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        #expect(!scenarios.isEmpty)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for entry in scenarios {
            #expect(entry.scenario.acceptanceScenarioID == entry.id)
            #expect(entry.scenario.acceptanceScenarioVersion == entry.version)
            #expect(entry.scenario.acceptanceTimeoutSeconds == entry.timeoutSeconds)
            let report = try await execute(entry.scenario, timeoutSeconds: entry.timeoutSeconds)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: URL(fileURLWithPath: output).appendingPathComponent("runtime-\(entry.id).json"), options: .atomic)
            #expect(report.passed, "\(entry.id): \(report.failure?.checkpoint ?? "unknown failure")")
        }
    }

    @Test func seededBoundaryRegressionPassesRepresentativeAndFailsHoldout() async throws {
        guard let input = ProcessInfo.processInfo.environment["SPOTTY_ACCEPTANCE_INPUT"] else { return }
        let selected = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        guard selected.contains(where: { $0.scenario.acceptanceVariation == "stale-observation-reversed" }) else {
            return
        }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.mode = .playback
        scenario.acceptanceScenarioID = "playback.recovery"
        scenario.acceptanceScenarioVersion = 1
        scenario.acceptanceTimeoutSeconds = 120
        let representative = try await execute(scenario, seed: .delayedPlaybackUsesArrivalRevision)
        #expect(representative.passed)
        scenario.acceptanceScenarioID = "holdout.playback-stale-order"
        scenario.acceptanceVariation = "stale-observation-reversed"
        let holdout = try await execute(scenario)
        #expect(holdout.passed)
        let seededHoldout = try await execute(scenario, seed: .delayedPlaybackUsesArrivalRevision)
        #expect(!seededHoldout.passed)
        #expect(seededHoldout.failure?.checkpoint == "holdout.stale-playback-preserves-position")
        #expect(seededHoldout.failure?.expected["positionMS"] == "135000")
        #expect(seededHoldout.failure?.observed["positionMS"] == "45000")
        #expect(seededHoldout.checkpoints.count > 10, "completed checkpoints survive the seeded failure")
        #expect(seededHoldout.timeline.contains { $0.name == "holdout.release-old-partial-playback" })
        #expect(seededHoldout.isolation.forbiddenMutationAttempts == 0)
        if let output = ProcessInfo.processInfo.environment["SPOTTY_ACCEPTANCE_OUTPUT"] {
            struct Proof: Encodable {
                let schemaVersion = 1
                let mutation = "Delayed partial playback observations incorrectly receive fresh arrival revisions"
                let representative: AcceptanceRuntimeReport
                let holdout: AcceptanceRuntimeReport
                let seededHoldout: AcceptanceRuntimeReport
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Proof(representative: representative, holdout: holdout, seededHoldout: seededHoldout))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("mutation-proof.json"), options: .atomic)
        }
    }

    @Test(arguments: [false, true])
    func replacementCatalogIsReadyForTheFollowingDemoWorkload(expanded: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyAcceptanceCatalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.mode = .playback
        scenario.expandedLibrary = expanded
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        let report = await AcceptanceScenarioRuntime.runWithDeadline(
            player: player, world: world, navigation: CatalogNavigation())
        #expect(report.passed)
        #expect(world.snapshot().requests["account.synthetic-replacement"] == 1)
        #expect(
            world.snapshot().requests["library"] == 3,
            "Startup, reconnect, and account replacement each refresh catalog freshness")
        #expect(player.catalog.homeLibrary.playlists.count == world.fixtures.playlists.count)
        #expect(player.catalog.homeLibrary.homeSections.count == (expanded ? 4 : 1))
        #expect(report.checkpoints.contains { $0.name == "account.replacement-catalog-ready" && $0.passed })
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true])
    func reconnectCatalogRetirementAndJoinedTraceHaveDifferentValidRequestCounts(joinReconnect: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyGatedReconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.mode = .playback
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let catalog = ReconnectProfileCatalog(world: world)
        defer { catalog.withheld.close() }
        let environment = PlaybackEnvironment(
            remote: world, local: world, webQueue: world, account: world, audioOutput: world,
            preferences: world, lifecycle: world, clock: world, catalog: catalog,
            playlistMutations: world, artwork: world.environment.artwork)
        let player = PlaybackStore(environment: environment, feedback: TransientFeedbackPresenter(clock: world))
        var retiredWorkers: [Task<Void, Never>] = []
        var journey: Task<Void, any Error>?
        do {
            await player.restore()
            await player.catalogLoadTask?.value
            try #require(world.snapshot().requests["library"] == 1)
            let oldEpoch = player.accountEpoch
            let oldSession = player.catalogSession.snapshot
            player.withRuntime {
                $0.accountStore.publishPhase(.connecting)
                $0.accountStore.publishPhase(.ready)
            }
            try await PlaybackTrace.until("reconnect.profile-admitted") { catalog.withheld.waiterCount == 1 }
            retiredWorkers = player.catalog.homeLibrary.workerSettlements()
            var journeyStarted = false
            var journeyFinished = false
            journey = Task {
                journeyStarted = true
                defer { journeyFinished = true }
                if joinReconnect {
                    try await PlaybackTrace.reconnectCatalog(player: player, world: world, previousSession: oldSession)
                    #expect(
                        catalog.withheld.waiterCount == 0, "The reconnect join must settle before account replacement")
                    #expect(world.snapshot().requests["library"] == 2)
                }
                await player.logout()
                world.restoreSyntheticAccount()
                await player.restore()
                await player.catalogLoadTask?.value
            }
            try await PlaybackTrace.until("reconnect.journey-started") { journeyStarted }
            if joinReconnect {
                #expect(player.accountEpoch == oldEpoch)
                #expect(world.snapshot().requests["account.synthetic-replacement"] == nil)
                catalog.withheld.finish(CatalogProfileSnapshot(name: "Reconnect", uri: "spotify:user:synthetic"))
            }
            try await PlaybackTrace.until("reconnect.journey-finished") { journeyFinished }
            try await journey?.value
            if !joinReconnect {
                #expect(catalog.withheld.waiterCount == 1, "Retired non-cooperative profile is still withheld")
                catalog.withheld.finish(CatalogProfileSnapshot(name: "Retired", uri: "spotify:user:retired"))
            }
            for worker in retiredWorkers { await worker.value }
            #expect(player.accountEpoch > oldEpoch)
            #expect(player.catalogSession.snapshot.accountEpoch == player.accountEpoch)
            #expect(player.catalog.homeLibrary.currentProfileURI == "spotify:user:synthetic")
            #expect(player.catalog.homeLibrary.currentPlaylists.count == world.fixtures.playlists.count)
            #expect(world.snapshot().requests["library"] == (joinReconnect ? 3 : 2))
            await player.shutdownForTermination()
        } catch {
            let outstanding = retiredWorkers + player.catalog.homeLibrary.workerSettlements()
            journey?.cancel()
            catalog.withheld.close()
            _ = try? await journey?.value
            for worker in outstanding { await worker.value }
            await player.shutdownForTermination()
            throw error
        }
    }

    private func execute(
        _ scenario: BrowsingScenario, timeoutSeconds: Int = 120, seed: AcceptanceSeed = .none
    ) async throws -> AcceptanceRuntimeReport {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyAcceptance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        let report = await AcceptanceScenarioRuntime.runWithDeadline(
            player: player, world: world, navigation: CatalogNavigation(), timeoutSeconds: timeoutSeconds, seed: seed)
        await player.shutdownForTermination()
        return report
    }
}

/// The acceptance world must remain the account/playback authority. Its profile response has
/// no hold point; this narrow forwarding adapter adds that script using the shared response gate.
private actor ReconnectProfileCatalog: CatalogProviding {
    let world: BrowsingWorld
    nonisolated let withheld = HarnessResponseGate<CatalogProfileSnapshot>(cancellation: .ignored)
    private var profiles = 0

    init(world: BrowsingWorld) { self.world = world }

    func profile() async throws -> CatalogProfileSnapshot {
        profiles += 1
        if profiles == 2 { return try await withheld.wait() }
        return try await world.profile()
    }

    func home() async throws -> CatalogHomeSnapshot { try await world.home() }
    func playlistLibrary() async throws -> [PlaylistLibraryNode] { try await world.playlistLibrary() }
    func libraryAlbums() async throws -> [CatalogItem] { try await world.libraryAlbums() }
    func libraryArtists() async throws -> [CatalogItem] { try await world.libraryArtists() }
    func libraryTracks() async throws -> [CatalogTrack] { try await world.libraryTracks() }
    func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack] {
        try await world.searchTracks(term, limit: limit)
    }
    func playlist(id: String) async throws -> CatalogPlaylistSnapshot { try await world.playlist(id: id) }
}

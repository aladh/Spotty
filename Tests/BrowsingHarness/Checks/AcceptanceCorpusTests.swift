import Foundation
import Testing
@testable import SpottyBrowsingSupport
@testable import SpottyCore

/// The acceptance job supplies the manifest-resolved corpus. Legacy checks retain their separate
/// coverage; an absent input or representative-only run never executes the holdout mutation proof.
@Suite("Manifest acceptance corpus", .serialized)
@MainActor
struct AcceptanceCorpusTests {
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

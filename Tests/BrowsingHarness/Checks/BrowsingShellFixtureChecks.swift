import Foundation
import SpottyEngineAdapter
import Testing
@testable import SpottyBrowsingSupport
@testable import SpottyCore

@Suite("Non-playing GUI shell fixtures", .serialized)
@MainActor
struct BrowsingShellFixtureChecks {
    @Test(arguments: [BrowsingScenario.Mode.browsing, .signedOut])
    func restoresWithoutPlaybackCommands(mode: BrowsingScenario.Mode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyShellFixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.mode = mode
        scenario.guiShellRegression = true
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        do {
            await player.restore()
            if mode == .browsing {
                try await PlaybackTrace.until("gui.fixture-restored") {
                    player.hasCurrentTrack && player.hasCurrentTrackMetadata && player.displayedArtworkURL != nil
                }
                #expect(player.trackURI == "spotify:track:synthetic0x0")
                #expect(player.displayedArtworkURL?.isFileURL == true)
            } else {
                #expect(player.accountStore.phase == .signedOut)
                #expect(world.snapshot().requests["engine.synthetic-initialize"] == nil)
                #expect(player.hasCurrentTrack == false)
            }
            #expect(player.isPlaying == false)
            #expect(world.playback.snapshot().playing == false)
            #expect(world.playback.snapshot().commandCount == 0)
            #expect(world.snapshot().mutationAttempts == 0)
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }

    @Test func pausedGUIFixtureDoesNotEnableCommandPort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyShellPort-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.guiShellRegression = true
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        #expect(world.execute(.pause).isOK == false)
        #expect(world.snapshot().mutationAttempts == 1)
        #expect(world.playback.snapshot().commandCount == 0)
        #expect(world.playback.snapshot().playing == false)
        scenario.mode = .playback
        #expect(throws: (any Error).self) { try scenario.validate() }
    }

    @Test func scheduledSearchCompletesThroughGUIFixtureClockWithoutPlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyShellSearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.version = 2
        scenario.guiShellRegression = true
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        var scheduled: Task<Void, Never>?
        do {
            await player.restore()
            try await PlaybackTrace.until("gui.search-session-ready") {
                player.accountStore.phase == .ready && player.isConnected
            }
            let query = "Signals at Dusk"
            var finished = false
            scheduled = Task {
                // Exercise the production view-driven debounce, which immediate search bypasses.
                await player.catalog.searchStore.scheduleSearch(query)
                finished = true
            }
            try await PlaybackTrace.until("gui.scheduled-search-ready") {
                finished && !player.catalog.searchStore.isAwaitingResults(for: query)
                    && player.catalog.searchStore.albums.map(\.title) == [query]
            }
            scheduled?.cancel()
            await scheduled?.value
            scheduled = nil
            #expect(player.catalog.searchStore.errors.isEmpty)
            #expect(world.snapshot().requests["search.albums"] == 1)
            #expect(player.isPlaying == false)
            #expect(world.playback.snapshot().playing == false)
            #expect(world.playback.snapshot().commandCount == 0)
            #expect(world.snapshot().mutationAttempts == 0)
        } catch {
            // A parked debounce must fail the readiness bound and still retire its owned task.
            scheduled?.cancel()
            await scheduled?.value
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }
}

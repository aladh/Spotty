import Darwin
import Foundation
import SpottyTestSupport
import Testing
@testable import SpottyBrowsingSupport
@testable import SpottyCore

@Suite("Controlled actual Home measurement", .serialized)
@MainActor
struct BrowsingHomeMeasurementChecks {
    @Test(arguments: [12, 120])
    func initialResponseStaysSuspendedUntilCaptureOwnerReleasesIt(sections: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeGate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var scenario = BrowsingScenario(trackCount: 1, artworkCount: 1, artworkPixels: 64, cycles: 1)
        scenario.homePresentedProbeSections = sections
        scenario.homePresentedMeasurement = true
        let world = try BrowsingWorld(scenario: scenario, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        defer { world.homeResponse.close() }
        do {
            await player.restore()
            try await requireEventually(description: "Actual restore reaches the suspended synthetic Home provider") {
                world.homeResponse.isWaiting && CatalogPlaybackAccess(player: player).isConnected
            }
            #expect(player.accountStore.phase == .ready)
            #expect(player.catalog.homeLibrary.homeSections.isEmpty)
            #expect(world.snapshot().requests["home"] == 1)
            world.homeResponse.resume()
            await player.catalogLoadTask?.value
            #expect(BrowsingRun.homeContentReady(player: player, expectedSections: sections))
            #expect(world.playback.snapshot().commandCount == 0)
            #expect(world.snapshot().mutationAttempts == 0)
        } catch {
            world.homeResponse.close()
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }

    @Test func measurementCannotEnableAnUnrelatedScenario() {
        var scenario = BrowsingScenario()
        scenario.homePresentedMeasurement = true
        #expect(throws: BrowsingFailure.self) { try scenario.validate() }
        scenario.homePresentedProbeSections = 120
        #expect(throws: Never.self) { try scenario.validate() }
        scenario.guiShellRegression = true
        #expect(throws: BrowsingFailure.self) { try scenario.validate() }
    }

    @Test func terminalRasterCanPrecedeLaterReadinessWithoutInventingAFrame() {
        let first = frame(110, 120, "home")
        let idle = frame(110, 210, "home", new: false)
        let frames = [frame(90, 100, "loading"), first, idle, idle, idle]
        let selected = HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 200)
        #expect(selected?.displayedMachTime == 110)
        #expect(selected?.receivedMachTime == 120)
        #expect(selected?.isNewFrame == true)
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 115, observed: 200) == nil)
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 220) == nil)
    }

    @Test func anEarlierMatchingTransientIsNotTheTerminalRasterOnset() {
        let frames = [frame(110, 120, "home"), frame(130, 140, "loading"),
            frame(150, 160, "home"), frame(150, 210, "home", new: false),
            frame(150, 220, "home", new: false), frame(150, 230, "home", new: false)]
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 200)?
            .displayedMachTime == 150)
    }

    @Test func transientOrUnconfirmedTerminalRasterIsExcluded() {
        let frames = [frame(110, 210, "home"), frame(120, 220, "loading"), frame(130, 230, "home")]
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 200) == nil)
        let idle = frame(90, 210, "old", new: false)
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: [idle, idle, idle], started: 100, observed: 200) == nil)
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 201, observed: 200) == nil)
    }

    @Test func observationMustBelongToTheCurrentLoadAndSharedDeadline() throws {
        let request = HomeAXProtocol.Request(runID: "run", pid: 42, nonce: UUID().uuidString,
            startedMachTime: 100, deadlineMachTime: 300)
        try HomeAXProtocol.Observation(nonce: request.nonce, observedMachTime: 200)
            .validate(request: request, loadStarted: 150, now: 250)
        for observation in [
            HomeAXProtocol.Observation(nonce: UUID().uuidString, observedMachTime: 200),
            HomeAXProtocol.Observation(nonce: request.nonce, observedMachTime: 149),
            HomeAXProtocol.Observation(nonce: request.nonce, observedMachTime: 251),
            HomeAXProtocol.Observation(nonce: request.nonce, observedMachTime: 300),
        ] {
            #expect(throws: HomeAXProtocol.Failure.self) {
                try observation.validate(request: request, loadStarted: 150, now: 250)
            }
        }
    }

    private func frame(_ display: UInt64, _ received: UInt64, _ digest: String, new: Bool = true)
        -> HomePresentedFrameCollector.Frame
    {
        HomePresentedFrameCollector.Frame(displayedMachTime: display, receivedMachTime: received, digest: digest,
            isNewFrame: new)
    }
}

import Darwin
import ApplicationServices
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
        let frames = [
            frame(110, 120, "home"), frame(130, 140, "loading"),
            frame(150, 160, "home"), frame(150, 210, "home", new: false),
            frame(150, 220, "home", new: false), frame(150, 230, "home", new: false),
        ]
        #expect(
            HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 200)?
                .displayedMachTime == 150)
    }

    @Test func transientOrUnconfirmedTerminalRasterIsExcluded() {
        let frames = [frame(110, 210, "home"), frame(120, 220, "loading"), frame(130, 230, "home")]
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 100, observed: 200) == nil)
        let idle = frame(90, 210, "old", new: false)
        #expect(
            HomePresentedFrameCollector.terminalHomeFrame(in: [idle, idle, idle], started: 100, observed: 200) == nil)
        #expect(HomePresentedFrameCollector.terminalHomeFrame(in: frames, started: 201, observed: 200) == nil)
    }

    @Test func observationMustBelongToTheCurrentLoadAndSharedDeadline() throws {
        let request = HomeAXProtocol.Request(
            runID: "run", pid: 42, nonce: UUID().uuidString,
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

    @Test func initialHomePublicationPrecedesWindowAdmissionAndEmptyCannotCompleteCanSettle() throws {
        #expect(try !HomeAXProtocol.mayQueryWindows(sectionCount: 0, expectedSections: 12, onHome: true))
        #expect(try HomeAXProtocol.mayQueryWindows(sectionCount: 12, expectedSections: 12, onHome: true))
        let observations = [
            HomeAXProtocol.WindowQuery(resultCode: AXError.success.rawValue, arrayValue: true, windowCount: 0),
            HomeAXProtocol.WindowQuery(
                resultCode: AXError.cannotComplete.rawValue, arrayValue: false, windowCount: nil),
            HomeAXProtocol.WindowQuery(resultCode: AXError.success.rawValue, arrayValue: true, windowCount: 1),
        ]
        #expect(try observations.map { try $0.disposition() } == [.pending, .pending, .ready])
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.mayQueryWindows(
                sectionCount: 0, expectedSections: 12, onHome: true,
                populatedAlready: true)
        }
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.mayQueryWindows(sectionCount: 12, expectedSections: 12, onHome: false)
        }
    }

    @Test func invalidWindowShapeAmbiguityAndPermanentAPIErrorsNeverAdmitOrRetry() {
        for query in [
            HomeAXProtocol.WindowQuery(resultCode: AXError.success.rawValue, arrayValue: true, windowCount: 2),
            HomeAXProtocol.WindowQuery(resultCode: AXError.success.rawValue, arrayValue: false, windowCount: nil),
            HomeAXProtocol.WindowQuery(resultCode: AXError.apiDisabled.rawValue, arrayValue: false, windowCount: nil),
            HomeAXProtocol.WindowQuery(
                resultCode: AXError.invalidUIElement.rawValue, arrayValue: false, windowCount: nil),
        ] {
            #expect(throws: HomeAXProtocol.Failure.self) { try query.disposition() }
        }
    }

    @Test func staleMissingFutureOrInvalidSafetyPulsesNeverEstablishReadiness() {
        #expect(HomeAXProtocol.pulseIsFresh(recordedAt: 100, now: 103))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: 100, now: 103.001))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: nil, now: 100))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: 102, now: 100))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: .nan, now: 100))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: 100, now: .infinity))
    }

    @Test func markedCapturedWindowSurvivesReorderingAndUnmarkedAuxiliaryWindows() throws {
        let identity = windowIdentity()
        let main = HomeAXProtocol.WindowCandidate(
            pid: 42, role: "AXWindow", identifier: identity.identifier, frame: identity.axFrame)
        let auxiliary = HomeAXProtocol.WindowCandidate(
            pid: 42, role: "AXWindow", identifier: nil, frame: CGRect(x: 16, y: 49, width: 66, height: 20))
        #expect(try HomeAXProtocol.measuredWindowIndex(in: [auxiliary, main], identity: identity) == 1)
        #expect(try HomeAXProtocol.measuredWindowIndex(in: [main, auxiliary], identity: identity) == 0)
        #expect(try HomeAXProtocol.measuredWindowIndex(in: [auxiliary], identity: identity) == nil)
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.measuredWindowIndex(in: [main, main], identity: identity)
        }
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.measuredWindowIndex(in: Array(repeating: auxiliary, count: 9), identity: identity)
        }
        #expect(
            try HomeAXProtocol.WindowQuery(resultCode: 0, arrayValue: true, windowCount: 2)
                .disposition(measuredIdentity: true) == .ready)
    }

    @Test func matchingSizeWrongOwnerRoleOrNonceCannotIdentifyMeasuredWindow() throws {
        let identity = windowIdentity()
        for candidate in [
            HomeAXProtocol.WindowCandidate(
                pid: 43, role: "AXWindow", identifier: identity.identifier, frame: identity.axFrame),
            .init(pid: 42, role: "AXButton", identifier: identity.identifier, frame: identity.axFrame),
            .init(pid: 42, role: "AXWindow", identifier: "another-nonce", frame: identity.axFrame),
            .init(pid: 42, role: "AXWindow", identifier: nil, frame: identity.axFrame),
        ] {
            #expect(try HomeAXProtocol.measuredWindowIndex(in: [candidate], identity: identity) == nil)
        }
        for geometry: CGRect? in [
            nil, .zero, CGRect(x: 0, y: 34, width: 1728, height: 1084),
            CGRect(x: CGFloat.infinity, y: 33, width: 1728, height: 1084),
        ] {
            #expect(throws: HomeAXProtocol.Failure.self) {
                try HomeAXProtocol.measuredWindowIndex(
                    in: [.init(pid: 42, role: "AXWindow", identifier: identity.identifier, frame: geometry)],
                    identity: identity)
            }
        }
        try identity.validate(runID: "owned-run", nonce: "owned-nonce", pid: 42)
        #expect(throws: HomeAXProtocol.Failure.self) {
            try identity.validate(runID: "owned-run", nonce: "different-nonce", pid: 42)
        }
    }

    @Test func malformedWindowAttributeStringsFailInsteadOfWaitingForExport() throws {
        #expect(try HomeAXProtocol.windowString(nil) == nil)
        #expect(try HomeAXProtocol.windowString("AXWindow") == "AXWindow")
        for value: Any in [42, ["AXWindow"], true] {
            #expect(throws: HomeAXProtocol.Failure.self) { try HomeAXProtocol.windowString(value) }
        }
    }

    @Test func primaryDisplayNormalizationHandlesSecondaryDisplaysWithNegativeOrigins() throws {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(
            try HomeAXProtocol.axFrame(CGRect(x: 0, y: 0, width: 1728, height: 1084), primaryDisplay: primary)
                == CGRect(x: 0, y: 33, width: 1728, height: 1084))
        #expect(
            try HomeAXProtocol.axFrame(CGRect(x: -1920, y: -200, width: 960, height: 640), primaryDisplay: primary)
                == CGRect(x: -1920, y: 677, width: 960, height: 640))
        #expect(
            try HomeAXProtocol.axFrame(CGRect(x: 100, y: 1200, width: 960, height: 640), primaryDisplay: primary)
                == CGRect(x: 100, y: -723, width: 960, height: 640))
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.axFrame(.zero, primaryDisplay: primary)
        }
        #expect(throws: HomeAXProtocol.Failure.self) {
            try HomeAXProtocol.axFrame(
                primary, primaryDisplay: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1117))
        }
    }

    private func windowIdentity() -> HomeAXProtocol.MeasuredWindow {
        .init(
            runID: "owned-run", nonce: "owned-nonce", pid: 42, windowNumber: 100,
            identifier: HomeAXProtocol.MeasuredWindow.marker(runID: "owned-run", nonce: "owned-nonce"),
            appKitFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            primaryDisplayAppKitFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            axFrame: CGRect(x: 0, y: 33, width: 1728, height: 1084))
    }

    @Test func safetyRejectionNamesTheObservedPredicateWithoutChangingAdmission() {
        let status: [String: Any] = [
            "runID": "owned", "pid": Int32(42), "state": "workload-running", "recordedAtSeconds": 100.0,
            "networkSandboxVerified": true, "syntheticDependencies": true, "engineUsedForPlayback": false,
            "commandCount": 0, "mutationAttempts": 0,
            "homeProbe": ["sectionCount": 0, "connected": true],
            "window": ["visible": true, "miniaturized": false],
        ]
        func failed(_ pulse: [String: Any], now: Double = 100, populated: Bool = false) -> [String] {
            HomeAXProtocol.safetyPredicates(
                pulse, runID: "owned", pid: 42, sections: 120, measurement: true,
                populatedAlready: populated, now: now
            ).filter { !$0.value }.map(\.key).sorted()
        }
        #expect(failed(status).isEmpty)
        #expect(failed(status, now: 103).isEmpty)
        #expect(failed(status, now: 103.001) == ["pulseFresh"])
        #expect(failed(status, populated: true) == ["sectionsReadyOrInitialGate"])
        for (key, value, predicate): (String, Any, String) in [
            ("runID", "foreign", "runID"), ("pid", Int32(43), "pid"), ("state", "failed", "state"),
            ("networkSandboxVerified", false, "networkDenied"),
            ("syntheticDependencies", false, "syntheticDependencies"),
            ("engineUsedForPlayback", true, "engineUnused"), ("commandCount", 1, "commandsZero"),
            ("mutationAttempts", 1, "mutationsZero"),
        ] {
            var changed = status
            changed[key] = value
            #expect(failed(changed) == [predicate])
        }
        var changed = status
        changed["homeProbe"] = ["sectionCount": 120, "connected": false]
        #expect(failed(changed, populated: true) == ["connected"])
        changed = status
        changed["window"] = ["visible": false, "miniaturized": true]
        #expect(failed(changed) == ["windowNotMiniaturized", "windowVisible"])
    }

    @Test func onlyMatchingAtomicControllerFailureRequestsCooperativeCaptureCleanup() throws {
        let request = HomeAXProtocol.Request(
            runID: "owned", pid: 42, nonce: UUID().uuidString, startedMachTime: 100, deadlineMachTime: 200)
        let result = HomeAXProtocol.ControllerResult(
            runID: request.runID, pid: request.pid, nonce: request.nonce, passed: false,
            deadlineMachTime: request.deadlineMachTime)
        #expect(result.rejects(request))
        for other in [
            HomeAXProtocol.ControllerResult(
                runID: "foreign", pid: 42, nonce: request.nonce, passed: false, deadlineMachTime: 200),
            .init(runID: "owned", pid: 43, nonce: request.nonce, passed: false, deadlineMachTime: 200),
            .init(runID: "owned", pid: 42, nonce: "foreign", passed: false, deadlineMachTime: 200),
            .init(runID: "owned", pid: 42, nonce: request.nonce, passed: true, deadlineMachTime: 200),
            .init(runID: "owned", pid: 42, nonce: request.nonce, passed: false, deadlineMachTime: 201),
        ] { #expect(!other.rejects(request)) }
    }

    @Test func passivePublicationWaitNeverAdmitsStaleUnsafeMalformedOrLaterPhaseActions() {
        let status: [String: Any] = [
            "runID": "owned", "pid": Int32(42), "state": "workload-running", "recordedAtSeconds": 100.0,
            "networkSandboxVerified": true, "syntheticDependencies": true, "engineUsedForPlayback": false,
            "commandCount": 0, "mutationAttempts": 0,
            "homeProbe": ["sectionCount": 0, "connected": true, "onHome": true],
            "window": ["visible": true, "miniaturized": false],
        ]
        func pending(_ pulse: [String: Any], now: Double = 103.1, measured: Bool = true, populated: Bool = false)
            -> Bool
        {
            HomeAXProtocol.mayWaitForPublicationPulse(
                pulse,
                predicates: HomeAXProtocol.safetyPredicates(
                    pulse, runID: "owned", pid: 42, sections: 120, measurement: measured,
                    populatedAlready: populated, now: now),
                measurement: measured, populatedAlready: populated, now: now)
        }
        #expect(pending(status))
        #expect(!HomeAXProtocol.pulseIsFresh(recordedAt: 100, now: 103.1))
        #expect(!pending(status, now: 103))
        #expect(!pending(status, measured: false))
        #expect(!pending(status, populated: true))
        #expect(!pending(status, now: 98))
        for (key, value): (String, Any) in [
            ("runID", "foreign"), ("pid", Int32(43)), ("state", "failed"),
            ("networkSandboxVerified", false), ("syntheticDependencies", false),
            ("engineUsedForPlayback", true), ("commandCount", 1), ("mutationAttempts", 1),
            ("recordedAtSeconds", Double.nan), ("recordedAtSeconds", "malformed"),
            ("homeProbe", ["sectionCount": 120, "connected": false, "onHome": true]),
            ("homeProbe", ["sectionCount": 120, "connected": true, "onHome": false]),
            ("window", ["visible": false, "miniaturized": false]),
            ("window", ["visible": true, "miniaturized": true]),
        ] {
            var changed = status
            changed[key] = value
            #expect(!pending(changed))
        }
        var published = status
        published["homeProbe"] = ["sectionCount": 120, "connected": true, "onHome": true]
        #expect(pending(published))
        #expect(!pending(published, populated: true))
        published["recordedAtSeconds"] = 103.1
        #expect(!pending(published), "fresh publication proceeds through strict admission")
    }

    private func frame(_ display: UInt64, _ received: UInt64, _ digest: String, new: Bool = true)
        -> HomePresentedFrameCollector.Frame
    {
        HomePresentedFrameCollector.Frame(
            displayedMachTime: display, receivedMachTime: received, digest: digest,
            isNewFrame: new)
    }
}

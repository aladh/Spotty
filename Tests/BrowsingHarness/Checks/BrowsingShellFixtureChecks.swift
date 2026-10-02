import AppKit
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

    @Test func changedWorkAreaRequalifiesOnlyTheOwnedWindowOncePerChange() throws {
        let initial = CGRect(x: 0, y: 78, width: 1280, height: 851)
        let desired = CGSize(width: 1220, height: 780)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: desired), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var sizedFrame = initial
        var resizeCount = 0
        func apply(_ frame: CGRect) throws {
            let target = try BrowsingShellRegression.targetBodySize(
                desired: desired, visibleFrame: frame, overhead: .zero)
            window.setContentSize(target)
            window.setFrameOrigin(
                CGPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            sizedFrame = frame
        }
        try apply(initial)
        for frame in [
            initial, CGRect(x: 0, y: 74, width: 1280, height: 855),
            CGRect(x: 0, y: 74, width: 1280, height: 855),
            CGRect(x: 0, y: 0, width: 1024, height: 700),
            CGRect(x: 0, y: 0, width: 1024, height: 700),
        ] {
            _ = try BrowsingShellRegression.requalifyDisplayIfNeeded(sizedFrame: sizedFrame, currentFrame: frame) {
                try apply(frame)
                resizeCount += 1
            }
            #expect(sizedFrame == frame)
            #expect(frame.contains(window.frame))
            // AppKit rounds a half-point frame origin to the backing pixel.
            #expect(abs(window.frame.midY - frame.midY) <= 0.5)
        }
        #expect(resizeCount == 2)
        #expect(window.contentView?.bounds.size == CGSize(width: 1024, height: 700))
        #expect(throws: (any Error).self) {
            _ = try BrowsingShellRegression.requalifyDisplayIfNeeded(sizedFrame: sizedFrame, currentFrame: nil) {
                Issue.record("An unavailable display must not be admitted")
            }
        }
        #expect(throws: (any Error).self) {
            let ineligible = CGRect(x: 0, y: 0, width: 959, height: 700)
            _ = try BrowsingShellRegression.requalifyDisplayIfNeeded(sizedFrame: sizedFrame, currentFrame: ineligible) {
                try apply(ineligible)
            }
        }
        #expect(sizedFrame == CGRect(x: 0, y: 0, width: 1024, height: 700))
    }

    @Test func capturedWorkAreaRejectsRequalificationAndExplicitResize() throws {
        let captured = CGRect(x: 0, y: 78, width: 1280, height: 851)
        let changed = CGRect(x: 0, y: 74, width: 1280, height: 855)
        var resizeCount = 0
        #expect(
            try BrowsingShellRegression.requalifyDisplayIfNeeded(
                sizedFrame: captured, currentFrame: captured, capturedFrame: captured,
                resize: { resizeCount += 1 }) == false)
        #expect(throws: (any Error).self) {
            _ = try BrowsingShellRegression.requalifyDisplayIfNeeded(
                sizedFrame: captured, currentFrame: changed, capturedFrame: captured,
                resize: { resizeCount += 1 })
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let originalFrame = window.frame
        // Exercise the production native resize operation, including admission
        // before either metadata publication or changes to the owned window.
        #expect(throws: (any Error).self) {
            _ = try BrowsingShellRegression.resizeOwnedWindow(
                window, bodySize: CGSize(width: 1080, height: 700), visibleFrame: changed, capturedFrame: captured,
                didQualify: { _ in resizeCount += 1 })
        }
        #expect(window.frame == originalFrame)
        #expect(throws: (any Error).self) {
            _ = try BrowsingShellRegression.requalifyDisplayIfNeeded(
                sizedFrame: changed, currentFrame: changed, capturedFrame: captured,
                resize: { resizeCount += 1 })
        }
        #expect(resizeCount == 0)
    }

    @Test func asynchronousCaptureRejectsUnqualifiedAndFinalDisplayDrift() async throws {
        let initial = CGRect(x: 0, y: 78, width: 1280, height: 851)
        let changed = CGRect(x: 0, y: 74, width: 1280, height: 855)
        var visibleFrame: CGRect? = initial
        var operations = 0
        let stable = try await BrowsingShellRegression.captureOnQualifiedDisplay(
            sizedFrame: initial, capturedFrame: nil, visibleFrame: { visibleFrame },
            operation: {
                operations += 1
                await Task.yield()
                return 42
            })
        #expect(stable.frame == initial && stable.value == 42)
        await #expect(throws: (any Error).self) {
            _ = try await BrowsingShellRegression.captureOnQualifiedDisplay(
                sizedFrame: initial, capturedFrame: initial, visibleFrame: { visibleFrame },
                operation: {
                    operations += 1
                    await Task.yield()
                    visibleFrame = changed
                })
        }
        for frame in [Optional(changed), nil] {
            visibleFrame = frame
            await #expect(throws: (any Error).self) {
                _ = try await BrowsingShellRegression.captureOnQualifiedDisplay(
                    sizedFrame: initial, capturedFrame: nil, visibleFrame: { visibleFrame },
                    operation: { operations += 1 })
            }
        }
        #expect(operations == 2)
    }

    @Test func displayEligibilityPreservesMinimumAndDistinctResizeCoverage() throws {
        let defaultSize = CGSize(width: 1220, height: 780)
        let minimumSize = CGSize(width: 960, height: 640)
        let resizeSize = CGSize(width: 1080, height: 700)
        let overhead = CGSize(width: 0, height: 52)
        #expect(
            try BrowsingShellRegression.targetBodySize(
                desired: defaultSize, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), overhead: overhead)
                == defaultSize)
        // Hosted CI and secondary displays can have a short visible area and negative origins.
        let ciDisplay = CGRect(x: -1440, y: -80, width: 1220, height: 692)
        #expect(
            try BrowsingShellRegression.targetBodySize(
                desired: defaultSize, visibleFrame: ciDisplay, overhead: overhead)
                == CGSize(width: 1220, height: 640))
        #expect(
            try BrowsingShellRegression.targetBodySize(
                desired: minimumSize, visibleFrame: ciDisplay, overhead: overhead)
                == minimumSize)
        #expect(
            try BrowsingShellRegression.targetBodySize(desired: resizeSize, visibleFrame: ciDisplay, overhead: overhead)
                == CGSize(width: 1080, height: 640))
        for display in [
            CGRect(x: 0, y: 0, width: 959, height: 692),
            CGRect(x: 0, y: 0, width: 1220, height: 691),
        ] {
            #expect(throws: (any Error).self) {
                try BrowsingShellRegression.targetBodySize(
                    desired: defaultSize, visibleFrame: display, overhead: overhead)
            }
        }
        for (desired, display, invalidOverhead) in [
            (CGSize(width: CGFloat.infinity, height: 780), ciDisplay, overhead),
            (defaultSize, CGRect(x: CGFloat.nan, y: 0, width: 1220, height: 692), overhead),
            (defaultSize, ciDisplay, CGSize(width: 0, height: CGFloat.nan)),
            (defaultSize, ciDisplay, CGSize(width: -1, height: 52)),
            (defaultSize, ciDisplay, CGSize(width: 0, height: -1)),
        ] {
            #expect(throws: (any Error).self) {
                try BrowsingShellRegression.targetBodySize(
                    desired: desired, visibleFrame: display, overhead: invalidOverhead)
            }
        }
        // A display which can show only the minimum cannot establish a distinct resize.
        for display in [
            CGRect(x: 0, y: 0, width: 960, height: 692),
            CGRect(x: 0, y: 0, width: 962, height: 694),
        ] {
            #expect(throws: (any Error).self) {
                try BrowsingShellRegression.targetBodySize(
                    desired: resizeSize, visibleFrame: display, overhead: overhead)
            }
        }
        #expect(
            try BrowsingShellRegression.targetBodySize(
                desired: resizeSize, visibleFrame: CGRect(x: 0, y: 0, width: 963, height: 692), overhead: overhead)
                == CGSize(width: 963, height: 640))
    }
}

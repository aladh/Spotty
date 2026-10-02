import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import SpottyHarnessSupport
@testable import SpottyCore

/// Controlled initial Home response in the actual Demo scene, before any detail navigation.
@MainActor
enum BrowsingHomePresentedMeasurement {
    static func run(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation,
        window: NSWindow, launch: BrowsingLaunch, networkSandboxVerified: Bool
    ) async throws {
        defer { world.homeResponse.close() }
        let originalFrame = window.frame
        let originalScale = window.backingScaleFactor
        let root = URL(fileURLWithPath: launch.runRoot)
        let collector = HomePresentedFrameCollector()
        let queue = DispatchQueue(label: "dev.spotty.actual-home-frames")
        var stream: SCStream?
        var capturing = false
        var evidence: [String: Any] = [
            "schemaVersion": 1, "launchRunID": launch.runID, "sourceSHA256": launch.source.sourceSHA256,
            "syntheticDependencies": true, "networkSandboxVerified": networkSandboxVerified,
            "engineUsedForPlayback": false, "performanceMeasurement": true,
            "kind": "controlled synthetic Home response in actual Demo scene",
            "limitations":
                "Warm connected scene; nil fixture art; external AX readiness observation; terminal raster onset is retrospective. Not cold launch, earliest usable frame, loaded artwork, or visual parity. Footprints include capture buffers, SHA256 hashing, AX observation, and sampling instrumentation; not isolated Home allocation.",
        ]
        func safety(onHome: Bool = true) throws {
            guard networkSandboxVerified, !launch.automated, !player.isPlaying,
                world.playback.snapshot().commandCount == 0, world.snapshot().mutationAttempts == 0,
                CatalogPlaybackAccess(player: player).isConnected, window.isVisible, !window.isMiniaturized,
                window.occlusionState.contains(.visible), window.frame == originalFrame,
                window.backingScaleFactor == originalScale, NSApp.windows.contains(where: { $0 === window }),
                !onHome || navigation.selection == .destination(.home),
                abs(navigation.homeInteraction.scrollOffset) < 1
            else { throw BrowsingFailure.checkpoint("home-measurement.isolation") }
        }
        func stop() async throws {
            if capturing, let stream {
                try await stream.stopCapture()
                capturing = false
                await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
            }
        }
        do {
            let request = try JSONDecoder().decode(
                HomeAXProtocol.Request.self, from: Data(contentsOf: root.appendingPathComponent("home-ax-request.json"))
            )
            try request.validate(
                runID: launch.runID, pid: ProcessInfo.processInfo.processIdentifier, now: mach_absolute_time())
            func prerequisite(onHome: Bool = true, _ condition: () -> Bool) async throws {
                while !condition() {
                    try request.validate(
                        runID: launch.runID, pid: ProcessInfo.processInfo.processIdentifier, now: mach_absolute_time())
                    try safety(onHome: onHome)
                    try await ContinuousClock().sleep(for: .milliseconds(25))
                }
                try request.validate(
                    runID: launch.runID, pid: ProcessInfo.processInfo.processIdentifier, now: mach_absolute_time())
                try safety(onHome: onHome)
            }
            try safety()
            guard let count = world.scenario.homePresentedProbeSections,
                world.homeResponse.isWaiting, player.catalog.homeLibrary.homeSections.isEmpty
            else { throw BrowsingFailure.checkpoint("home-measurement.initial-gate") }
            evidence["sectionCount"] = count
            evidence["externalRequestNonce"] = request.nonce
            evidence["connected"] = true
            evidence["sharedDeadlineMachTime"] = request.deadlineMachTime
            evidence["contentWidth"] = window.contentView?.bounds.width
            evidence["contentHeight"] = window.contentView?.bounds.height
            evidence["windowFramePoints"] = NSStringFromRect(window.frame)
            evidence["displayScale"] = window.backingScaleFactor
            let available = try await SCShareableContent.currentProcess
            guard let shared = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                shared.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            else { throw BrowsingFailure.checkpoint("home-measurement.owned-window") }
            let width = Int((window.frame.width * window.backingScaleFactor).rounded())
            let height = Int((window.frame.height * window.backingScaleFactor).rounded())
            guard (1...4_096).contains(width), (1...4_096).contains(height) else {
                throw BrowsingFailure.checkpoint("home-measurement.capture-size")
            }
            evidence["captureWidthPixels"] = width
            evidence["captureHeightPixels"] = height
            evidence["captureFramesPerSecond"] = 30
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.captureMicrophone = false
            configuration.ignoreShadowsSingleWindow = true
            let owned = SCStream(
                filter: SCContentFilter(desktopIndependentWindow: shared), configuration: configuration, delegate: nil)
            try owned.addStreamOutput(collector, type: .screen, sampleHandlerQueue: queue)
            stream = owned
            try await owned.startCapture()
            capturing = true
            try await prerequisite { !collector.snapshot.frames.isEmpty }
            evidence["beforeHomePhysicalFootprintBytes"] = try footprint()
            evidence["beforeHomeNativeViewCount"] = window.contentView.map(nativeViewCount) ?? 0
            let started = mach_absolute_time()
            evidence["loadStartMachTime"] = started
            // The capture is primed while the synthetic provider is still suspended.
            world.homeResponse.resume()
            try HomeAXProtocol.publish(
                JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                to: root.appendingPathComponent("home-ax-armed.json"))
            let observedPath = root.appendingPathComponent("home-ax-observed.json")
            try await prerequisite {
                player.catalog.homeLibrary.homeSections.count == count
                    && FileManager.default.fileExists(atPath: observedPath.path)
            }
            let observation = try JSONDecoder().decode(
                HomeAXProtocol.Observation.self, from: Data(contentsOf: observedPath))
            try observation.validate(request: request, loadStarted: started, now: mach_absolute_time())
            let observed = observation.observedMachTime
            evidence["externalReadyObservedMachTime"] = observed
            try await prerequisite {
                HomePresentedFrameCollector.terminalHomeFrame(
                    in: collector.snapshot.frames, started: started, observed: observed) != nil
            }
            try await stop()
            try safety()
            let captured = collector.snapshot
            guard !captured.exceededBound,
                let frame = HomePresentedFrameCollector.terminalHomeFrame(
                    in: captured.frames, started: started, observed: observed)
            else { throw BrowsingFailure.checkpoint("home-measurement.terminal-raster") }
            evidence["homePhysicalFootprintBytes"] = try footprint()
            evidence["homeNativeViewCount"] = window.contentView.map(nativeViewCount) ?? 0
            evidence["homeResponseToExternalObservationSeconds"] = HomePresentedFrameCollector.seconds(
                from: started, to: observed)
            evidence["homeResponseToTerminalRasterOnsetSeconds"] = HomePresentedFrameCollector.seconds(
                from: started, to: frame.displayedMachTime)
            evidence["terminalRasterDigest"] = frame.digest
            evidence["frames"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captured.frames))
            evidence["measuredBeforeNavigation"] = true
            evidence["measurementStageComplete"] = true
            evidence["functionalActivationPending"] = true
            try HomeAXProtocol.publish(
                JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                to: root.appendingPathComponent("home-presented-measurement.json"))
            // Functional activation is separate and occurs only after Home capture and sampling finish.
            try await prerequisite(onHome: false) { navigation.selection == .album("spotify:album:0-0") }
            try HomeAXProtocol.publish(
                JSONSerialization.data(
                    withJSONObject: [
                        "externalRequestNonce": request.nonce, "selectionConfirmed": true,
                        "selectionConfirmedMachTime": mach_absolute_time(),
                    ], options: [.prettyPrinted, .sortedKeys]),
                to: root.appendingPathComponent("home-measurement-accepted.json"))
        } catch {
            let primary = error
            do { try await stop() } catch { evidence["captureStopError"] = String(describing: error) }
            evidence["error"] = String(describing: primary)
            evidence["frames"] = try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode(collector.snapshot.frames))
            evidence["frameBoundExceeded"] = collector.snapshot.exceededBound
            do {
                try HomeAXProtocol.publish(
                    JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                    to: root.appendingPathComponent("home-presented-measurement.failure.json"))
            } catch {
                FileHandle.standardError.write(
                    Data("Home measurement receipt failed: \(error); primary: \(primary)\n".utf8))
            }
            throw primary
        }
    }

    private static func nativeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + nativeViewCount($1) }
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw BrowsingFailure.checkpoint("home-measurement.footprint") }
        return info.phys_footprint
    }
}

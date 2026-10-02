import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import SpottyDomain
import SpottyTestSupport
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

/// Explicit opt-in only: presents one owned synthetic Home window and captures only that window.
@MainActor
struct HomePresentedMeasurementChecks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_HOME_PRESENTED_REPORT"] != nil))
    func measurePresentedHome() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["SPOTTY_HOME_PRESENTED_REPORT"])
        let count = try #require(Int(env["SPOTTY_HOME_PRESENTED_SECTIONS"] ?? "120"))
        try #require([12, 120].contains(count))
        try #require(!FileManager.default.fileExists(atPath: path))
        try #require(!FileManager.default.fileExists(atPath: path + ".failure.json"))
        let provider = HarnessCatalog()
        provider.onHome = {
            CatalogHomeSnapshot(
                greeting: "Synthetic Home",
                sections: (0..<count).map { section in
                    CatalogSection(
                        id: "section:\(section)", title: "Synthetic shelf \(section)",
                        items: (0..<8).map { item in
                            let id = "\(section)-\(item)"
                            return CatalogItem(
                                id: id, uri: "spotify:album:\(id)", title: "Synthetic album \(id)",
                                subtitle: "Synthetic artist",
                                artworkURL: URL(string: "https://synthetic.invalid/\(section)/\(item)"), kind: .album)
                        })
                })
        }
        let artwork = HarnessArtwork(immediateFailure: .unavailable)
        let engine = HarnessEngine()
        let remote = HarnessRemote()
        let mutations = HarnessPlaylistMutations()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: remote, catalog: provider, playlistMutations: mutations))
        func safety() -> [String: Any] {
            [
                "syntheticDependencies": true, "engineUsedForPlayback": false,
                "engineCommands": engine.executeCount, "remoteCommands": remote.sendCount,
                "playlistMutations": mutations.addCalls.count + mutations.removeCalls.count,
            ]
        }
        func requireSafety() throws {
            try #require(engine.executeCount == 0 && remote.sendCount == 0)
            try #require(mutations.addCalls.isEmpty && mutations.removeCalls.isEmpty)
        }
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        let interaction = HomeInteractionState()
        var selectedID: String?
        let host = NSHostingView(
            rootView: HomeView(
                store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                interaction: interaction, onSelect: { selectedID = $0.id }
            ).environment(\.artworkAccess, ArtworkAccess(provider: artwork, accountEpoch: 1)))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        var stream: SCStream?
        let callbackQueue = DispatchQueue(label: "dev.spotty.home-frame-probe")
        let collector = HomePresentedFrameCollector()
        var phase = "own-window capture admission"
        var observedTimes: [String: UInt64] = [:]
        var observedFootprints: [String: UInt64] = [:]
        var captureStarted = false
        var captureStopped = false
        var readinessEvidence: [String: Any] = [:]
        do {
            try requireSafety()
            let available = try await SCShareableContent.currentProcess
            let shared = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            try #require(shared.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((900 * window.backingScaleFactor).rounded())
            configuration.height = Int((600 * window.backingScaleFactor).rounded())
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.captureMicrophone = false
            configuration.ignoreShadowsSingleWindow = true
            let owned = SCStream(
                filter: SCContentFilter(desktopIndependentWindow: shared), configuration: configuration,
                delegate: nil)
            try owned.addStreamOutput(
                collector, type: .screen, sampleHandlerQueue: callbackQueue)
            stream = owned
            try await owned.startCapture()
            captureStarted = true
            phase = "capture priming"
            try await requireEventually(description: "Own-window capture is primed before the Home load") {
                !collector.snapshot.frames.isEmpty
            }
            let before = try footprint()
            observedFootprints["beforeHomeLoadBytes"] = before
            try requireSafety()
            let started = mach_absolute_time()
            observedTimes["loadStartMachTime"] = started
            phase = "native extent threshold"
            await player.catalog.homeLibrary.loadHome()
            var activationAttempted = false
            var activationAccepted = false
            // All readiness phases share the original single ten-second prerequisite deadline.
            try await requireEventually(description: "Home extent and exact synthetic selection callback readiness") {
                host.layoutSubtreeIfNeeded()
                let height = page(in: host)?.documentView?.bounds.height ?? 0
                readinessEvidence["documentHeight"] = height
                readinessEvidence["sectionCount"] = player.catalog.homeLibrary.homeSections.count
                readinessEvidence["connected"] = CatalogPlaybackAccess(player: player).isConnected
                guard height > CGFloat(count * 200) else {
                    phase = "native extent threshold"
                    return false
                }
                if observedTimes["extentThresholdMachTime"] == nil {
                    observedTimes["extentThresholdMachTime"] = mach_absolute_time()
                }
                if !activationAttempted {
                    phase = "exact visible detail-control discovery"
                    let discovered = HomePresentedAccessibilityProbe.discover(
                        in: window, visibleFrame: window.frame, label: "Synthetic album 0-0")
                    readinessEvidence["accessibility"] = discovered.evidence
                    guard let button = discovered.control else { return false }
                    observedTimes["detailControlDiscoveredMachTime"] = mach_absolute_time()
                    activationAttempted = true
                    readinessEvidence["activationAttempted"] = true
                    phase = "single detail-control activation"
                    activationAccepted = button.accessibilityPerformPress()
                    readinessEvidence["activationAccepted"] = activationAccepted
                    observedTimes["detailControlPressedMachTime"] = mach_absolute_time()
                }
                readinessEvidence["selectedID"] = selectedID as Any? ?? NSNull()
                if activationAccepted { phase = "synthetic selection callback acceptance" }
                return activationAccepted && selectedID == "0-0"
            }
            let ready = mach_absolute_time()
            try requireSafety()
            observedTimes["syntheticSelectionReadyMachTime"] = ready
            let readyFootprint = try footprint()
            observedFootprints["syntheticSelectionReadyBytes"] = readyFootprint
            phase = "visible artwork admission"
            try await requireEventually(description: "Initially visible artwork requests settle") {
                await artwork.requests.contains { $0.url.path == "/1/0" }
            }
            phase = "post-readiness terminal raster"
            try await requireEventually(description: "Three own-window events confirm the terminal raster") {
                HomePresentedFrameCollector.firstSteadyFrame(
                    in: collector.snapshot.frames, started: started, ready: ready) != nil
            }
            phase = "capture stop and callback drain"
            try await owned.stopCapture()
            captureStopped = true
            stream = nil
            await drain(callbackQueue)
            let captured = collector.snapshot
            try #require(!captured.exceededBound)
            let first = try #require(
                HomePresentedFrameCollector.firstSteadyFrame(in: captured.frames, started: started, ready: ready))
            let requests = await artwork.requests
            try #require(requests.count <= 16)
            let scroll = try #require(page(in: host))
            let report: [String: Any] = [
                "sections": count, "itemsPerSection": 8, "viewportWidth": 900, "viewportHeight": 600,
                "displayScale": window.backingScaleFactor,
                "captureFramesPerSecond": 30, "captureQueueDepth": 3,
                "captureSource": "ScreenCaptureKit.currentProcess.own-window",
                "loadStartMachTime": started, "syntheticSelectionReadyMachTime": ready,
                "firstQualifiedRasterDisplayedMachTime": first.displayedMachTime,
                "firstQualifiedRasterReceivedMachTime": first.receivedMachTime,
                "loadToSyntheticSelectionReadySeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: started, to: ready)),
                "loadToFirstQualifiedRasterDisplayedSeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: started, to: first.displayedMachTime)),
                "captureDeliveryDelaySeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: first.displayedMachTime, to: first.receivedMachTime)),
                "documentHeight": try #require(scroll.documentView).bounds.height,
                "documentHeightReadinessThreshold": count * 200,
                "readinessEvidence": readinessEvidence,
                "nativeViewCount": nativeViewCount(host), "artworkAdmissions": requests.count,
                "beforePhysicalFootprintBytes": before, "readyPhysicalFootprintBytes": readyFootprint,
                "captureStoppedPhysicalFootprintBytes": try footprint(),
                "safety": safety(),
                "frames": captured.frames.map {
                    [
                        "displayedMachTime": $0.displayedMachTime, "receivedMachTime": $0.receivedMachTime,
                        "digest": $0.digest,
                        "isNewFrame": $0.isNewFrame,
                    ] as [String: Any]
                },
                "limitations":
                    "Synthetic production Home surface, not full app startup/network/audio. Primed own-window compositor capture; first matching terminal raster after the document-height threshold and successful visible detail-control AX activation. The threshold does not prove exact full extent. Three consecutive complete/idle events confirm the terminal raster. This is the first captured terminal-raster match after observed readiness, not proof of the earliest possible usable frame; a raster displayed only before readiness remains unmeasured. Capture does not prove unobscured screen visibility or human input latency. Includes forced-layout polling, AX traversal/activation, sampling/SHA256 overhead and three capture buffers; no raw pixels retained. Immediate unavailable artwork excludes decode/raster/network. No live-account, full keyboard traversal or visual parity claim.",
            ]
            await player.shutdownForTermination()
            try requireSafety()
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        } catch {
            let primary = error
            var cleanupError: String?
            if let stream {
                do {
                    try await stream.stopCapture()
                    captureStopped = true
                } catch let cleanup {
                    cleanupError = String(describing: cleanup)
                }
            }
            await drain(callbackQueue)
            await player.shutdownForTermination()
            let captured = collector.snapshot
            let failure: [String: Any] = [
                "sections": count, "phase": phase, "primaryError": String(describing: primary),
                "cleanupError": cleanupError as Any? ?? NSNull(),
                "captureStarted": captureStarted, "captureStopSucceeded": captureStopped,
                "callbackQueueDrained": true, "playerShutdownCompleted": true,
                "observedTimes": observedTimes, "observedFootprints": observedFootprints,
                "frameBoundExceeded": captured.exceededBound,
                "readinessEvidence": readinessEvidence,
                "safety": safety(),
                "frames": captured.frames.map {
                    [
                        "displayedMachTime": $0.displayedMachTime, "receivedMachTime": $0.receivedMachTime,
                        "digest": $0.digest, "isNewFrame": $0.isNewFrame,
                    ] as [String: Any]
                },
            ]
            do {
                try JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path + ".failure.json"), options: .withoutOverwriting)
            } catch {
                Issue.record("Failure receipt could not be written: \(error)")
            }
            if let cleanupError {
                throw HomePresentedCleanupFailure(primary: String(describing: primary), cleanup: cleanupError)
            }
            throw primary
        }
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func page(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { page(in: $0) }.first
    }

    private func nativeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + nativeViewCount($1) }
    }

    private func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS)
        return info.phys_footprint
    }
}

private struct HomePresentedCleanupFailure: Error {
    let primary: String
    let cleanup: String
}

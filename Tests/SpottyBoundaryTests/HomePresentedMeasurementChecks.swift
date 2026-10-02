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
                                id: id, uri: "spotify:album:\(id)", title: "Synthetic album",
                                subtitle: "Synthetic artist",
                                artworkURL: URL(string: "https://synthetic.invalid/\(section)/\(item)"), kind: .album)
                        })
                })
        }
        let artwork = HarnessArtwork(immediateFailure: .unavailable)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
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
        do {
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
            let collector = HomePresentedFrameCollector()
            let owned = SCStream(
                contentFilter: SCContentFilter(desktopIndependentWindow: shared), configuration: configuration,
                delegate: nil)
            try owned.addStreamOutput(
                collector, type: .screen, sampleHandlerQueue: callbackQueue)
            stream = owned
            try await owned.startCapture()
            try await requireEventually(description: "Own-window capture is primed before the Home load") {
                !collector.snapshot.frames.isEmpty
            }
            let before = try footprint()
            let started = mach_absolute_time()
            await player.catalog.homeLibrary.loadHome()
            try await requireEventually(description: "Complete Home extent and a visible detail control can activate") {
                host.layoutSubtreeIfNeeded()
                guard (page(in: host)?.documentView?.bounds.height ?? 0) > CGFloat(count * 200),
                    let button = visibleDetailControl(in: window)
                else { return false }
                return button.accessibilityPerformPress() && selectedID == "0-0"
            }
            let ready = mach_absolute_time()
            let readyFootprint = try footprint()
            try await requireEventually(description: "Initially visible artwork requests settle") {
                await artwork.requests.contains { $0.url.path == "/1/0" }
            }
            try await requireEventually(description: "Three own-window events confirm the terminal raster") {
                HomePresentedFrameCollector.firstSteadyFrame(
                    in: collector.snapshot.frames, started: started, ready: ready) != nil
            }
            try await owned.stopCapture()
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
                "loadStartMachTime": started, "nativeInputReadyMachTime": ready,
                "firstQualifiedRasterDisplayedMachTime": first.displayedMachTime,
                "firstQualifiedRasterReceivedMachTime": first.receivedMachTime,
                "loadToNativeInputReadySeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: started, to: ready)),
                "loadToFirstQualifiedRasterDisplayedSeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: started, to: first.displayedMachTime)),
                "captureDeliveryDelaySeconds": try #require(
                    HomePresentedFrameCollector.seconds(from: first.displayedMachTime, to: first.receivedMachTime)),
                "documentHeight": try #require(scroll.documentView).bounds.height,
                "nativeViewCount": nativeViewCount(host), "artworkAdmissions": requests.count,
                "beforePhysicalFootprintBytes": before, "readyPhysicalFootprintBytes": readyFootprint,
                "captureStoppedPhysicalFootprintBytes": try footprint(),
                "frames": captured.frames.map {
                    [
                        "displayedMachTime": $0.displayedMachTime, "receivedMachTime": $0.receivedMachTime,
                        "digest": $0.digest,
                        "isNewFrame": $0.isNewFrame,
                    ] as [String: Any]
                },
                "limitations":
                    "Synthetic production Home surface, not full app startup/network/audio. Primed own-window compositor capture; first matching terminal raster after complete extent and successful visible detail-control AX activation. Three consecutive complete/idle events confirm the terminal raster. This is the first captured terminal-raster match after observed readiness, not proof of the earliest possible usable frame; a raster displayed only before readiness remains unmeasured. Capture does not prove unobscured screen visibility or human input latency. Includes sampling/SHA256 overhead and three capture buffers; no raw pixels retained. Immediate unavailable artwork excludes decode/raster/network. No live-account, full keyboard traversal or visual parity claim.",
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            await player.shutdownForTermination()
        } catch {
            if let stream {
                do { try await stream.stopCapture() } catch let cleanup {
                    await drain(callbackQueue)
                    await player.shutdownForTermination()
                    throw HomePresentedCleanupFailure(
                        primary: String(describing: error), cleanup: String(describing: cleanup))
                }
            }
            await drain(callbackQueue)
            await player.shutdownForTermination()
            throw error
        }
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func visibleDetailControl(in window: NSWindow) -> (any NSAccessibilityProtocol)? {
        var pending: [Any] = [window]
        var inspected = 0
        while let element = pending.popLast(), inspected < 10_000 {
            inspected += 1
            guard let accessible = element as? any NSAccessibilityProtocol else { continue }
            if accessible.accessibilityRole() == .button,
                accessible.accessibilityLabel() == "Synthetic album",
                accessible.isAccessibilityEnabled(),
                accessible.accessibilityFrame().intersects(window.frame)
            {
                return accessible
            }
            pending.append(contentsOf: (accessible.accessibilityChildren() ?? []).reversed())
        }
        return nil
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

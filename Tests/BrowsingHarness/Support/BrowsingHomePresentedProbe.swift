import AppKit
import Darwin
import Foundation
@testable import SpottyCore

/// Causal diagnostic in the real SwiftUI application lifecycle, with synthetic ports only.
@MainActor
enum BrowsingHomePresentedProbe {
    static func run(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation,
        window: NSWindow, launch: BrowsingLaunch, networkSandboxVerified: Bool
    ) async throws {
        let output = URL(fileURLWithPath: launch.runRoot).appendingPathComponent("home-presented-diagnostic.json")
        var evidence: [String: Any] = [
            "schemaVersion": 1, "launchRunID": launch.runID, "sourceSHA256": launch.source.sourceSHA256,
            "syntheticDependencies": true, "networkSandboxVerified": networkSandboxVerified,
            "engineUsedForPlayback": false, "kind": "actual-app public AX readiness diagnostic",
            "performanceMeasurement": false,
        ]
        func requireSafety() throws {
            let commands = world.playback.snapshot().commandCount
            let mutations = world.snapshot().mutationAttempts
            evidence["commands"] = commands
            evidence["mutations"] = mutations
            guard networkSandboxVerified, !player.isPlaying, commands == 0, mutations == 0 else {
                throw BrowsingFailure.checkpoint("home-probe.isolation")
            }
        }
        do {
            try requireSafety()
            guard let count = world.scenario.homePresentedProbeSections,
                player.catalog.homeLibrary.homeSections.count == count,
                CatalogPlaybackAccess(player: player).isConnected,
                navigation.selection == .destination(.home), window.isVisible, !window.isMiniaturized,
                NSApp.windows.contains(where: { $0 === window }),
                navigation.homeInteraction.scrollOffset.isFinite, abs(navigation.homeInteraction.scrollOffset) < 1,
                let content = window.contentView, content.bounds.width > 0, content.bounds.height > 0
            else { throw BrowsingFailure.checkpoint("home-probe.catalog") }
            evidence["sectionCount"] = count
            evidence["connected"] = true
            evidence["windowNumber"] = window.windowNumber
            evidence["windowIdentifier"] = window.identifier?.rawValue as Any? ?? NSNull()
            evidence["retainedHomeScrollOffsetPoints"] = navigation.homeInteraction.scrollOffset
            evidence["contentWidth"] = content.bounds.width
            evidence["contentHeight"] = content.bounds.height
            if !launch.automated {
                try await awaitExternalSelection(
                    player: player, world: world, navigation: navigation, window: window, launch: launch,
                    evidence: &evidence)
                try requireSafety()
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .withoutOverwriting)
                return
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var pressed = false
            var accepted = false
            while ContinuousClock.now < deadline {
                try requireSafety()
                // Use normal app layout scheduling, without forcing a redraw for readiness.
                if !pressed {
                    let result = discover(in: window, visibleFrame: window.frame)
                    evidence["accessibility"] = result.evidence
                    if let button = result.control {
                        evidence["discoveredMachTime"] = mach_absolute_time()
                        evidence["homePhysicalFootprintBytes"] = try footprint()
                        evidence["sectionCount"] = count
                        pressed = true
                        accepted = button.accessibilityPerformPress()
                        evidence["activationAccepted"] = accepted
                    }
                }
                if accepted, navigation.selection == .album("spotify:album:0-0") {
                    evidence["selectionConfirmedMachTime"] = mach_absolute_time()
                    evidence["ready"] = true
                    try requireSafety()
                    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output, options: .withoutOverwriting)
                    return
                }
                try await ContinuousClock().sleep(for: .milliseconds(25))
            }
            evidence["navigationRawValue"] = navigation.rawValue
            throw BrowsingFailure.checkpoint("home-probe.public-ax-readiness")
        } catch {
            let primary = error
            evidence["ready"] = false
            evidence["error"] = String(describing: error)
            do {
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .withoutOverwriting)
            } catch {
                FileHandle.standardError.write(
                    Data("Home diagnostic receipt failed: \(error); primary failure: \(primary)\n".utf8))
            }
            throw primary
        }
    }

    private static func awaitExternalSelection(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation,
        window: NSWindow, launch: BrowsingLaunch, evidence: inout [String: Any]
    ) async throws {
        let root = URL(fileURLWithPath: launch.runRoot)
        let request = try JSONDecoder().decode(
            ExternalRequest.self, from: Data(contentsOf: root.appendingPathComponent("home-ax-request.json")))
        try request.validate(
            runID: launch.runID, pid: ProcessInfo.processInfo.processIdentifier, now: mach_absolute_time())
        evidence["externalRequestNonce"] = request.nonce
        evidence["sharedStartedMachTime"] = request.startedMachTime
        evidence["sharedDeadlineMachTime"] = request.deadlineMachTime
        evidence["accessibility"] = discover(in: window, visibleFrame: window.frame).evidence
        evidence["preNavigationPhysicalFootprintBytes"] = try footprint()
        evidence["preNavigationNativeViewCount"] = window.contentView.map(nativeViewCount) ?? 0
        try HomeAXProtocol.publish(
            JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            to: root.appendingPathComponent("home-ax-armed.json"))
        while mach_absolute_time() < request.deadlineMachTime {
            guard !player.isPlaying, world.playback.snapshot().commandCount == 0,
                world.snapshot().mutationAttempts == 0, CatalogPlaybackAccess(player: player).isConnected
            else { throw BrowsingFailure.checkpoint("home-probe.external-isolation") }
            if navigation.selection == .album("spotify:album:0-0") {
                evidence["selectionConfirmedMachTime"] = mach_absolute_time()
                evidence["ready"] = true
                evidence["activationSource"] = "separately admitted public external AX controller"
                return
            }
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        throw BrowsingFailure.checkpoint("home-probe.external-selection")
    }

    typealias ExternalRequest = HomeAXProtocol.Request

    private static func nativeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + nativeViewCount($1) }
    }

    static func discover(in root: Any, visibleFrame: NSRect, limit: Int = 10_000) -> (
        control: (any NSAccessibilityProtocol)?, evidence: [String: Any]
    ) {
        var pending: [(element: Any, path: [Int])] = [(root, [])]
        var inspected = 0
        var buttons = 0
        var unsupported = 0
        var samples: [[String: Any]] = []
        var pruned: [[String: Any]] = []
        while let entry = pending.popLast(), inspected < limit {
            inspected += 1
            guard let accessible = entry.element as? any NSAccessibilityProtocol else {
                unsupported += 1
                if let object = entry.element as? NSObject, pruned.count < 16 {
                    pruned.append([
                        "childIndexPath": Array(entry.path.prefix(32)),
                        "publicRoleAccessor": object.responds(to: #selector(NSAccessibilityProtocol.accessibilityRole)),
                        "publicChildrenAccessor": object.responds(
                            to: #selector(NSAccessibilityProtocol.accessibilityChildren)),
                        "publicLabelAccessor": object.responds(
                            to: #selector(NSAccessibilityProtocol.accessibilityLabel)),
                    ])
                }
                continue
            }
            if samples.count < 32 {
                samples.append([
                    "childIndexPath": Array(entry.path.prefix(32)),
                    "role": accessible.accessibilityRole()?.rawValue ?? "",
                    "label": accessible.accessibilityLabel() ?? "",
                ])
            }
            if accessible.accessibilityRole() == .button {
                buttons += 1
                let frame = accessible.accessibilityFrame()
                if accessible.accessibilityLabel() == "Synthetic album 0-0",
                    accessible.isAccessibilityEnabled(), !frame.isEmpty, frame.intersects(visibleFrame)
                {
                    return (
                        accessible,
                        [
                            "inspectedElements": inspected, "buttonCount": buttons, "targetFound": true,
                            "unsupportedElements": unsupported,
                            "publicSamples": samples, "prunedPublicAccessors": pruned,
                        ]
                    )
                }
            }
            for (index, child) in (accessible.accessibilityChildren() ?? []).enumerated().reversed() {
                pending.append((child, entry.path + [index]))
            }
        }
        return (
            nil,
            [
                "inspectedElements": inspected, "buttonCount": buttons, "targetFound": false,
                "unsupportedElements": unsupported, "limitReached": inspected >= limit,
                "publicSamples": samples, "prunedPublicAccessors": pruned,
            ]
        )
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw BrowsingFailure.checkpoint("home-probe.footprint") }
        return info.phys_footprint
    }
}

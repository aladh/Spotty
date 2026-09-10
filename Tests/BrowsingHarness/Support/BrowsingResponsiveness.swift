import AppKit
import Foundation
import Observation
import OSLog
import QuartzCore
@testable import SpottyCore

struct BrowsingResponsivenessReport: Codable {
    let observerInvalidations: [String: Int]
    let displayCallbackCount: Int
    let callbackGapP95Milliseconds: Double
    let callbackGapP99Milliseconds: Double
    let maximumCallbackGapMilliseconds: Double
    let missedDisplayOpportunityCount: Int
    let reducedMotion: Bool
    let nominalFramesPerSecond: Int
    let windowVisibleAtStart: Bool
    let windowVisibleAtEnd: Bool
}

/// Demo-only instrumentation. Display-link gaps measure main-run-loop opportunities, not GPU
/// frame presentation. Keep that distinction in the report rather than claiming rendered FPS.
@MainActor
final class BrowsingResponsiveness: NSObject {
    private let player: PlaybackStore
    private var active = false
    private var link: CADisplayLink?
    private var previousCallback: CFTimeInterval?
    private var gaps: [Double] = []
    private var missed = 0
    private var callbackCount = 0
    private var counts: [String: Int] = [:]
    private var refreshRate = 0
    private weak var window: NSWindow?
    private var visibleAtStart = false
    private let signposter = OSSignposter(subsystem: "dev.spotty.demo", category: "Measurement")
    private var interval: OSSignpostIntervalState?

    init(player: PlaybackStore) { self.player = player }

    func start(window: NSWindow) {
        guard !active else { return }
        active = true
        self.window = window
        visibleAtStart = window.occlusionState.contains(.visible)
        interval = signposter.beginInterval("Demo workload")
        refreshRate = window.screen?.maximumFramesPerSecond ?? 0
        for key in ["nowPlaying", "devices", "queue", "catalogIndicator", "timing"] { observe(key) }
        let link = window.displayLink(target: self, selector: #selector(displayTick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() -> BrowsingResponsivenessReport {
        if let interval {
            signposter.endInterval("Demo workload", interval)
            self.interval = nil
        }
        active = false
        link?.invalidate()
        link = nil
        let ordered = gaps.sorted()
        func percentile(_ p: Double) -> Double {
            guard !ordered.isEmpty else { return 0 }
            return ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * p))]
        }
        return BrowsingResponsivenessReport(
            observerInvalidations: counts, displayCallbackCount: callbackCount,
            callbackGapP95Milliseconds: percentile(0.95), callbackGapP99Milliseconds: percentile(0.99),
            maximumCallbackGapMilliseconds: ordered.last ?? 0, missedDisplayOpportunityCount: missed,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            nominalFramesPerSecond: refreshRate, windowVisibleAtStart: visibleAtStart,
            windowVisibleAtEnd: window?.occlusionState.contains(.visible) ?? false)
    }

    private func observe(_ key: String) {
        guard active else { return }
        withObservationTracking {
            switch key {
            case "nowPlaying":
                _ = player.displayedTrackTitle; _ = player.displayedArtistName
                _ = player.isPlaying; _ = player.canTogglePlayback
            case "devices": _ = player.connectDevices; _ = player.activeRemoteDevice
            case "queue": _ = player.queueNextEntries
            case "catalogIndicator": _ = player.currentTrackIndicator
            default: _ = player.position; _ = player.positionAnchorDate
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.counts[key, default: 0] += 1
                self.observe(key)
            }
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        callbackCount += 1
        let now = CACurrentMediaTime()
        defer { previousCallback = now }
        guard let previousCallback, gaps.count < 100_000 else { return }
        let gap = now - previousCallback
        gaps.append(gap * 1_000)
        let expected = link.targetTimestamp - link.timestamp
        if expected > 0, gap > expected * 1.5 { missed += max(1, Int((gap / expected).rounded()) - 1) }
    }
}

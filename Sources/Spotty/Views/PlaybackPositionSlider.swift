import AppKit
import SwiftUI

/// NSSlider owns dragging, keyboard adjustment, focus, and accessibility. Noncontinuous
/// target/action commits once on mouse release; authoritative updates never move a tracked thumb.
struct PlaybackPositionSlider: NSViewRepresentable {
    let position: Double
    let duration: Double
    let isEnabled: Bool
    let commit: (Double) -> Void

    func makeNSView(context: Context) -> PositionSlider {
        let slider = PositionSlider()
        slider.minValue = 0
        slider.altIncrementValue = 10
        slider.isContinuous = false
        slider.target = slider
        slider.action = #selector(PositionSlider.commitPosition)
        slider.setAccessibilityLabel("Playback position")
        return slider
    }

    func updateNSView(_ slider: PositionSlider, context: Context) {
        slider.commit = commit
        slider.isEnabled = isEnabled
        slider.setAccessibilityEnabled(isEnabled)
        slider.accessibleDuration = duration
        guard !slider.isTrackingPosition else { return }
        slider.updatePosition(position, duration: duration)
    }

    final class PositionSlider: NSSlider {
        var commit: ((Double) -> Void)?
        var accessibleDuration: Double = 0
        private var trackingCommit: ((Double) -> Void)?
        private(set) var isTrackingPosition = false

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            isTrackingPosition = true
            trackingCommit = commit
            defer {
                isTrackingPosition = false
                trackingCommit = nil
            }
            super.mouseDown(with: event)
        }

        func updatePosition(_ position: Double, duration: Double) {
            maxValue = duration > 0 ? duration : 1
            doubleValue = min(max(0, position), max(0, duration))
        }

        override func accessibilityValueDescription() -> String? {
            guard accessibleDuration > 0 else { return "Duration unavailable" }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .full
            formatter.zeroFormattingBehavior = .dropAll
            let position = formatter.string(from: max(0, doubleValue)) ?? "0 seconds"
            let duration = formatter.string(from: accessibleDuration) ?? "0 seconds"
            return "\(position) of \(duration)"
        }

        @objc func commitPosition() {
            guard isEnabled else { return }
            (isTrackingPosition ? trackingCommit : commit)?(doubleValue)
        }
    }
}

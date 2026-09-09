import AppKit
import SwiftUI

/// NSSlider owns dragging, keyboard adjustment, focus, and accessibility. Noncontinuous
/// target/action commits once on mouse release; authoritative updates never move a tracked thumb.
struct PlaybackPositionSlider: NSViewRepresentable {
    let position: Double
    let duration: Double
    let isEnabled: Bool
    var drawsIdleProgress = true
    let commit: (Double) -> Void

    func makeNSView(context: Context) -> PositionSlider {
        let slider = PositionSlider(frame: .zero)
        slider.minValue = 0
        slider.altIncrementValue = 10
        slider.isContinuous = false
        slider.target = slider
        slider.action = #selector(PositionSlider.commitPosition)
        slider.setAccessibilityLabel("Playback position")
        return slider
    }

    func updateNSView(_ slider: PositionSlider, context: Context) {
        slider.drawsIdleProgress = drawsIdleProgress
        slider.commit = commit
        if slider.isEnabled != isEnabled {
            slider.isEnabled = isEnabled
            slider.window?.invalidateCursorRects(for: slider)
        }
        slider.setAccessibilityEnabled(isEnabled)
        slider.accessibleDuration = duration
        guard !slider.isTrackingPosition else { return }
        slider.updatePosition(position, duration: duration)
    }

    final class PositionSlider: NSSlider {
        override init(frame: NSRect) {
            super.init(frame: frame)
            cell = PositionSliderCell()
        }

        required init?(coder: NSCoder) { nil }

        var drawsIdleProgress = true

        var isHovering = false {
            didSet { needsDisplay = true }
        }
        private var hoverArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isHovering = false }
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
        }

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
                needsDisplay = true
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

    /// Only drawing is customized; NSSliderCell retains hit testing and tracking geometry.
    final class PositionSliderCell: NSSliderCell {
        private var engaged: Bool {
            guard let slider = controlView as? PositionSlider, slider.isEnabled else { return false }
            return slider.isHovering || slider.isTrackingPosition || slider.window?.firstResponder === slider
        }

        override func drawBar(inside rect: NSRect, flipped: Bool) {
            guard (controlView as? PositionSlider)?.drawsIdleProgress != false || engaged else { return }
            let rail = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
            NSColor(SpottyPalette.progressTrack).setFill()
            NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).fill()
            guard isEnabled else { return }
            let knob = knobRect(flipped: flipped)
            let fill = NSRect(
                x: rail.minX, y: rail.minY,
                width: min(rail.width, max(0, knob.midX - rail.minX)), height: rail.height)
            NSColor(engaged ? SpottyPalette.mediaGreen : SpottyPalette.playerPrimary).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }

        override func drawKnob(_ knobRect: NSRect) {
            guard engaged else { return }
            NSColor(SpottyPalette.playerPrimary).setFill()
            NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12)).fill()
        }
    }
}

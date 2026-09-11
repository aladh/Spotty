import AppKit
import SwiftUI

/// NSSlider owns dragging, keyboard adjustment, focus, and accessibility. Noncontinuous
/// target/action commits once on mouse release; authoritative updates never move a tracked thumb.
struct PlaybackPositionSlider: NSViewRepresentable {
    let position: Double
    let anchoredAt: Date
    let duration: Double
    let isEnabled: Bool
    var isPlaying = false
    var reduceMotion = false
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
        slider.commit = commit
        if slider.isEnabled != isEnabled {
            slider.isEnabled = isEnabled
            slider.window?.invalidateCursorRects(for: slider)
        }
        slider.setAccessibilityEnabled(isEnabled)
        slider.accessibleDuration = duration
        guard !slider.isTrackingPosition else { return }
        slider.updatePosition(
            position, anchoredAt: anchoredAt, duration: duration, isPlaying: isPlaying, reduceMotion: reduceMotion)
    }

    final class PositionSlider: NSSlider {
        let progressDrawing = PlaybackProgressDrawing(frame: .zero)
        var now: () -> Date = Date.init
        private var anchorPosition = 0.0
        private var anchoredAt = Date()
        private var plays = false
        private var reduceMotion = false
        private var hasDuration = false
        private var hasKeyboardFocus = false
        private weak var observedWindow: NSWindow?
        private var hoverArea: NSTrackingArea?
        var isHovering = false {
            didSet { synchronizePosition(); needsDisplay = true }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            cell = PositionSliderCell()
            addSubview(progressDrawing)
        }
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            progressDrawing.frame = bounds
            synchronizePosition()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            hoverArea = area
            refreshHover()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            observedWindow = window
            if let window {
                for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowActivationChanged), name: name, object: window)
                }
            }
            refreshHover()
            renderProgress()
        }

        @objc private func windowActivationChanged(_ notification: Notification) { refreshHover() }

        func refreshHover() {
            guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else {
                isHovering = false
                return
            }
            isHovering = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }

        override func becomeFirstResponder() -> Bool {
            synchronizePosition()
            let accepted = super.becomeFirstResponder()
            hasKeyboardFocus = accepted
            renderProgress()
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { hasKeyboardFocus = false }
            synchronizePosition()
            return accepted
        }

        override func keyDown(with event: NSEvent) {
            synchronizePosition()
            super.keyDown(with: event)
        }

        override func accessibilityPerformIncrement() -> Bool {
            synchronizePosition()
            return super.accessibilityPerformIncrement()
        }

        override func accessibilityPerformDecrement() -> Bool {
            synchronizePosition()
            return super.accessibilityPerformDecrement()
        }

        var commit: ((Double) -> Void)?
        var accessibleDuration: Double = 0
        private var trackingCommit: ((Double) -> Void)?
        private(set) var isTrackingPosition = false

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            synchronizePosition()
            isTrackingPosition = true
            trackingCommit = commit
            defer {
                isTrackingPosition = false
                trackingCommit = nil
                renderProgress()
                needsDisplay = true
            }
            super.mouseDown(with: event)
        }

        /// Convenience for callers (and existing tests) that only have an interpolated position,
        /// not a store anchor date: anchors immediately at `now()`.
        func updatePosition(_ position: Double, duration: Double, isPlaying: Bool = false, reduceMotion: Bool = false) {
            updatePosition(
                position, anchoredAt: now(), duration: duration, isPlaying: isPlaying, reduceMotion: reduceMotion)
        }

        /// Authoritative updates carry the store's own anchor. When nothing about the anchor,
        /// duration, or motion state actually changed and Core Animation is carrying the thumb,
        /// only chrome (enabled/engaged colors) is refreshed so the running animation is left
        /// untouched instead of being restarted every call (e.g. every second from a 1 Hz
        /// `TimelineView`). A static thumb still advances from the same anchor on every call.
        func updatePosition(
            _ position: Double, anchoredAt: Date, duration: Double, isPlaying: Bool = false, reduceMotion: Bool = false
        ) {
            let newMaxValue = duration > 0 ? duration : 1
            let newHasDuration = duration > 0
            let newAnchorPosition = min(max(0, position), max(0, duration))
            if newAnchorPosition == anchorPosition, anchoredAt == self.anchoredAt, newMaxValue == maxValue,
                newHasDuration == hasDuration, isPlaying == plays, reduceMotion == self.reduceMotion
            {
                if animatesProgress {
                    progressDrawing.refreshChrome(hasTrack: hasDuration, engaged: isEngaged)
                } else {
                    synchronizePosition()
                }
                return
            }
            maxValue = newMaxValue
            hasDuration = newHasDuration
            anchorPosition = newAnchorPosition
            self.anchoredAt = anchoredAt
            plays = isPlaying
            self.reduceMotion = reduceMotion
            synchronizePosition()
        }

        /// The same anchor drives animation and native interaction, including VoiceOver.
        func synchronizePosition() {
            if !isTrackingPosition {
                let elapsed = plays ? max(0, now().timeIntervalSince(anchoredAt)) : 0
                doubleValue = min(maxValue, anchorPosition + elapsed)
            }
            renderProgress()
        }

        private var isEngaged: Bool {
            isEnabled && (isTrackingPosition || isHovering || (hasKeyboardFocus && window?.isKeyWindow == true))
        }

        /// Mirrors the drawing's own decision to run Core Animation rather than draw a static thumb.
        private var animatesProgress: Bool {
            plays && !reduceMotion && !isTrackingPosition && hasDuration && window != nil
        }

        func renderProgress() {
            guard let cell = cell as? NSSliderCell else { return }
            progressDrawing.frame = bounds
            progressDrawing.update(
                bar: cell.barRect(flipped: isFlipped), knob: cell.knobRect(flipped: isFlipped),
                remaining: max(0, maxValue - doubleValue), hasTrack: hasDuration, engaged: isEngaged,
                animates: plays && !reduceMotion && !isTrackingPosition
            )
        }

        override func accessibilityValueDescription() -> String? {
            synchronizePosition()
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
            anchorPosition = doubleValue
            anchoredAt = now()
            (isTrackingPosition ? trackingCommit : commit)?(doubleValue)
            renderProgress()
        }
    }

    /// The cell keeps native geometry/tracking; the one overlay owns all visible chrome.
    final class PositionSliderCell: NSSliderCell {
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            (controlView as? PositionSlider)?.renderProgress()
        }
        override func drawKnob(_ knobRect: NSRect) {
            (controlView as? PositionSlider)?.renderProgress()
        }
    }
}

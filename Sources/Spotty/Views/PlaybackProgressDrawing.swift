import AppKit
import QuartzCore
import SwiftUI

/// Render-server interpolation avoids a SwiftUI layout pass on every progress frame.
/// Playback and accessibility remain owned by NowPlayingProgress.
struct PlaybackProgressDrawing: NSViewRepresentable {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let hasTrack: Bool
    let isHovering: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> ProgressView { ProgressView() }

    func updateNSView(_ view: ProgressView, context: Context) {
        view.update(self)
    }

    static func dismantleNSView(_ view: ProgressView, coordinator: ()) {
        view.stopAnimation()
    }

    final class ProgressView: NSView {
        private let rail = CALayer()
        private let fill = CALayer()
        private let thumb = CALayer()
        private var state: PlaybackProgressDrawing?
        private var anchoredAt = Date()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for sublayer in [rail, fill, thumb] { layer?.addSublayer(sublayer) }
            rail.backgroundColor = NSColor(SpottyPalette.progressTrack).cgColor
            thumb.backgroundColor = NSColor(SpottyPalette.playerPrimary).cgColor
            rail.cornerRadius = 2
            fill.cornerRadius = 2
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            thumb.cornerRadius = 6
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(_ state: PlaybackProgressDrawing) {
            let previous = self.state
            self.state = state
            anchoredAt = Date()
            render()
            if state.reduceMotion {
                thumb.removeAnimation(forKey: "hover")
            } else if previous?.isHovering != state.isHovering {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previous?.isHovering == true ? 1 : 0
                fade.toValue = state.isHovering ? 1 : 0
                fade.duration = 0.2
                thumb.add(fade, forKey: "hover")
            }
        }

        override func layout() {
            super.layout()
            render()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            render()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            render()
        }

        func stopAnimation() {
            fill.removeAllAnimations()
            thumb.removeAllAnimations()
        }

        private func render() {
            guard let state else { return }
            let elapsed = state.isPlaying ? max(0, Date().timeIntervalSince(anchoredAt)) : 0
            let position = min(max(0, state.position + elapsed), max(0, state.duration))
            let fraction = state.duration > 0 ? position / state.duration : 0
            let width = bounds.width
            let x = width * fraction
            let remaining = max(0, state.duration - position)
            let animates = state.hasTrack && state.isPlaying && remaining > 0 && window != nil

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.removeAnimation(forKey: "playbackProgress")
            thumb.removeAnimation(forKey: "playbackProgress")
            for sublayer in [rail, fill, thumb] {
                sublayer.contentsScale = window?.backingScaleFactor ?? 1
            }
            rail.frame = CGRect(x: 0, y: bounds.midY - 2, width: width, height: 4)
            fill.isHidden = !state.hasTrack
            thumb.isHidden = !state.hasTrack
            thumb.opacity = state.isHovering ? 1 : 0
            fill.backgroundColor =
                NSColor(
                    state.isHovering ? SpottyPalette.mediaGreen : SpottyPalette.playerPrimary
                ).cgColor
            fill.position = CGPoint(x: 0, y: bounds.midY)
            fill.bounds = CGRect(x: 0, y: 0, width: animates ? width : x, height: 4)
            thumb.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            thumb.position = CGPoint(x: animates ? width : x, y: bounds.midY)
            if animates {
                for (target, keyPath) in [(fill, "bounds.size.width"), (thumb, "position.x")] {
                    let animation = CABasicAnimation(keyPath: keyPath)
                    animation.fromValue = x
                    animation.toValue = width
                    animation.duration = remaining
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                    target.add(animation, forKey: "playbackProgress")
                }
            }
            CATransaction.commit()
        }
    }
}

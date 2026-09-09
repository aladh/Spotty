import AppKit
import QuartzCore

/// One renderer owns idle and interactive chrome. Geometry comes from the native slider cell;
/// Core Animation advances the fill/handle without per-frame SwiftUI layout or playback commands.
@MainActor
final class PlaybackProgressDrawing: NSView {
    private let rail = CALayer()
    private let fill = CALayer()
    private let thumb = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for sublayer in [rail, fill, thumb] { layer?.addSublayer(sublayer) }
        rail.cornerRadius = 2
        fill.cornerRadius = 2
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        thumb.cornerRadius = 6
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(bar: NSRect, knob: NSRect, remaining: Double, hasTrack: Bool, engaged: Bool, animates: Bool) {
        // NSSlider's knob center travels between these endpoints. Both drawing states use
        // this range, so a native interaction cannot switch to a different progress geometry.
        let track = NSRect(
            x: bar.minX + knob.width / 2, y: bar.midY - 2,
            width: max(0, bar.width - knob.width), height: 4
        )
        let x = min(max(knob.midX, track.minX), track.maxX)
        let runs = animates && hasTrack && remaining > 0 && window != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAnimation(forKey: "progress")
        thumb.removeAnimation(forKey: "progress")
        for sublayer in [rail, fill, thumb] { sublayer.contentsScale = window?.backingScaleFactor ?? 1 }
        rail.frame = track
        rail.backgroundColor = NSColor(SpottyPalette.progressTrack).cgColor
        fill.isHidden = !hasTrack
        fill.backgroundColor = NSColor(engaged ? SpottyPalette.mediaGreen : SpottyPalette.playerPrimary).cgColor
        fill.position = CGPoint(x: track.minX, y: track.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: runs ? track.width : x - track.minX, height: 4)
        thumb.isHidden = !hasTrack || !engaged
        thumb.backgroundColor = NSColor(SpottyPalette.playerPrimary).cgColor
        thumb.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        thumb.position = CGPoint(x: runs ? track.maxX : x, y: track.midY)
        if runs {
            for (target, keyPath, start, end) in [
                (fill, "bounds.size.width", x - track.minX, track.width),
                (thumb, "position.x", x, track.maxX),
            ] {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = start
                animation.toValue = end
                animation.duration = remaining
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                target.add(animation, forKey: "progress")
            }
        }
        CATransaction.commit()
    }
}

import AppKit
import QuartzCore

/// One renderer owns idle and interactive chrome. Geometry comes from the native slider cell;
/// Core Animation advances the fill/handle without per-frame SwiftUI layout or playback commands.
///
/// A running animation is kept in place whenever its presented position is still close to the
/// freshly-computed target (within `animationDecision`'s tolerance) — colors, visibility, and
/// scale are updated without touching the animation or its model values, so a 1 Hz refresh with
/// no real change does not restart the thumb from a quantized position. When the presented
/// position and the target really have drifted apart, the animation restarts, but eases from the
/// presented position into the linear run instead of snapping.
@MainActor
final class PlaybackProgressDrawing: NSView {
    private let rail = CALayer()
    private let fill = CALayer()
    private let thumb = CALayer()

    /// Test hook: counts every time the animation is removed and geometry rewritten from scratch
    /// (as opposed to the in-place update that preserves a running animation).
    private(set) var progressRestartCount = 0

    enum AnimationDecision: Equatable {
        case keep
        case restart(from: CGFloat)
    }

    /// Pure decision of whether a running animation is close enough to the newly computed target
    /// to keep running as-is, or whether it must restart — and if so, from where. Drift within
    /// `tolerance` keeps the animation; drift up to `snapThreshold` restarts from the presented
    /// position so the correction eases in; anything larger (a seek or track change) restarts
    /// from the target so the thumb snaps instead of sweeping across the bar.
    static func animationDecision(
        presentedX: CGFloat?, targetX: CGFloat, pointsPerSecond: CGFloat,
        tolerance: TimeInterval = 0.25, snapThreshold: TimeInterval = 2
    ) -> AnimationDecision {
        guard let presentedX else { return .restart(from: targetX) }
        guard pointsPerSecond > 0 else { return .restart(from: targetX) }
        let driftSeconds = abs(presentedX - targetX) / pointsPerSecond
        if driftSeconds <= tolerance { return .keep }
        if driftSeconds > snapThreshold { return .restart(from: targetX) }
        return .restart(from: presentedX)
    }

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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [rail, fill, thumb] { sublayer.contentsScale = window?.backingScaleFactor ?? 1 }
        CATransaction.commit()
    }

    /// Updates colors, visibility, and scale without touching geometry or a running animation.
    func refreshChrome(hasTrack: Bool, engaged: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [rail, fill, thumb] { sublayer.contentsScale = window?.backingScaleFactor ?? 1 }
        fill.isHidden = !hasTrack
        fill.backgroundColor = NSColor(engaged ? SpottyPalette.mediaGreen : SpottyPalette.playerPrimary).cgColor
        thumb.isHidden = !hasTrack || !engaged
        thumb.backgroundColor = NSColor(SpottyPalette.playerPrimary).cgColor
        CATransaction.commit()
    }

    func update(bar: NSRect, knob: NSRect, remaining: Double, hasTrack: Bool, engaged: Bool, animates: Bool) {
        // NSSlider's knob center travels between these endpoints. Both drawing states use
        // this range, so a native interaction cannot switch to a different progress geometry.
        let track = NSRect(
            x: bar.minX + knob.width / 2, y: bar.midY - 2,
            width: max(0, bar.width - knob.width), height: 4
        )
        let x = min(max(knob.midX, track.minX), track.maxX)
        let runs = animates && hasTrack && remaining > 0 && window != nil
        let rate = remaining > 0 ? CGFloat((track.maxX - x) / remaining) : 0

        let presentedX: CGFloat? =
            (thumb.animation(forKey: "progress") != nil && rail.frame == track)
            ? thumb.presentation()?.position.x
            : nil
        let decision = Self.animationDecision(presentedX: presentedX, targetX: x, pointsPerSecond: rate)

        if runs, case .keep = decision {
            refreshChrome(hasTrack: hasTrack, engaged: engaged)
            return
        }

        progressRestartCount += 1
        let from: CGFloat
        if case .restart(let restartFrom) = decision {
            from = restartFrom
        } else {
            from = x
        }

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
            // A correction rejoins the target path over `c` seconds; with less than that left,
            // a two-segment keyframe would degenerate, so run plain linear from `from`.
            let c = 0.3
            let corrects = from != x && remaining > c
            for (target, keyPath, start, end) in [
                (fill, "bounds.size.width", from - track.minX, track.width),
                (thumb, "position.x", from, track.maxX),
            ] {
                if corrects {
                    // Rejoin the target's linear path `c` seconds in, then run on it to the end.
                    let mid = end - rate * (remaining - c)
                    let animation = CAKeyframeAnimation(keyPath: keyPath)
                    animation.values = [start, mid, end]
                    animation.keyTimes = [0, NSNumber(value: c / remaining), 1]
                    animation.timingFunctions = [
                        CAMediaTimingFunction(name: .easeInEaseOut),
                        CAMediaTimingFunction(name: .linear),
                    ]
                    animation.calculationMode = .linear
                    animation.duration = remaining
                    target.add(animation, forKey: "progress")
                } else {
                    let animation = CABasicAnimation(keyPath: keyPath)
                    animation.fromValue = start
                    animation.toValue = end
                    animation.duration = remaining
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                    target.add(animation, forKey: "progress")
                }
            }
        }
        CATransaction.commit()
    }
}

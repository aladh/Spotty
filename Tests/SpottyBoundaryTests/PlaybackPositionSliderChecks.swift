import AppKit
import Testing
@testable import SpottyCore

@Suite("Native playback position")
@MainActor
struct PlaybackPositionSliderChecks {
    @Test func spotifyProgressAppearanceRetainsNativeControl() throws {
        let slider = PlaybackPositionSlider.PositionSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.appearance = NSAppearance(named: .darkAqua)
        slider.isEnabled = true
        slider.updatePosition(50, duration: 100)
        let cell = try #require(slider.cell as? PlaybackPositionSlider.PositionSliderCell)

        func render() throws -> NSBitmapImageRep {
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 20,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            NSColor.black.setFill()
            NSBezierPath(rect: slider.bounds).fill()
            cell.draw(withFrame: slider.bounds, in: slider)
            slider.progressDrawing.layer?.render(in: context.cgContext)
            return bitmap
        }

        func coloredPixels(_ bitmap: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> Int {
            (0..<20).reduce(0) { count, y in
                count
                    + (0..<200).filter { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return predicate(color)
                    }.count
            }
        }
        let white: (NSColor) -> Bool = { $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 }
        let green: (NSColor) -> Bool = { $0.greenComponent > 0.7 && $0.redComponent < 0.3 && $0.blueComponent < 0.5 }
        let resting = try render()
        #expect(coloredPixels(resting, matching: white) > 200)
        #expect(coloredPixels(resting, matching: green) == 0)
        slider.isHovering = true
        let hovered = try render()
        #expect(coloredPixels(hovered, matching: green) > 200)
        #expect(coloredPixels(hovered, matching: white) > 50)
        slider.isEnabled = false
        let disabled = try render()
        #expect(coloredPixels(disabled, matching: green) == 0)
        #expect(coloredPixels(disabled, matching: white) > 200)
    }

    @Test func animationAnchorIsSynchronizedBeforeHoverAndAccessibility() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        var time = Date(timeIntervalSince1970: 1_000)
        slider.now = { time }
        slider.updatePosition(60, duration: 180, isPlaying: true)
        time = time.addingTimeInterval(0.75)
        slider.isHovering = true
        #expect(slider.doubleValue == 60.75)
        slider.target = slider
        slider.action = #selector(PlaybackPositionSlider.PositionSlider.commitPosition)
        var committed: Double?
        slider.commit = { committed = $0 }
        time = time.addingTimeInterval(1)
        _ = slider.accessibilityPerformIncrement()
        #expect(slider.doubleValue > 61.75)
        #expect(committed == slider.doubleValue)
        let incremented = slider.doubleValue
        _ = slider.accessibilityPerformDecrement()
        #expect(slider.doubleValue < incremented)
        #expect(slider.doubleValue >= 61.75)
        slider.updatePosition(10, duration: 180, isPlaying: false)
        time = time.addingTimeInterval(2)
        slider.isHovering = false
        #expect(slider.doubleValue == 10)
    }

    @Test func spokenPositionAdvancesWithoutInteraction() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: .zero)
        var time = Date(timeIntervalSince1970: 1_000)
        slider.now = { time }
        slider.accessibleDuration = 180
        slider.updatePosition(60, duration: 180, isPlaying: true)
        let original = slider.accessibilityValueDescription()
        time = time.addingTimeInterval(5)
        #expect(slider.accessibilityValueDescription() != original)
        #expect(slider.doubleValue == 65)
    }

    @Test func trackingAreaRefreshClearsHoverWithoutAnActiveWindow() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: .zero)
        slider.isHovering = true
        slider.updateTrackingAreas()
        #expect(!slider.isHovering)
    }

    @Test func shortTrackRangeAndUnknownDuration() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: .zero)
        slider.updatePosition(0.25, duration: 0.5)
        #expect(slider.maxValue == 0.5)
        #expect(slider.doubleValue == 0.25)
        slider.updatePosition(0, duration: 0)
        #expect(slider.maxValue == 1)
        #expect(slider.accessibilityValueDescription() == "Duration unavailable")
    }

    @Test func spokenLongDuration() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: .zero)
        slider.accessibleDuration = 5_400
        slider.updatePosition(3_600, duration: 5_400)
        let position = DateComponentsFormatter.localizedString(
            from: DateComponents(hour: 1), unitsStyle: .full)
        let duration = DateComponentsFormatter.localizedString(
            from: DateComponents(hour: 1, minute: 30), unitsStyle: .full)
        #expect(position != nil && duration != nil)
        #expect(slider.accessibilityValueDescription() == "\(position ?? "") of \(duration ?? "")")
    }

    @Test func nativeAccessibilityAdjustmentAndDisabledCommit() {
        let slider = PlaybackPositionSlider.PositionSlider(frame: .zero)
        slider.minValue = 0
        slider.maxValue = 180
        slider.accessibleDuration = 180
        slider.updatePosition(60, duration: 180)
        slider.isContinuous = false
        slider.target = slider
        slider.action = #selector(PlaybackPositionSlider.PositionSlider.commitPosition)
        var positions: [Double] = []
        slider.commit = { positions.append($0) }
        let position = DateComponentsFormatter.localizedString(
            from: DateComponents(minute: 1), unitsStyle: .full)
        let duration = DateComponentsFormatter.localizedString(
            from: DateComponents(minute: 3), unitsStyle: .full)
        #expect(position != nil && duration != nil)
        #expect(slider.accessibilityValueDescription() == "\(position ?? "") of \(duration ?? "")")
        _ = slider.accessibilityPerformIncrement()
        #expect(positions.count == 1)
        #expect(slider.doubleValue > 60)
        _ = slider.accessibilityPerformDecrement()
        #expect(positions.count == 2)
        slider.isEnabled = false
        slider.commitPosition()
        #expect(positions.count == 2)
    }
}

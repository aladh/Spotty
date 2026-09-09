import AppKit
import Testing
@testable import SpottyCore

@Suite("Native playback position")
@MainActor
struct PlaybackPositionSliderChecks {
    @Test func nativeAccessibilityAdjustmentAndDisabledCommit() {
        let slider = PlaybackPositionSlider.PositionSlider()
        slider.minValue = 0
        slider.maxValue = 180
        slider.accessibleDuration = 180
        slider.doubleValue = 60
        slider.isContinuous = false
        slider.target = slider
        slider.action = #selector(PlaybackPositionSlider.PositionSlider.commitPosition)
        var positions: [Double] = []
        slider.commit = { positions.append($0) }
        #expect(slider.accessibilityValueDescription() == "1:00 of 3:00")
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

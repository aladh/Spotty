import AppKit
import Testing
@testable import SpottyCore

@Suite("Native playback position")
@MainActor
struct PlaybackPositionSliderChecks {
    @Test func shortTrackRangeAndUnknownDuration() {
        let slider = PlaybackPositionSlider.PositionSlider()
        slider.updatePosition(0.25, duration: 0.5)
        #expect(slider.maxValue == 0.5)
        #expect(slider.doubleValue == 0.25)
        slider.updatePosition(0, duration: 0)
        #expect(slider.maxValue == 1)
        #expect(slider.accessibilityValueDescription() == "Duration unavailable")
    }

    @Test func spokenLongDuration() {
        let slider = PlaybackPositionSlider.PositionSlider()
        slider.accessibleDuration = 5_400
        slider.updatePosition(3_600, duration: 5_400)
        #expect(slider.accessibilityValueDescription() == "1 hour of 1 hour, 30 minutes")
    }

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
        #expect(slider.accessibilityValueDescription() == "1 minute of 3 minutes")
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

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import SpottyCore

@Suite("Visual Contrast")
struct VisualContrastTests {
    @Test
    @MainActor
    func testVisualContrast() {
        do {
            #expect(
                contrastRatio(SpottyPalette.progressTrack, .black) >= 2.4,
                "the intentionally subdued unfilled rail retains Spotify-like contrast over black")
            #expect(
                (contrastRatio(SpottyPalette.dataText, SpottyPalette.catalogCanvas) >= 4.5) == true,
                "data column text clears WCAG AA normal-text contrast on the catalog canvas")
            #expect(
                (contrastRatio(SpottyPalette.playerPrimary, SpottyPalette.progressTrack) >= 3.0) == true,
                "the played portion remains distinct from the unfilled progress rail")
            #expect(
                (contrastRatio(SpottyPalette.remotePlaybackForeground, SpottyPalette.mediaGreen) >= 4.5) == true,
                "remote playback footer text clears WCAG AA normal-text contrast on the media green banner")
        }
    }
}

/// WCAG 2.x contrast ratio between two colors, computed from their real sRGB components
/// rather than from source text, so a decorative or system color cannot slip past the gate.
private func contrastRatio(_ foreground: Color, _ background: Color) -> Double {
    let foregroundLuminance = relativeLuminance(of: foreground)
    let backgroundLuminance = relativeLuminance(of: background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(of color: Color) -> Double {
    guard let sRGB = NSColor(color).usingColorSpace(.sRGB) else {
        preconditionFailure("Expected a color convertible to the sRGB color space")
    }
    let red = linearize(Double(sRGB.redComponent))
    let green = linearize(Double(sRGB.greenComponent))
    let blue = linearize(Double(sRGB.blueComponent))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

private func linearize(_ channel: Double) -> Double {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}

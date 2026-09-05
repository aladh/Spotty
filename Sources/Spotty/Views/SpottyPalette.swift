import SwiftUI

/// Small, bounded color vocabulary for catalog media surfaces.
///
/// System colors remain the default for text, separators, selection, and window materials. The
/// fixed media green is reserved for actions and the current-track indicator, so it never becomes
/// a second global accent or selection system.
enum SpottyPalette {
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.7)
    static let navigationControl = Color(white: 0.122)
    static let mediaGreen = Color(red: 0.118, green: 0.843, blue: 0.376)
    // Spotify-familiar elevations: canvas, resting card, and hovered card.
    static let catalogCanvas = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let playlistHeroGradient = [
        Color(red: 0.12, green: 0.15, blue: 0.18),
        catalogCanvas,
    ]
    static let mediaSurface = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let mediaSurfaceHover = Color(red: 0.141, green: 0.141, blue: 0.141)
    static let quickAccessSurface = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let quickAccessSurfaceHover = Color(red: 0.22, green: 0.22, blue: 0.22)
    // The player is a distinct, near-black anchor rather than another raised media card.
    static let playerShelf = Color(red: 0.035, green: 0.035, blue: 0.035)
    static let playerDivider = Color.primary.opacity(0.10)
    static let playerPrimary = textPrimary
    static let playerSecondary = textSecondary
    static let playerDisabledControl = Color.primary.opacity(0.20)
    static let playerDisabledForeground = Color.secondary.opacity(0.55)
    static let playerButtonForeground = Color.black
    static let remotePlaybackForeground = Color(red: 0.025, green: 0.12, blue: 0.06)
    /// Data columns (BPM, key, time signature, popularity, duration, relative times). Measures
    /// ≥4.5:1 against `catalogCanvas`, meeting WCAG AA for normal text.
    static let dataText = Color(white: 0.64)
    /// Spotify's #ffffff4d rail over black intentionally retains its subdued ~2.48:1 contrast.
    /// The white played portion and hover thumb provide the higher-contrast progress indicator.
    static let progressTrack = Color(white: 77.0 / 255)

    static func mediaCardSurface(isHovering: Bool) -> Color {
        isHovering ? mediaSurfaceHover : .clear
    }

    static func quickAccessSurface(isHovering: Bool) -> Color {
        isHovering ? quickAccessSurfaceHover : quickAccessSurface
    }

    static func historySurface(isHovering: Bool) -> Color {
        isHovering ? Color.primary.opacity(0.055) : .clear
    }

    static let artworkPlaceholderColors = [
        Color.secondary.opacity(0.13),
        Color.primary.opacity(0.08),
    ]
}

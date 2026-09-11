import AppKit
import CoreImage
import SwiftUI

/// Derives a Spotify-like header tint from artwork, clamped so header text stays legible.
///
/// Fetches the artwork bytes directly rather than threading a callback through `RemoteArtwork`'s
/// `AsyncImage` phase, because SwiftUI's `Image` does not expose its bitmap. `RemoteArtwork` has
/// typically already requested the same URL, so this normally resolves from `URLSession`'s shared
/// cache rather than issuing a second network fetch — no application-owned image cache is added.
enum ArtworkDominantColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Loads the image at `url` and computes its clamped dominant color, or `nil` if unavailable.
    static func load(from url: URL?) async -> Color? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        return dominantColor(in: image)
    }

    static func dominantColor(in image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        bitmap.withUnsafeMutableBytes { buffer in
            context.render(
                outputImage,
                toBitmap: buffer.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )
        }

        let nsColor = NSColor(
            srgbRed: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
        return clamped(nsColor)
    }

    /// Darkens/desaturates toward Spotify's header range so white foreground text stays readable.
    private static func clamped(_ color: NSColor) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let clampedBrightness = min(max(brightness, 0.35), 0.55)
        let clampedSaturation = min(saturation, 0.55)
        return Color(hue: hue, saturation: clampedSaturation, brightness: clampedBrightness)
    }
}

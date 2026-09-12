import CoreGraphics
import Foundation
import ImageIO
import SpottyRuntimeContracts
import Synchronization

/// A dedicated lane keeps ImageIO and PNG encoding away from the state actor and MainActor.
final class ArtworkDecoder: Sendable {
    private let queue = DispatchQueue(label: "dev.spotty.artwork.decode", qos: .utility)
    private let mainThreadDecodes = Mutex(0)

    var mainThreadDecodeCount: Int { mainThreadDecodes.withLock { $0 } }

    func decode(_ data: Data, maximumPixelDimension: Int) async throws -> ArtworkAsset {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if Thread.isMainThread { mainThreadDecodes.withLock { $0 += 1 } }
                continuation.resume(
                    with: Result { try Self.decodeImage(data, maximumPixelDimension: maximumPixelDimension) })
            }
        }
    }

    private static func decodeImage(_ data: Data, maximumPixelDimension: Int) throws -> ArtworkAsset {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 100_000_000 / height
        else { throw ArtworkFailure.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw ArtworkFailure.invalidImage }
        let pixelWidth = thumbnail.width
        let pixelHeight = thumbnail.height
        var pixels = Data(count: pixelWidth * pixelHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard rendered else { throw ArtworkFailure.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw ArtworkFailure.invalidImage
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkFailure.invalidImage }
        return ArtworkAsset(
            encodedThumbnail: encoded as Data, rgbaPixels: pixels,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, tint: tint(in: pixels)
        )
    }

    /// Alpha-weighted average, followed by the existing header saturation/brightness clamp.
    private static func tint(in pixels: Data) -> ArtworkTint? {
        var red: UInt64 = 0
        var green: UInt64 = 0
        var blue: UInt64 = 0
        var alpha: UInt64 = 0
        pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                red += UInt64(bytes[offset])
                green += UInt64(bytes[offset + 1])
                blue += UInt64(bytes[offset + 2])
                alpha += UInt64(bytes[offset + 3])
            }
        }
        guard alpha > 0 else { return nil }
        let rgb = [Double(red) / Double(alpha), Double(green) / Double(alpha), Double(blue) / Double(alpha)]
        let maximum = rgb.max() ?? 0
        let minimum = rgb.min() ?? 0
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum
        var hue: Double = 0
        if delta > 0 {
            if maximum == rgb[0] {
                hue = (rgb[1] - rgb[2]) / delta
            } else if maximum == rgb[1] {
                hue = 2 + (rgb[2] - rgb[0]) / delta
            } else {
                hue = 4 + (rgb[0] - rgb[1]) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return ArtworkTint(hue: hue, saturation: min(saturation, 0.55), brightness: min(max(maximum, 0.35), 0.55))
    }
}

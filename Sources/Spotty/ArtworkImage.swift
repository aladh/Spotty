import CoreGraphics
import Foundation
import SpottyRuntimeContracts

extension ArtworkAsset {
    /// Binds pixels decoded by the runtime to a native image; no image file is decoded here.
    func makeCGImage() -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
            pixelWidth <= 1_024, pixelHeight <= 1_024,
            rgbaPixels.count == pixelWidth * pixelHeight * 4,
            let provider = CGDataProvider(data: rgbaPixels as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pixelWidth * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

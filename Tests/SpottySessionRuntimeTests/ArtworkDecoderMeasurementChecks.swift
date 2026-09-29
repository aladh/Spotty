import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import SpottySessionRuntime

/// Opt-in decoder cost, excluding fixture creation, loading, caching and presentation.
struct ArtworkDecoderMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_ARTWORK_DECODE_REPORT"] != nil))
    func measureThumbnailPreparation() async throws {
        let source = try fixture()
        let decoder = ArtworkDecoder()
        let iterations = 100
        var reports: [[String: Any]] = []
        for pixels in [64, 256, 640] {
            _ = try await decoder.decode(source, maximumPixelDimension: pixels)
            let started = ContinuousClock.now
            let before = try cpuSeconds()
            var byteCount = 0
            for _ in 0..<iterations {
                let asset = try await decoder.decode(source, maximumPixelDimension: pixels)
                try #require(asset.pixelWidth == pixels && asset.pixelHeight == pixels)
                byteCount += asset.byteCount
            }
            let cpu = try cpuSeconds() - before
            let elapsed = started.duration(to: .now).components
            reports.append([
                "pixels": pixels, "cpuSeconds": cpu, "assetBytes": byteCount / iterations,
                "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            ])
        }
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "iterations": iterations, "sourcePixels": 640,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "measurements": reports,
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_ARTWORK_DECODE_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func fixture() throws -> Data {
        // Deterministic detailed pixels exercise compression beyond a single-color fixture.
        let width = 640
        var bytes = Data(count: width * width * 4)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for y in 0..<width {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    buffer[offset] = UInt8(truncatingIfNeeded: x * 7 + y * 3)
                    buffer[offset + 1] = UInt8(truncatingIfNeeded: x * 2 + y * 11)
                    buffer[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
                    buffer[offset + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(
            CGImage(
                width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

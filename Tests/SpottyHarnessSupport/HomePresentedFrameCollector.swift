#if os(macOS)
    import CoreMedia
    import CoreVideo
    import CryptoKit
    import Darwin
    import Foundation
    import ScreenCaptureKit

    /// Samples only the caller's synthetic window. Pixel buffers never escape the callback.
    public final class HomePresentedFrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
        public struct Frame: Sendable, Codable {
            public let displayedMachTime: UInt64
            public let receivedMachTime: UInt64
            public let digest: String
            public var isNewFrame = true

            public init(displayedMachTime: UInt64, receivedMachTime: UInt64, digest: String, isNewFrame: Bool = true) {
                self.displayedMachTime = displayedMachTime
                self.receivedMachTime = receivedMachTime
                self.digest = digest
                self.isNewFrame = isNewFrame
            }
        }

        public override init() { super.init() }

        private let lock = NSLock()
        private var frames: [Frame] = []
        private var exceededBound = false
        private var lastComplete: Frame?

        public var snapshot: (frames: [Frame], exceededBound: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (frames, exceededBound)
        }

        public func stream(
            _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
        ) {
            guard type == .screen, sample.isValid,
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let info = attachments.first,
                let status = (info[.status] as? NSNumber)?.intValue
            else { return }
            let received = mach_absolute_time()
            if status == SCFrameStatus.idle.rawValue {
                lock.lock()
                defer { lock.unlock() }
                guard frames.count < 300 else {
                    exceededBound = true
                    return
                }
                guard let lastComplete else { return }
                frames.append(
                    Frame(
                        displayedMachTime: lastComplete.displayedMachTime, receivedMachTime: received,
                        digest: lastComplete.digest, isNewFrame: false))
                return
            }
            guard status == SCFrameStatus.complete.rawValue, let displayed = info[.displayTime] as? NSNumber,
                let buffer = sample.imageBuffer
            else { return }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            // Fixed BGRA capture; hash visible rows only, excluding unspecified stride padding.
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                width > 0, height > 0, width <= 4_096, height <= 4_096, stride >= width * 4
            else { return }
            var hash = SHA256()
            for row in 0..<height {
                hash.update(
                    bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row * stride), count: width * 4))
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            lock.lock()
            defer { lock.unlock() }
            guard frames.count < 300 else {
                exceededBound = true
                return
            }
            let frame = Frame(displayedMachTime: displayed.uint64Value, receivedMachTime: received, digest: digest)
            frames.append(frame)
            lastComplete = frame
        }

        public static func firstSteadyFrame(in frames: [Frame], started: UInt64, ready: UInt64) -> Frame? {
            guard frames.count >= 3, let final = frames.last, final.displayedMachTime >= ready,
                frames.suffix(3).allSatisfy({ $0.digest == final.digest })
            else { return nil }
            return frames.first {
                $0.isNewFrame && $0.displayedMachTime >= max(started, ready) && $0.digest == final.digest
            }
        }

        /// Retrospective onset of the terminal Home raster, qualified by later external readiness.
        /// Readiness is an observation time, not a requirement to manufacture another display event.
        public static func terminalHomeFrame(in frames: [Frame], started: UInt64, observed: UInt64) -> Frame? {
            guard observed >= started, frames.count >= 3, let final = frames.last,
                frames.suffix(3).allSatisfy({ $0.digest == final.digest && $0.receivedMachTime >= observed })
            else { return nil }
            let lastDifferent = frames.lastIndex { $0.digest != final.digest }
            let terminalRun = frames.dropFirst(lastDifferent.map { $0 + 1 } ?? 0)
            return terminalRun.first {
                $0.isNewFrame && $0.displayedMachTime >= started && $0.digest == final.digest
            }
        }

        public static func seconds(from start: UInt64, to end: UInt64) -> Double? {
            guard end >= start else { return nil }
            var base = mach_timebase_info_data_t()
            guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return nil }
            return Double(end - start) * Double(base.numer) / Double(base.denom) / 1e9
        }
    }
#endif

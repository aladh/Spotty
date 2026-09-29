/// Fixed storage for interleaved stereo Float32 frames. The renderer holds its existing buffer
/// lock around every operation; this owner neither locks nor retains caller-owned pointers.
nonisolated final class StereoPCMBuffer {
    static let channels = 2

    enum WriteResult: Equatable {
        case rejectedInput
        case full
        /// Number of Float32 values copied, always an even complete-frame prefix.
        case written(sampleCount: Int)
    }

    private let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readFrame = 0
    private var writeFrame = 0
    private(set) var availableFrames = 0

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0 && capacityFrames <= Int.max / (Self.channels * MemoryLayout<Float>.stride))
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * Self.channels)
        storage.initialize(repeating: 0, count: capacityFrames * Self.channels)
    }

    deinit { storage.deallocate() }

    /// Each callback must contain whole stereo frames. Reject malformed packets atomically so
    /// a lone channel can never be paired with a sample from a later callback.
    func write(_ samples: UnsafeBufferPointer<Float>) -> WriteResult {
        guard samples.count.isMultiple(of: Self.channels) else { return .rejectedInput }
        guard !samples.isEmpty else { return .written(sampleCount: 0) }
        let frames = min(samples.count / Self.channels, capacityFrames - availableFrames)
        guard frames > 0 else { return .full }
        let first = min(frames, capacityFrames - writeFrame)
        storage.advanced(by: writeFrame * Self.channels)
            .update(from: samples.baseAddress!, count: first * Self.channels)
        if first < frames {
            storage.update(
                from: samples.baseAddress!.advanced(by: first * Self.channels),
                count: (frames - first) * Self.channels)
        }
        writeFrame = (writeFrame + frames) % capacityFrames
        availableFrames += frames
        return .written(sampleCount: frames * Self.channels)
    }

    /// Copies and consumes complete frames. An unmatched destination slot is left untouched.
    /// The returned frame count is also the Core Media sample count, without rounding.
    func read(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
        let frames = min(destination.count / Self.channels, availableFrames)
        guard frames > 0 else { return 0 }
        let first = min(frames, capacityFrames - readFrame)
        // Float is trivial: byte copies support both initialized test buffers and the newly
        // allocated Core Media block, without requiring its destination to contain old values.
        let output = UnsafeMutableRawPointer(destination.baseAddress!)
        output.copyMemory(
            from: storage.advanced(by: readFrame * Self.channels),
            byteCount: first * Self.channels * MemoryLayout<Float>.stride)
        if first < frames {
            output.advanced(by: first * Self.channels * MemoryLayout<Float>.stride)
                .copyMemory(from: storage, byteCount: (frames - first) * Self.channels * MemoryLayout<Float>.stride)
        }
        readFrame = (readFrame + frames) % capacityFrames
        availableFrames -= frames
        return frames
    }

    func reset() {
        readFrame = 0
        writeFrame = 0
        availableFrames = 0
    }
}

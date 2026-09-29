import Testing
@testable import SpottyEngineAdapter

@Suite("Stereo PCM buffer")
struct StereoPCMBufferTests {
    @Test(arguments: [1, 3, 88_200])
    func fullCapacityDrainsAsCompleteFrames(capacity: Int) throws {
        let buffer = StereoPCMBuffer(capacityFrames: capacity)
        let input = samples(frames: 0..<capacity)
        try #require(input.withUnsafeBufferPointer(buffer.write) == .written(sampleCount: input.count))
        #expect(buffer.availableFrames == capacity)
        #expect([Float(91), -91].withUnsafeBufferPointer(buffer.write) == .full)
        var consumedFrames = 0
        while consumedFrames < capacity {
            // One spare scalar must remain untouched even when the destination size is odd.
            var output = [Float](repeating: .infinity, count: 2_049)
            let read = output.withUnsafeMutableBufferPointer { buffer.read(into: $0) }
            try #require(read == min(1_024, capacity - consumedFrames))
            let matches = output.prefix(read * 2).elementsEqual(
                input[(consumedFrames * 2)..<((consumedFrames + read) * 2)])
            #expect(matches)
            #expect(output.dropFirst(read * 2).allSatisfy { $0 == .infinity })
            consumedFrames += read
        }
        #expect(buffer.availableFrames == 0)
        var output = [Float](repeating: .infinity, count: 4)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 0)
        #expect(output.allSatisfy { $0 == .infinity })
    }

    @Test
    func readsIntoFreshMemoryForCoreMedia() {
        let buffer = StereoPCMBuffer(capacityFrames: 3)
        let input = samples(frames: 0..<3)
        #expect(input.withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        let block = UnsafeMutableRawPointer.allocate(
            byteCount: 6 * MemoryLayout<Float>.stride, alignment: MemoryLayout<Float>.alignment)
        defer { block.deallocate() }
        let destination = UnsafeMutableBufferPointer(start: block.bindMemory(to: Float.self, capacity: 6), count: 6)
        #expect(buffer.read(into: destination) == 3)
        #expect(Array(destination) == input)
        #expect(buffer.availableFrames == 0)
    }

    @Test
    func wrappedCopiesKeepFIFOChannelPairsAndOwnTheCopiedSamples() throws {
        let buffer = StereoPCMBuffer(capacityFrames: 4)
        var input = samples(frames: 0..<3)
        #expect(input.withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        input[0] = 99
        var output = [Float](repeating: .infinity, count: 4)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 2)
        #expect(output == samples(frames: 0..<2))

        // Three of these five frames fit, crossing the end of the allocation.
        #expect(samples(frames: 3..<8).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        try #require(buffer.availableFrames == 4)
        output = [Float](repeating: .infinity, count: 10)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 4)
        #expect(Array(output.prefix(8)) == samples(frames: 2..<6))
        #expect(output.suffix(2).allSatisfy { $0 == .infinity })
    }

    @Test(arguments: [0, 1, 3])
    func malformedCallbacksCannotChangeExistingAudio(occupied: Int) throws {
        let buffer = StereoPCMBuffer(capacityFrames: 3)
        let initial = samples(frames: 0..<occupied)
        #expect(initial.withUnsafeBufferPointer(buffer.write) == .written(sampleCount: initial.count))
        #expect([Float(10), -10, 11].withUnsafeBufferPointer(buffer.write) == .rejectedInput)
        #expect(buffer.availableFrames == occupied)
        var single = [Float.infinity]
        #expect(single.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 0)
        #expect(single == [.infinity])
        #expect(buffer.availableFrames == occupied)

        var output = [Float](repeating: .infinity, count: 6)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == occupied)
        #expect(Array(output.prefix(occupied * 2)) == initial)
        #expect(output.dropFirst(occupied * 2).allSatisfy { $0 == .infinity })
        #expect(samples(frames: 20..<23).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 3)
        #expect(output == samples(frames: 20..<23))
    }

    @Test
    func resetDiscardsWrappedAudioWithoutRenewingTheCallbacksWaitBudget() {
        let buffer = StereoPCMBuffer(capacityFrames: 3)
        let peer = StereoPCMBuffer(capacityFrames: 3)
        var budget = PCMWriteBudget()
        #expect(samples(frames: 0..<3).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        var output = [Float](repeating: .infinity, count: 2)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 1)
        #expect(samples(frames: 3..<4).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 2))
        #expect(samples(frames: 4..<5).withUnsafeBufferPointer(buffer.write) == .full)
        #expect(budget.takeWait(isRendering: true) == true)

        buffer.reset()
        #expect(buffer.availableFrames == 0)
        #expect(samples(frames: 10..<13).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 6))
        #expect(samples(frames: 13..<14).withUnsafeBufferPointer(buffer.write) == .full)
        #expect(budget.takeWait(isRendering: true) == false)
        var nextCallback = PCMWriteBudget()
        #expect(nextCallback.takeWait(isRendering: true) == true)
        #expect(peer.availableFrames == 0)
        output = [Float](repeating: .infinity, count: 6)
        #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 3)
        #expect(output == samples(frames: 10..<13))
    }

    @Test(arguments: [1, 3, 17])
    func fullBufferDropsWithoutWaitingWhenStoppedAndCannotStackWaits(capacity: Int) {
        let buffer = StereoPCMBuffer(capacityFrames: capacity)
        #expect(
            samples(frames: 0..<capacity).withUnsafeBufferPointer(buffer.write) == .written(sampleCount: capacity * 2))
        let next = samples(frames: 50..<51)
        #expect(next.withUnsafeBufferPointer(buffer.write) == .full)
        var stopped = PCMWriteBudget()
        #expect(stopped.takeWait(isRendering: false) == false)
        var running = PCMWriteBudget()
        #expect(running.takeWait(isRendering: true) == true)
        for _ in 0..<3 {
            var output = [Float](repeating: .infinity, count: 2)
            #expect(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == 1)
            #expect(next.withUnsafeBufferPointer(buffer.write) == .written(sampleCount: 2))
            #expect(next.withUnsafeBufferPointer(buffer.write) == .full)
            #expect(running.takeWait(isRendering: true) == false)
        }
    }

    @Test(arguments: [1, 3, 17])
    func repeatedWrapResetAndSaturationMatchAFrameQueue(capacity: Int) throws {
        let buffer = StereoPCMBuffer(capacityFrames: capacity)
        var pending: [Float] = []
        var seed: UInt64 = 0x5A_07_29
        var nextFrame = 0
        func random(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        for _ in 0..<1_000 {
            switch random(8) {
            case 0:
                buffer.reset()
                pending = []
            case 1...4:
                let count = random(15)
                let input = samples(frames: nextFrame..<(nextFrame + count))
                nextFrame += count
                let admitted = min(count, capacity - pending.count / 2)
                let result = input.withUnsafeBufferPointer(buffer.write)
                let expected: StereoPCMBuffer.WriteResult =
                    count > 0 && admitted == 0 ? .full : .written(sampleCount: admitted * 2)
                try #require(result == expected)
                pending.append(contentsOf: input.prefix(admitted * 2))
            default:
                var output = [Float](repeating: .infinity, count: random(31))
                let expected = min(output.count / 2, pending.count / 2)
                try #require(output.withUnsafeMutableBufferPointer { buffer.read(into: $0) } == expected)
                #expect(Array(output.prefix(expected * 2)) == Array(pending.prefix(expected * 2)))
                #expect(output.dropFirst(expected * 2).allSatisfy { $0 == .infinity })
                pending.removeFirst(expected * 2)
            }
            try #require(buffer.availableFrames == pending.count / 2)
        }
    }

    private func samples(frames: Range<Int>) -> [Float] {
        frames.flatMap { [Float($0 + 1), -Float($0 + 1)] }
    }
}

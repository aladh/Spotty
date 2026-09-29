import Testing
import Foundation
import Synchronization
@testable import SpottyEngineAdapter

@Suite("PCM Write Space")
@MainActor
struct PCMWriteSpaceTests {
    @Test
    func idleSignalsCannotWakeALaterWait() {
        let space = PCMWriteSpace()
        space.signalIfArmed()
        space.arm()
        #expect(!space.wait(timeoutMilliseconds: 0))
    }

    @Test
    func anUnsignaledWaitTimesOut() {
        let space = PCMWriteSpace()
        space.arm()
        #expect(!space.wait(timeoutMilliseconds: 0))
    }

    @Test
    func aSignalBeforeParkingWakesTheWriter() {
        let space = PCMWriteSpace()
        space.arm()
        space.signalIfArmed()
        #expect(space.wait(timeoutMilliseconds: 0))
    }

    @Test
    func rearmingDiscardsTheSupersededWake() {
        let space = PCMWriteSpace()
        space.arm()
        space.signalIfArmed()
        space.arm()
        #expect(!space.wait(timeoutMilliseconds: 0))
    }

    @Test(arguments: [1, 10])
    func repeatedSignalsOnlyWakeOneArmedWait(signals: Int) {
        let space = PCMWriteSpace()
        space.arm()
        for _ in 0..<signals { space.signalIfArmed() }
        #expect(space.wait(timeoutMilliseconds: 0))
        space.arm()
        #expect(!space.wait(timeoutMilliseconds: 0))
    }

    @Test
    func aSignalWakesAParkedWriter() {
        let space = PCMWriteSpace()
        let parked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let woke = Mutex(false)
        Thread.detachNewThread {
            space.arm()
            let result = space.wait(timeoutMilliseconds: 5_000, onWillBlock: { parked.signal() })
            woke.withLock { $0 = result }
            finished.signal()
        }
        #expect(parked.wait(timeout: .now() + .seconds(5)) == .success, "Writer reached the park handshake")
        space.signalIfArmed()
        #expect(finished.wait(timeout: .now() + .seconds(5)) == .success, "Control signal releases the writer")
        #expect(woke.withLock { $0 })
    }
}

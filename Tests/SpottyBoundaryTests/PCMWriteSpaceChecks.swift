import Testing
import Foundation
@testable import SpottyCore
@testable import SpottyEngineAdapter

@Suite("PCM Write Space")
struct PCMWriteSpaceTests {
    @Test
    @MainActor
    func testPCMWriteSpace() {
        do {
            let stale = PCMWriteSpace()
            stale.signalIfArmed()
            stale.arm()
            #expect(
                (!stale.wait(timeoutMilliseconds: 0)) == true,
                "a control signal with no armed writer is not consumed by a later wait")

            let idle = PCMWriteSpace()
            idle.arm()
            #expect((!idle.wait(timeoutMilliseconds: 0)) == true, "a wait with no signal times out without spinning")

            let bypass = PCMWriteSpace()
            bypass.arm()
            bypass.signalIfArmed()
            #expect(
                (bypass.wait(timeoutMilliseconds: 0)) == true,
                "stop or flush in the unlock-to-wait window wakes the writer"
            )

            let space = PCMWriteSpace()
            let parked = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let woke = PCMWriterWakeFlag()
            Thread.detachNewThread {
                space.arm()
                woke.store(
                    space.wait(
                        timeoutMilliseconds: 5_000,
                        onWillBlock: {
                            parked.signal()
                        })
                )
                finished.signal()
            }
            #expect(
                (parked.wait(timeout: .now() + .seconds(5)) == .success) == true,
                "the writer handshake arrives before the park")
            space.signalIfArmed()
            #expect(
                (finished.wait(timeout: .now() + .seconds(5)) == .success) == true,
                "stop or flush wakes a genuinely parked writer")
            #expect((woke.load()) == true, "the parked writer observes the control signal")
        }
    }
}

private final class PCMWriterWakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func store(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

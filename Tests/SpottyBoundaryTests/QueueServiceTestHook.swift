import SpottyTestSupport
@testable import SpottySessionRuntime

#if DEBUG
    /// Check-only scheduler that parks `QueueService` at the injected hook points.
    actor QueueServiceTestHook: QueueServiceHook {
        private let reset = HarnessSuspension()
        private let accept = HarnessSuspension()
        private let replacement = HarnessSuspension()

        func parkNextReset() { reset.arm() }
        func resetIsParked() -> Bool { reset.isWaiting }
        func resumeReset() { reset.resume() }

        func parkNextConnectAccept() { accept.arm() }
        func connectAcceptIsParked() -> Bool { accept.isWaiting }
        func resumeConnectAccept() { accept.resume() }

        func parkNextCommittedReplacement() { replacement.arm() }
        func committedReplacementIsParked() -> Bool { replacement.isWaiting }
        func resumeCommittedReplacement() { replacement.resume() }

        nonisolated func close() { reset.close(); accept.close(); replacement.close() }

        func beforeReset() async { await reset.waitIfArmed() }
        func beforeAcceptConnect() async { await accept.waitIfArmed() }
        func beforeRecordCommittedReplacement() async { await replacement.waitIfArmed() }
    }
#endif

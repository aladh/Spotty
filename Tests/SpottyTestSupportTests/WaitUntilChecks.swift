import SpottyTestSupport
import Testing
@MainActor
private final class WaitUntilCheckProbe {
    var entered = false
}

@Suite("Wait Until")
struct WaitUntilTests {
    @Test
    @MainActor
    func testWaitUntil() async throws {
        do {
            let immediate = await waitUntil { true }
            #expect((immediate) == true, "already-true condition succeeds")

            let expired = await waitUntil(timeout: .zero) { true }
            #expect((!expired) == true, "zero timeout is already expired")

            let cancelledBeforeStart = Task { @MainActor in
                await waitUntil { true }
            }
            cancelledBeforeStart.cancel()
            #expect((await cancelledBeforeStart.value == false) == true, "cancelled wait returns false before polling")

            let probe = WaitUntilCheckProbe()
            let cancelledDuringPoll = Task { @MainActor in
                await waitUntil {
                    probe.entered = true
                    return false
                }
            }
            defer { cancelledDuringPoll.cancel() }
            try await requireEventually { probe.entered }
            cancelledDuringPoll.cancel()
            #expect((await cancelledDuringPoll.value == false) == true, "cancelled wait returns false during polling")

            let gate = HarnessResponseGate<Void>(cancellation: .ignored)
            let cancelledAfterPredicate = Task { @MainActor in
                await waitUntil {
                    try? await gate.wait()
                    return true
                }
            }
            defer {
                cancelledAfterPredicate.cancel()
                gate.close()
            }
            try await requireEventually { gate.waiterCount == 1 }
            cancelledAfterPredicate.cancel()
            gate.finish(())
            #expect(
                (await cancelledAfterPredicate.value == false) == true, "cancelled wait does not accept a late true")
        }
    }

    @Test
    @MainActor
    func repeatedFalsePredicatesStillReachReadiness() async {
        var observations = 0
        let ready = await waitUntil {
            observations += 1
            return observations >= 64
        }
        #expect(ready)
    }

    @Test
    @MainActor
    func cancellationStopsAnExtendedWait() async throws {
        var observations = 0
        let waiting = Task { @MainActor in
            await waitUntil {
                observations += 1
                return false
            }
        }
        defer { waiting.cancel() }
        try await requireEventually { observations >= 64 }
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    @Test
    @MainActor
    func requireEventuallyAcceptsAnEstablishedPrerequisite() async {
        await #expect(throws: Never.self) {
            try await requireEventually { true }
        }
    }
}

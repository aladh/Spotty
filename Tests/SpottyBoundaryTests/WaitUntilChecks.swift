import Testing
@MainActor
private final class WaitUntilCheckProbe {
    var entered = false
}

@MainActor
private final class WaitUntilSuspensionGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func park() async {
        entered = true
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
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

            let gate = WaitUntilSuspensionGate()
            let cancelledAfterPredicate = Task { @MainActor in
                await waitUntil {
                    await gate.park()
                    return true
                }
            }
            defer {
                cancelledAfterPredicate.cancel()
                gate.release()
            }
            try await requireEventually { gate.entered }
            cancelledAfterPredicate.cancel()
            gate.release()
            #expect(
                (await cancelledAfterPredicate.value == false) == true, "cancelled wait does not accept a late true")
        }
    }

    @Test
    @MainActor
    func requireEventuallyAcceptsAnEstablishedPrerequisite() async {
        await #expect(throws: Never.self) {
            try await requireEventually { true }
        }
    }
}

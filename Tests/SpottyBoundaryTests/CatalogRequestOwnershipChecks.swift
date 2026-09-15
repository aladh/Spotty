import Testing
@testable import SpottyCore

@MainActor
struct CatalogRequestOwnershipTests {
    enum Retirement: CaseIterable, Sendable {
        case reset, superseded, accountChanged, disconnected, reconnected, abandoned
    }

    @Test(arguments: Retirement.allCases)
    func retiredAdmissionCannotStartWork(retirement: Retirement) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        switch retirement {
        case .reset:
            flight.reset()
        case .superseded:
            flight.begin("replacement")
        case .accountChanged:
            session.update(accountEpoch: 2, isAvailable: true)
        case .disconnected:
            session.update(accountEpoch: 1, isAvailable: false)
        case .reconnected:
            session.update(accountEpoch: 1, isAvailable: false)
            session.update(accountEpoch: 1, isAvailable: true)
        case .abandoned:
            flight.abandonUnstarted(handle)
        }
        var calls = 0
        await flight.run(handle) { calls += 1 }
        #expect(calls == 0)
        flight.markLoaded(handle)
        #expect(!flight.isLoaded("route"))
    }

    @Test(arguments: [false, true])
    func duplicateOrStaleRegistrationCannotDisplaceALiveTask(stale: Bool) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let old = flight.begin("route")
        let current = stale ? flight.begin("route") : old
        let clock = HarnessClock.parked()
        var originalWasCancelled = false
        let original = Task {
            await flight.run(current) {
                try? await clock.sleep(seconds: 10)
                originalWasCancelled = Task.isCancelled
            }
        }
        #expect(await waitUntil { clock.waiterCount == 1 })
        var unexpectedCalls = 0
        await flight.run(old) { unexpectedCalls += 1 }
        flight.reset()
        clock.releaseAll()
        await original.value
        #expect(unexpectedCalls == 0)
        #expect(originalWasCancelled, "reset must still own and cancel the original task")
    }

    @Test func completedAdmissionCannotStartAgain() async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        var calls = 0
        await flight.run(handle) { calls += 1 }
        await flight.run(handle) { calls += 1 }
        #expect(calls == 1)
    }

    @Test func cancellationBeforeRegistrationCannotStartWork() async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        var calls = 0
        let caller = Task { await flight.run(handle) { calls += 1 } }
        // MainActor has not yielded since creating the caller, so cancellation precedes run.
        caller.cancel()
        await caller.value
        #expect(calls == 0)
    }
}

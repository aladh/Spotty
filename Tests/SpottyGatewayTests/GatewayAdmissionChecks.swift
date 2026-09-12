import Testing
@testable import SpottyGateway

@Suite("Gateway request admission")
@MainActor
struct GatewayAdmissionTests {
    @Test
    func defaultCapacityBoundsActiveAndRejectsOverflowBeforeDispatch() async throws {
        let admission = SpotifyRequestAdmission(maximumQueued: 2)
        let gate = AdmissionOperationGate()
        var tasks: [Task<Int, any Error>] = []
        for id in 0..<4 {
            tasks.append(submit(id, to: admission, gate: gate))
            #expect(await waitUntil { await gate.started.count == id + 1 })
        }
        for id in 4..<6 {
            tasks.append(submit(id, to: admission, gate: gate))
            #expect(await waitUntil { await admission.queuedCount == id - 3 })
        }

        do {
            _ = try await admission.withPermit(priority: .interactive) { try await gate.run(99) }
            Issue.record("A full admission queue must reject excess requests")
        } catch {
            #expect(error as? SpotifyRequestAdmission.Failure == .overloaded)
        }
        #expect(await admission.activeCount == 4)
        #expect(await gate.started == [0, 1, 2, 3])

        await gate.complete(0)
        #expect(await waitUntil { await gate.started.count == 5 })
        #expect(await admission.activeCount == 4)
        #expect(await admission.queuedCount == 1)
        await gate.complete(1)
        #expect(await waitUntil { await gate.started.count == 6 })
        for id in 2..<6 { await gate.complete(id) }
        for (id, task) in tasks.enumerated() {
            #expect(try await task.value == id)
        }
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }

    @Test
    func interactiveReadsPrecedeEnrichmentWithFIFOWithinEachLane() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1)
        let gate = AdmissionOperationGate()
        var tasks = [submit(0, to: admission, gate: gate)]
        #expect(await waitUntil { await gate.started == [0] })
        let priorities: [SpotifyRequestAdmission.Priority] = [.enrichment, .interactive, .enrichment, .interactive]
        for (offset, priority) in priorities.enumerated() {
            tasks.append(submit(offset + 1, to: admission, gate: gate, priority: priority))
            #expect(await waitUntil { await admission.queuedCount == offset + 1 })
        }

        let order = [0, 2, 4, 1, 3]
        for (offset, id) in order.enumerated() {
            #expect(await waitUntil { await gate.started == Array(order.prefix(offset + 1)) })
            await gate.complete(id)
        }
        for (id, task) in tasks.enumerated() {
            #expect(try await task.value == id)
        }
        #expect(await admission.activeCount == 0)
    }

    @Test
    func queuedCancellationRemovesWaiterAndFreesCapacityWithoutDispatch() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 1)
        let gate = AdmissionOperationGate()
        let active = submit(0, to: admission, gate: gate)
        #expect(await waitUntil { await gate.started == [0] })
        let cancelled = submit(1, to: admission, gate: gate)
        #expect(await waitUntil { await admission.queuedCount == 1 })

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled queued request must finish as cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await admission.queuedCount == 0)
        let replacement = submit(2, to: admission, gate: gate)
        #expect(await waitUntil { await admission.queuedCount == 1 })
        await gate.complete(0)
        #expect(try await active.value == 0)
        #expect(await waitUntil { await gate.started == [0, 2] })
        await gate.complete(2)
        #expect(try await replacement.value == 2)
        #expect(await admission.activeCount == 0)
    }

    @Test
    func activeCancellationRetainsPermitUntilNoncooperativeOperationSettles() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 1)
        let gate = AdmissionOperationGate()
        let active = submit(0, to: admission, gate: gate)
        #expect(await waitUntil { await gate.started == [0] })
        let queued = submit(1, to: admission, gate: gate)
        #expect(await waitUntil { await admission.queuedCount == 1 })

        active.cancel()
        do {
            _ = try await admission.withPermit(priority: .interactive) { try await gate.run(99) }
            Issue.record("Cancelling live transport must not admit another active operation")
        } catch {
            #expect(error as? SpotifyRequestAdmission.Failure == .overloaded)
        }
        #expect(await admission.activeCount == 1)
        #expect(await gate.started == [0])
        await gate.fail(0)
        do {
            _ = try await active.value
            Issue.record("The active transport failure must reach its caller")
        } catch {
            #expect(error as? AdmissionOperationGate.Failure == .synthetic)
        }

        #expect(await waitUntil { await gate.started == [0, 1] })
        await gate.complete(1)
        #expect(try await queued.value == 1)
        #expect(await admission.activeCount == 0)
    }

    @Test
    func alreadyCancelledRequestNeverDispatchesOrConsumesCapacity() async {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 0)
        let gate = AdmissionOperationGate()
        let start = AdmissionOperationGate()
        let request = Task {
            _ = try await start.run(0)
            return try await admission.withPermit(priority: .interactive) { try await gate.run(1) }
        }
        #expect(await waitUntil { await start.started == [0] })
        request.cancel()
        await start.complete(0)
        do {
            _ = try await request.value
            Issue.record("An already cancelled request must fail before dispatch")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await gate.started.isEmpty)
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }

    private func submit(
        _ id: Int,
        to admission: SpotifyRequestAdmission,
        gate: AdmissionOperationGate,
        priority: SpotifyRequestAdmission.Priority = .interactive
    ) -> Task<Int, any Error> {
        Task {
            try await admission.withPermit(priority: priority) { try await gate.run(id) }
        }
    }
}

/// Admission tests need independently held operations without a catalog, engine, or account
/// contract. This gate deliberately ignores task cancellation until each test settles transport.
private actor AdmissionOperationGate {
    enum Failure: Error { case synthetic }

    private(set) var started: [Int] = []
    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    func run(_ id: Int) async throws -> Int {
        started.append(id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func complete(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume(returning: id)
    }

    func fail(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: Failure.synthetic)
    }
}

/// Poll only concrete actor state; the deadline is a hang watchdog, never a scheduling delay.
@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while clock.now < deadline {
        if Task.isCancelled { return false }
        if await condition() { return !Task.isCancelled && clock.now < deadline }
        await Task.yield()
    }
    return false
}

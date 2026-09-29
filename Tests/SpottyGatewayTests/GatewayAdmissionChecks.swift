import SpottyTestSupport
import Synchronization
import Testing
@testable import SpottyGateway

@Suite("Gateway request admission")
@MainActor
struct GatewayAdmissionTests {
    @Test
    func defaultCapacityBoundsActiveAndRejectsOverflowBeforeDispatch() async throws {
        let admission = SpotifyRequestAdmission(maximumQueued: 2)
        let gate = AdmissionOperationGate(expected: Array(0..<6))
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        for id in 0..<4 {
            try requests.submit(id)
            try await requireEventually { gate.started.count == id + 1 }
        }
        for id in 4..<6 {
            try requests.submit(id)
            try await requireEventually { await admission.queuedCount == id - 3 }
        }

        try requests.submit(99)
        let overflow = try await requests.result(99)
        #expect(throws: SpotifyRequestAdmission.Failure.overloaded) { try overflow.get() }
        #expect(await admission.activeCount == 4)
        #expect(gate.started == [0, 1, 2, 3])

        gate.complete(0)
        try await requireEventually { gate.started.count == 5 }
        #expect(await admission.activeCount == 4)
        #expect(await admission.queuedCount == 1)
        gate.complete(1)
        try await requireEventually { gate.started.count == 6 }
        for id in 2..<6 { gate.complete(id) }
        for id in 0..<6 {
            let result = try await requests.result(id)
            #expect(try result.get() == id)
        }
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }

    @Test
    func interactiveReadsPrecedeEnrichmentWithFIFOWithinEachLane() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1)
        let gate = AdmissionOperationGate(expected: Array(0..<5))
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        try requests.submit(0)
        try await requireEventually { gate.started == [0] }
        let priorities: [SpotifyRequestAdmission.Priority] = [.enrichment, .interactive, .enrichment, .interactive]
        for (offset, priority) in priorities.enumerated() {
            try requests.submit(offset + 1, priority: priority)
            try await requireEventually { await admission.queuedCount == offset + 1 }
        }

        let order = [0, 2, 4, 1, 3]
        for (offset, id) in order.enumerated() {
            try await requireEventually { gate.started == Array(order.prefix(offset + 1)) }
            gate.complete(id)
        }
        for id in 0..<5 {
            let result = try await requests.result(id)
            #expect(try result.get() == id)
        }
        #expect(await admission.activeCount == 0)
    }

    @Test
    func queuedCancellationRemovesWaiterAndFreesCapacityWithoutDispatch() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 1)
        let gate = AdmissionOperationGate(expected: [0, 2])
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        try requests.submit(0)
        try await requireEventually { gate.started == [0] }
        try requests.submit(1)
        try await requireEventually { await admission.queuedCount == 1 }

        requests.cancel(1)
        let cancelled = try await requests.result(1)
        #expect(throws: CancellationError.self) { try cancelled.get() }
        #expect(await admission.queuedCount == 0)
        try requests.submit(2)
        try await requireEventually { await admission.queuedCount == 1 }
        gate.complete(0)
        let active = try await requests.result(0)
        #expect(try active.get() == 0)
        try await requireEventually { gate.started == [0, 2] }
        gate.complete(2)
        let replacement = try await requests.result(2)
        #expect(try replacement.get() == 2)
        #expect(await admission.activeCount == 0)
    }

    @Test
    func activeCancellationRetainsPermitUntilNoncooperativeOperationSettles() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 1)
        let gate = AdmissionOperationGate(expected: [0, 1])
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        try requests.submit(0)
        try await requireEventually { gate.started == [0] }
        try requests.submit(1)
        try await requireEventually { await admission.queuedCount == 1 }

        requests.cancel(0)
        try requests.submit(99)
        let overflow = try await requests.result(99)
        #expect(throws: SpotifyRequestAdmission.Failure.overloaded) { try overflow.get() }
        #expect(await admission.activeCount == 1)
        #expect(gate.started == [0])
        gate.fail(0)
        let active = try await requests.result(0)
        #expect(throws: AdmissionOperationGate.Failure.synthetic) { try active.get() }

        try await requireEventually { gate.started == [0, 1] }
        gate.complete(1)
        let queued = try await requests.result(1)
        #expect(try queued.get() == 1)
        #expect(await admission.activeCount == 0)
    }

    @Test
    func alreadyCancelledRequestNeverDispatchesOrConsumesCapacity() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 0)
        let gate = AdmissionOperationGate(expected: [])
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        // Submission and cancellation share this MainActor turn; the request cannot start yet.
        try requests.submit(1)
        requests.cancel(1)
        let result = try await requests.result(1)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(gate.started.isEmpty)
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }

    @Test
    func fixtureCleanupSettlesHeldAndQueuedRequests() async throws {
        let admission = SpotifyRequestAdmission(maximumActive: 1, maximumQueued: 1)
        let gate = AdmissionOperationGate(expected: [0, 1])
        let requests = AdmissionRequests(admission: admission, gate: gate)
        defer { requests.close() }
        try requests.submit(0)
        try await requireEventually { gate.started == [0] }
        try requests.submit(1)
        try await requireEventually { await admission.queuedCount == 1 }

        requests.close()
        for id in 0..<2 {
            let result = try await requests.result(id)
            #expect(throws: CancellationError.self) { try result.get() }
        }
        #expect(gate.started == [0])
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }
}

/// Owns every admission attempt, including overflow probes. A bounded
/// settlement prerequisite stays outside assertions about request errors, so timeout stops the test.
@MainActor
private final class AdmissionRequests {
    private let admission: SpotifyRequestAdmission
    private let gate: AdmissionOperationGate
    private let completed = HarnessCounters()
    private var tasks: [Int: Task<Int, any Error>] = [:]

    init(admission: SpotifyRequestAdmission, gate: AdmissionOperationGate) {
        self.admission = admission
        self.gate = gate
    }

    func submit(
        _ id: Int,
        priority: SpotifyRequestAdmission.Priority = .interactive,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(tasks[id] == nil, "Request IDs must be unique", sourceLocation: sourceLocation)
        tasks[id] = Task { [admission, gate, completed] in
            defer { completed.record(String(id)) }
            return try await admission.withPermit(priority: priority) { try await gate.run(id) }
        }
    }

    func cancel(_ id: Int) { tasks[id]?.cancel() }

    func result(
        _ id: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Result<Int, any Error> {
        let task = try #require(tasks[id], sourceLocation: sourceLocation)
        try await requireEventually(
            description: "Admission request \(id) completes", sourceLocation: sourceLocation
        ) { completed.count(String(id)) == 1 }
        return await task.result
    }

    func close() {
        tasks.values.forEach { $0.cancel() }
        gate.close()
    }
}

/// Admission tests need independently held operations without a catalog, engine, or account
/// contract. Shared response gates own suspension and ignore cancellation until transport settles.
private final class AdmissionOperationGate: Sendable {
    enum Failure: Error, Equatable { case synthetic, unexpectedOperation(Int), duplicateOperation(Int) }

    private let entries = Mutex<[Int]>([])
    private let responses: [Int: HarnessResponseGate<Int>]

    init(expected: [Int]) {
        responses = Dictionary(uniqueKeysWithValues: expected.map { ($0, HarnessResponseGate(cancellation: .ignored)) })
    }

    var started: [Int] { entries.withLock { $0 } }

    func run(_ id: Int) async throws -> Int {
        let duplicate = entries.withLock { entries in
            let duplicate = entries.contains(id)
            entries.append(id)
            return duplicate
        }
        guard !duplicate else { throw Failure.duplicateOperation(id) }
        guard let response = responses[id] else { throw Failure.unexpectedOperation(id) }
        return try await response.wait()
    }

    // Responses can precede installation of a waiter; the shared gate retains early replies.
    func complete(_ id: Int) { responses[id]?.finish(id) }
    func fail(_ id: Int) { responses[id]?.resolve(.failure(Failure.synthetic)) }
    func close() { responses.values.forEach { $0.close() } }
}

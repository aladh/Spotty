import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Synchronization
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

/// Queue flights need an intricate numbered script that the single-response harness cannot express.
/// Requests 1 and 2 ignore cancellation and consume their exact early success/failure once.
/// Any extra request fails immediately; terminal close cancels all current and future calls and
/// overrides unconsumed replies. A late reply cannot reopen the script.
final class QueueResponseScript: Sendable {
    enum Failure: Error, Equatable { case unexpectedRequest(Int) }

    private struct State {
        var nextRequestID = 0
        var closed = false
    }

    private let state = Mutex(State())
    private let responses = (0..<2).map { _ in HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored) }

    var pendingRequestIDs: Set<Int> {
        Set(responses.enumerated().compactMap { $0.element.waiterCount == 1 ? $0.offset + 1 : nil })
    }

    func next() async throws -> [CatalogTrack] {
        let requestID = try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            state.nextRequestID += 1
            guard state.nextRequestID <= responses.count else {
                throw Failure.unexpectedRequest(state.nextRequestID)
            }
            return state.nextRequestID
        }
        return try await responses[requestID - 1].wait()
    }

    func fail429(_ requestID: Int) {
        responses[requestID - 1].resolve(.failure(WebQueueFailure.requestFailed(429)))
    }

    func complete(_ requestID: Int, with tracks: [CatalogTrack]) {
        responses[requestID - 1].finish(tracks)
    }

    func close() {
        state.withLock { $0.closed = true }
        responses.forEach { $0.close() }
    }
}

/// Owns callers and the actual QueueService tasks captured while their dependencies are parked.
/// Caller cancellation alone is intentionally insufficient: reset completes subscribers before
/// an ignored Web request reaches acceptWebResult and finishRefreshFlight.
@MainActor
final class QueueResponseFixture {
    struct Caller {
        let id: Int
        let task: Task<ProvenanceQueueSnapshot?, Never>
        func cancel() { task.cancel() }
    }

    let script: QueueResponseScript
    let web: HarnessWebQueue
    let probePublication = HarnessResponseGate<Void>(cancellation: .ignored)
    let service: QueueService
    private let returnedCallers = HarnessCounters()
    private var callers: [Caller] = []
    private var workers: [Task<Void, Never>] = []

    init() {
        let script = QueueResponseScript()
        let web = HarnessWebQueue()
        self.script = script
        self.web = web
        web.onQueue = { try await script.next() }
        service = QueueService(
            webQueue: web, metadata: TrackMetadataService(remote: UnexpectedQueueRemote()),
            clock: HarnessClock.sticky())
    }

    func start(
        accountEpoch: UInt64 = 1, context: String = "spotify:track:current",
        fallbackEntries: [QueueEntry] = [], cachedTracks: [CatalogTrack] = [],
        onUpdate: @escaping @SessionRuntimeActor @Sendable (ProvenanceQueueSnapshot) async -> Void = { _ in }
    ) -> Caller {
        let service = service
        let id = callers.count + 1
        let returned = returnedCallers
        let task = Task {
            defer { returned.record("caller-\(id)") }
            return await service.refresh(
                fallbackEntries: fallbackEntries, cachedTracks: cachedTracks, currentTrackURI: context,
                accountEpoch: accountEpoch, onUpdate: onUpdate)
        }
        let caller = Caller(id: id, task: task)
        callers.append(caller)
        return caller
    }

    /// Only bounds this subscriber join. The marker is recorded inside its actual caller task;
    /// owner publication/settlement assertions separately join the captured worker task.
    func value(
        _ caller: Caller, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ProvenanceQueueSnapshot? {
        try await requireEventually(
            description: "Queue refresh caller \(caller.id) returns", sourceLocation: sourceLocation
        ) { returnedCallers.count("caller-\(caller.id)") == 1 }
        return await caller.task.value
    }

    func requireRequest(_ requestID: Int) async throws -> Task<Void, Never> {
        // waiterCount is the gate's installed continuation, not a transport invocation counter.
        try await requireEventually { script.pendingRequestIDs.contains(requestID) }
        let worker = try #require(await service.refreshWorkerTask)
        workers.append(worker)
        return worker
    }

    func requireProbeWorker() async throws -> Task<Void, Never> {
        try await requireEventually { probePublication.waiterCount == 1 }
        let worker = try #require(await service.refreshWorkerTask)
        workers.append(worker)
        return worker
    }

    func run(_ operation: @MainActor (QueueResponseFixture) async throws -> Void) async throws {
        do {
            try await operation(self)
        } catch {
            await closeAndJoin()
            throw error
        }
        await closeAndJoin()
    }

    private func closeAndJoin() async {
        callers.forEach { $0.cancel() }
        // Also capture an accepted worker when the prerequisite failed before gate registration.
        if let worker = await service.refreshWorkerTask { workers.append(worker) }
        script.close()
        probePublication.close()
        workers.forEach { $0.cancel() }
        for caller in callers { _ = await caller.task.value }
        for worker in workers { await worker.value }
    }
}

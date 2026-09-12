import Foundation

/// Bounds catalog and enrichment work across gateway instances. A permit belongs to the
/// operation until it settles, including when its caller cancels noncooperative transport.
actor SpotifyRequestAdmission {
    enum Priority: Sendable {
        case interactive
        case enrichment
    }

    enum Failure: Error, Equatable, Sendable {
        case overloaded
    }

    static let shared = SpotifyRequestAdmission()

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumActive: Int
    private let maximumQueued: Int
    private var waiters: [Waiter] = []
    private(set) var activeCount = 0

    var queuedCount: Int { waiters.count }

    init(maximumActive: Int = 4, maximumQueued: Int = 128) {
        precondition(maximumActive > 0)
        precondition(maximumQueued >= 0)
        self.maximumActive = maximumActive
        self.maximumQueued = maximumQueued
    }

    func withPermit<Value: Sendable>(
        priority: Priority,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await acquire(id: id, priority: priority)
        } onCancel: {
            Task { await self.cancelQueued(id: id) }
        }
        defer { release() }
        // A cancellation can race a queued permit's handoff. Return the reserved permit
        // without starting transport when the cancellation handler no longer finds a waiter.
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(id: UUID, priority: Priority) async throws {
        try Task.checkCancellation()
        if activeCount < maximumActive {
            activeCount += 1
            return
        }
        guard waiters.count < maximumQueued else { throw Failure.overloaded }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
        }
    }

    private func cancelQueued(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeCount -= 1
            return
        }
        // Stable insertion order provides FIFO within each lane. Hand the live permit
        // directly to the next waiter so a newly arriving request cannot overtake it.
        let index = waiters.firstIndex(where: { $0.priority == .interactive }) ?? 0
        waiters.remove(at: index).continuation.resume()
    }
}

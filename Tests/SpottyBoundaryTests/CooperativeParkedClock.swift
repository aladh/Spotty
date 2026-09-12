import Foundation
@testable import SpottyCore
import SpottyRuntimeContracts

/// Test-only clock that parks until `releaseAll()`. Cooperative cancellation
/// throws `CancellationError` and must not leave a waiter registered if the
/// task was already cancelled when `sleep` started.
final class CooperativeParkedClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSleeps: [TimeInterval] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    var requestedSleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                recordedSleeps.append(seconds)
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        lock.lock()
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

import Foundation
@testable import SpottyCore

/// The playback clock boundary checks inject.
///
/// It covers the three shapes the suite needs: a sticky clock that always reports the same
/// instant, an advancing clock the check steps by hand, and a parked clock whose sleepers wait
/// until released. `CooperativeParkedClock` remains for checks that compose parked deadlines
/// directly; this type is the default everywhere else.
final class HarnessClock: PlaybackClock, @unchecked Sendable {
    /// What `sleep(seconds:)` does.
    enum SleepBehavior: Sendable {
        /// Returns at once, so a deadline elapses immediately.
        case immediate
        /// Registers a waiter that `releaseNext()`/`releaseAll()` resumes. Cooperative
        /// cancellation throws `CancellationError` and never leaves the waiter registered.
        case parked
        /// Like `.parked`, but ignores cancellation, so a replaced sleeper stays suspended.
        case uncooperativelyParked
    }

    private struct Storage {
        var now: Date
        var behavior: SleepBehavior
        var requestedSleeps: [TimeInterval] = []
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var order: [UUID] = []
    }

    private let lock = NSLock()
    private var storage: Storage

    init(now: Date = HarnessDates.fixed, sleep: SleepBehavior = .parked) {
        storage = Storage(now: now, behavior: sleep)
    }

    /// A fixed instant whose sleeps only end on cancellation. The suite's default.
    static func sticky(
        now: Date = HarnessDates.fixed,
        sleep: SleepBehavior = .parked
    ) -> HarnessClock {
        HarnessClock(now: now, sleep: sleep)
    }

    /// A fixed instant the check steps with `advance(seconds:)`; sleeps return at once.
    static func advancing(from now: Date = HarnessDates.fixed) -> HarnessClock {
        HarnessClock(now: now, sleep: .immediate)
    }

    /// A fixed instant whose sleepers park until released.
    static func parked(now: Date = HarnessDates.fixed) -> HarnessClock {
        HarnessClock(now: now, sleep: .parked)
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    var sleepBehavior: SleepBehavior {
        get { withStorage { $0.behavior } }
        set { withStorage { $0.behavior = newValue } }
    }

    func advance(seconds: TimeInterval) {
        withStorage { $0.now = $0.now.addingTimeInterval(seconds) }
    }

    func set(now: Date) {
        withStorage { $0.now = now }
    }

    // MARK: Observation

    var requestedSleeps: [TimeInterval] { withStorage { $0.requestedSleeps } }
    var waiterCount: Int { withStorage { $0.waiters.count } }

    /// Resumes the oldest parked sleeper.
    func releaseNext() {
        let parked = withStorage { storage -> CheckedContinuation<Void, any Error>? in
            guard let id = storage.order.first else { return nil }
            storage.order.removeFirst()
            return storage.waiters.removeValue(forKey: id)
        }
        parked?.resume()
    }

    /// Resumes every parked sleeper.
    func releaseAll() {
        let parked = withStorage { storage -> [CheckedContinuation<Void, any Error>] in
            let pending = storage.order.compactMap { storage.waiters[$0] }
            storage.waiters.removeAll()
            storage.order.removeAll()
            return pending
        }
        parked.forEach { $0.resume() }
    }

    // MARK: PlaybackClock

    func now() -> Date { withStorage { $0.now } }

    func sleep(seconds: TimeInterval) async throws {
        let behavior = withStorage { storage -> SleepBehavior in
            storage.requestedSleeps.append(seconds)
            return storage.behavior
        }
        switch behavior {
        case .immediate:
            return
        case .parked:
            try await park(cooperatively: true)
        case .uncooperativelyParked:
            try await park(cooperatively: false)
        }
    }

    private func park(cooperatively: Bool) async throws {
        let id = UUID()
        guard cooperatively else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                withStorage { storage in
                    storage.waiters[id] = continuation
                    storage.order.append(id)
                }
            }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = withStorage { storage -> Bool in
                    if Task.isCancelled { return true }
                    storage.waiters[id] = continuation
                    storage.order.append(id)
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let parked = self.withStorage { storage -> CheckedContinuation<Void, any Error>? in
                storage.order.removeAll { $0 == id }
                return storage.waiters.removeValue(forKey: id)
            }
            parked?.resume(throwing: CancellationError())
        }
    }
}

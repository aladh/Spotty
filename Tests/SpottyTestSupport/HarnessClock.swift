import Foundation
import SpottyRuntimeContracts

/// The playback clock boundary checks inject.
///
/// Parked sleeps are explicit barriers. Scheduled sleeps follow the injected time;
/// immediate sleeps support checks that only need retry attempts to finish.
public final class HarnessClock: PlaybackClock, @unchecked Sendable {
    /// What `sleep(seconds:)` does.
    public enum SleepBehavior: Sendable {
        /// Returns at once unless cancelled, so a deadline elapses immediately.
        case immediate
        /// Registers a waiter that `releaseNext()`/`releaseAll()` resumes. Cooperative
        /// cancellation throws `CancellationError` and never leaves the waiter registered.
        case parked
        /// Like `.parked`, but ignores cancellation, so a replaced sleeper stays suspended.
        case uncooperativelyParked
        /// Sleeps until `advance(seconds:)` or `set(now:)` reaches their individual deadlines.
        case scheduled
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Date?
    }

    private struct Storage {
        var now: Date
        var behavior: SleepBehavior
        var requestedSleeps: [TimeInterval] = []
        var waiters: [UUID: Waiter] = [:]
        var order: [UUID] = []
        var releaseGeneration: UInt64 = 0
    }

    private let lock = NSLock()
    private var storage: Storage

    public init(now: Date = HarnessDates.fixed, sleep: SleepBehavior = .parked) {
        storage = Storage(now: now, behavior: sleep)
    }

    /// A fixed instant whose sleeps only end on cancellation. The suite's default.
    public static func sticky(
        now: Date = HarnessDates.fixed,
        sleep: SleepBehavior = .parked
    ) -> HarnessClock {
        HarnessClock(now: now, sleep: sleep)
    }

    /// A fixed instant the check steps with `advance(seconds:)`; sleeps return at once.
    public static func advancing(from now: Date = HarnessDates.fixed) -> HarnessClock {
        HarnessClock(now: now, sleep: .immediate)
    }

    /// A fixed instant whose sleepers park until released.
    public static func parked(now: Date = HarnessDates.fixed) -> HarnessClock {
        HarnessClock(now: now, sleep: .parked)
    }

    public static func scheduled(now: Date = HarnessDates.fixed) -> HarnessClock {
        HarnessClock(now: now, sleep: .scheduled)
    }

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    public var sleepBehavior: SleepBehavior {
        get { withStorage { $0.behavior } }
        set { withStorage { $0.behavior = newValue } }
    }

    public func advance(seconds: TimeInterval) {
        precondition(seconds.isFinite && seconds >= 0)
        updateTime { $0.addingTimeInterval(seconds) }
    }

    public func set(now: Date) {
        updateTime { _ in now }
    }

    private func updateTime(_ update: (Date) -> Date) {
        let due = withStorage { storage -> [CheckedContinuation<Void, any Error>] in
            storage.now = update(storage.now)
            let ids = storage.order.filter { id in
                guard let deadline = storage.waiters[id]?.deadline else { return false }
                return deadline <= storage.now
            }
            let due = ids.compactMap { storage.waiters.removeValue(forKey: $0)?.continuation }
            storage.order.removeAll { storage.waiters[$0] == nil }
            return due
        }
        due.forEach { $0.resume() }
    }

    // MARK: Observation

    public var requestedSleeps: [TimeInterval] { withStorage { $0.requestedSleeps } }
    public var waiterCount: Int { withStorage { $0.waiters.count } }

    /// Resumes the oldest parked sleeper.
    public func releaseNext() {
        let parked = withStorage { storage -> CheckedContinuation<Void, any Error>? in
            guard let id = storage.order.first else { return nil }
            storage.order.removeFirst()
            return storage.waiters.removeValue(forKey: id)?.continuation
        }
        parked?.resume()
    }

    /// Resumes every parked sleeper.
    public func releaseAll() {
        let parked = withStorage { storage -> [CheckedContinuation<Void, any Error>] in
            storage.releaseGeneration &+= 1
            let pending = storage.order.compactMap { storage.waiters[$0]?.continuation }
            storage.waiters.removeAll()
            storage.order.removeAll()
            return pending
        }
        parked.forEach { $0.resume() }
    }

    // MARK: PlaybackClock

    public func now() -> Date { withStorage { $0.now } }

    public func sleep(seconds: TimeInterval) async throws {
        let (behavior, releaseGeneration, deadline) = withStorage { storage -> (SleepBehavior, UInt64, Date?) in
            storage.requestedSleeps.append(seconds)
            let deadline = storage.behavior == .scheduled ? storage.now.addingTimeInterval(max(0, seconds)) : nil
            return (storage.behavior, storage.releaseGeneration, deadline)
        }
        switch behavior {
        case .immediate:
            try Task.checkCancellation()
            return
        case .parked:
            try await park(cooperatively: true, releaseGeneration: releaseGeneration)
        case .uncooperativelyParked:
            try await park(cooperatively: false, releaseGeneration: releaseGeneration)
        case .scheduled:
            try await park(cooperatively: true, releaseGeneration: releaseGeneration, deadline: deadline)
        }
    }

    private func park(cooperatively: Bool, releaseGeneration: UInt64, deadline: Date? = nil) async throws {
        let id = UUID()
        guard cooperatively else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let released = withStorage { storage -> Bool in
                    if storage.releaseGeneration != releaseGeneration { return true }
                    storage.waiters[id] = Waiter(continuation: continuation, deadline: nil)
                    storage.order.append(id)
                    return false
                }
                if released {
                    continuation.resume()
                }
            }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Registration {
                    case parked
                    case cancelled
                    case released
                }
                let registration = withStorage { storage -> Registration in
                    if Task.isCancelled { return .cancelled }
                    if storage.releaseGeneration != releaseGeneration { return .released }
                    if let deadline, deadline <= storage.now { return .released }
                    storage.waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                    storage.order.append(id)
                    return .parked
                }
                switch registration {
                case .parked:
                    break
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .released:
                    continuation.resume()
                }
            }
        } onCancel: {
            let parked = self.withStorage { storage -> CheckedContinuation<Void, any Error>? in
                storage.order.removeAll { $0 == id }
                return storage.waiters.removeValue(forKey: id)?.continuation
            }
            parked?.resume(throwing: CancellationError())
        }
    }
}

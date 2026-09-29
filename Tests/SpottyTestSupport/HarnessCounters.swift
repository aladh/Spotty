import Synchronization

/// Small named counters shared by fixtures driven across actors and blocking worker threads.
public final class HarnessCounters: Sendable {
    private let storage = Mutex<[String: Int]>([:])

    public init() {}

    public func record(_ name: String) { adjust(name, by: 1) }

    public func adjust(_ name: String, by delta: Int) {
        storage.withLock { $0[name, default: 0] += delta }
    }

    public func count(_ name: String) -> Int { storage.withLock { $0[name, default: 0] } }
}

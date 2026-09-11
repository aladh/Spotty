import Foundation

/// Wake-up for a writer that has armed a wait on a full ring.
///
/// Control and the pull side signal only while a wait is armed, covering the unlock-to-wait
/// window without leaving a generation for a later unrelated park. Timeouts use a monotonic
/// dispatch deadline.
public nonisolated final class PCMWriteSpace: @unchecked Sendable {
    private let stateLock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var waiting = false
    private var signaled = false

    public init() {}

    /// Marks that the caller will `wait`. Must run before releasing `bufferLock`.
    public func arm() {
        stateLock.lock()
        // There can only be one pending wake for an armed wait. Drain one left by a
        // superseded arm before reusing the semaphore.
        _ = wake.wait(timeout: .now())
        waiting = true
        signaled = false
        stateLock.unlock()
    }

    /// Wakes an armed writer. No-op if no wait is in the unlock-to-wait or parked window.
    public func signalIfArmed() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard waiting, !signaled else { return }
        signaled = true
        wake.signal()
    }

    /// Returns `true` when an armed wait was signaled, `false` on timeout.
    /// `onWillBlock` runs while this lock is held, immediately before the semaphore wait.
    /// The callback must only signal a test handshake and return; it must not call
    /// `signalIfArmed`, or it would deadlock on the state lock.
    @discardableResult
    public func wait(timeoutMilliseconds: Int, onWillBlock: (() -> Void)? = nil) -> Bool {
        stateLock.lock()
        if signaled {
            _ = wake.wait(timeout: .now())
            signaled = false
            waiting = false
            stateLock.unlock()
            return true
        }
        let deadline = DispatchTime.now() + .milliseconds(max(timeoutMilliseconds, 0))
        onWillBlock?()
        stateLock.unlock()

        let didWake = wake.wait(timeout: deadline) == .success

        stateLock.lock()
        defer { stateLock.unlock() }
        if didWake || signaled {
            // A signal racing with the timeout may set `signaled` after the semaphore
            // reports timed out. Consume that permit before completing the wait.
            if !didWake {
                _ = wake.wait(timeout: .now())
            }
            signaled = false
            waiting = false
            return true
        }
        waiting = false
        return false
    }
}

import Foundation
import Synchronization

/// Wake-up for a writer that has armed a wait on a full ring.
///
/// Control and the pull side signal only while a wait is armed, covering the unlock-to-wait
/// window without leaving a generation for a later unrelated park. Timeouts use a monotonic
/// dispatch deadline.
nonisolated final class PCMWriteSpace: Sendable {
    private enum State: Equatable, Sendable { case idle, armed, signaled }
    private let state = Mutex(State.idle)
    private let wake = DispatchSemaphore(value: 0)

    init() {}

    /// Marks that the caller will `wait`. Must run before releasing `bufferLock`.
    func arm() {
        state.withLock { state in
            // Drain a wake left by a superseded arm before reusing the semaphore.
            _ = wake.wait(timeout: .now())
            state = .armed
        }
    }

    /// Wakes an armed writer. No-op if no wait is in the unlock-to-wait or parked window.
    func signalIfArmed() {
        state.withLock { state in
            guard state == .armed else { return }
            state = .signaled
            wake.signal()
        }
    }

    /// Returns `true` when an armed wait was signaled, `false` on timeout.
    /// `onWillBlock` runs while this lock is held, immediately before the semaphore wait.
    /// The callback must only signal a test handshake and return; it must not call
    /// `signalIfArmed`, or it would deadlock on the state lock.
    @discardableResult
    func wait(timeoutMilliseconds: Int, onWillBlock: (() -> Void)? = nil) -> Bool {
        let deadline = state.withLock { state -> DispatchTime? in
            if state == .signaled {
                _ = wake.wait(timeout: .now())
                state = .idle
                return nil
            }
            let deadline = DispatchTime.now() + .milliseconds(max(timeoutMilliseconds, 0))
            onWillBlock?()
            return deadline
        }
        guard let deadline else { return true }
        let didWake = wake.wait(timeout: deadline) == .success

        return state.withLock { state in
            defer { state = .idle }
            guard didWake || state == .signaled else { return false }
            // A signal racing with the timeout may set `signaled` after the semaphore
            // reports timed out. Consume that permit before completing the wait.
            if !didWake { _ = wake.wait(timeout: .now()) }
            return true
        }
    }
}

/// One full-buffer wait per PCM callback. The value stays local to the writer, so a route reset
/// can wake it or free space without replenishing its allowance. Copy admission belongs to the buffer.
nonisolated struct PCMWriteBudget {
    static let timeoutMilliseconds = 500
    private var spent = false

    mutating func takeWait(isRendering: Bool) -> Bool {
        guard isRendering, !spent else { return false }
        spent = true
        return true
    }
}

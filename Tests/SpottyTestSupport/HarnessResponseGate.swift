import Foundation
import os

/// A scripted dependency response. Values sent before admission are retained in FIFO order.
/// Tests close the gate in `defer`, so failed prerequisites release current and future calls.
public final class HarnessResponseGate<Value: Sendable>: Sendable {
    public enum Cancellation: Sendable {
        case cooperative
        /// Proves lifetime fencing against a dependency that completes after caller cancellation.
        case ignored
    }

    private struct State {
        var requests = 0
        var closed = false
        var results: [Result<Value, any Error>] = []
        var order: [UUID] = []
        var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cancellation: Cancellation

    public init(cancellation: Cancellation = .cooperative) {
        self.cancellation = cancellation
    }

    public var requestCount: Int { state.withLock { $0.requests } }
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    public func wait() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    state.requests += 1
                    if state.closed || (cancellation == .cooperative && Task.isCancelled) {
                        return .failure(CancellationError())
                    }
                    if !state.results.isEmpty { return state.results.removeFirst() }
                    state.order.append(id)
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            guard self.cancellation == .cooperative else { return }
            let waiter = self.state.withLock { state in
                state.order.removeAll { $0 == id }
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    public func finish(_ value: Value) { resolve(.success(value)) }

    public func resolve(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard !state.closed else { return nil }
            guard !state.order.isEmpty else {
                state.results.append(result)
                return nil
            }
            return state.waiters.removeValue(forKey: state.order.removeFirst())
        }
        waiter?.resume(with: result)
    }

    /// Explicit cleanup overrides even deliberately ignored caller cancellation.
    public func close() {
        let waiters = state.withLock { state in
            state.closed = true
            state.results.removeAll()
            state.order.removeAll()
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

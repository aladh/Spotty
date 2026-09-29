import Foundation
import SpottyDomain
import Synchronization

/// One read entrance owns admission, sharing, publication authority, and presentation settlement.
/// Features supply content/error policy; cancelling a caller never waits for provider cooperation.
@MainActor
final class CatalogReadFlights<Key: Hashable & Sendable> {
    enum Scope { case singleSelection, perKey }

    struct Handle: Sendable {
        let key: Key
        let identity: AccountScopedRequestIdentity
        let sessionSnapshot: CatalogSessionSnapshot
    }

    private nonisolated final class Waiter: Sendable {
        private struct State {
            var finished = false
            var continuation: CheckedContinuation<Void, Never>?
        }
        private let state = Mutex(State())

        func wait() async {
            await withCheckedContinuation { continuation in
                let finished = state.withLock { state in
                    if state.finished { return true }
                    state.continuation = continuation
                    return false
                }
                if finished { continuation.resume() }
            }
        }

        func finish() {
            let continuation = state.withLock { state in
                state.finished = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }

    private nonisolated final class Request: Sendable {
        private struct State {
            var active = true
            var task: Task<Void, Never>?
            var waiters: [UUID: Waiter] = [:]
        }
        let handle: Handle
        let settled: @MainActor @Sendable () -> Void
        private let state = Mutex(State())

        init(handle: Handle, settled: @escaping @MainActor @Sendable () -> Void) {
            self.handle = handle
            self.settled = settled
        }

        var isActive: Bool { state.withLock { $0.active } }

        func install(_ task: Task<Void, Never>) { state.withLock { $0.task = task } }

        func join(_ waiter: Waiter, id: UUID) -> Bool {
            state.withLock { state in
                guard state.active else { return false }
                state.waiters[id] = waiter
                return true
            }
        }

        /// The final cancellation fences publication synchronously, before MainActor cleanup.
        func cancel(_ id: UUID) -> (waiter: Waiter, last: Bool)? {
            let removed = state.withLock { state -> (Waiter, Bool, Task<Void, Never>?)? in
                guard let waiter = state.waiters.removeValue(forKey: id) else { return nil }
                guard state.waiters.isEmpty else { return (waiter, false, nil) }
                state.active = false
                let task = state.task
                state.task = nil
                return (waiter, true, task)
            }
            guard let (waiter, last, task) = removed else { return nil }
            task?.cancel()
            return (waiter, last)
        }

        func take() -> (task: Task<Void, Never>?, waiters: [Waiter]) {
            state.withLock { state in
                state.active = false
                let result = (state.task, Array(state.waiters.values))
                state.task = nil
                state.waiters.removeAll()
                return result
            }
        }
    }

    private let session: CatalogSessionAvailability
    private let scope: Scope
    private var nextID: UInt64 = 0
    private var requests: [Key: Request] = [:]

    init(session: CatalogSessionAvailability, scope: Scope = .singleSelection) {
        self.session = session
        self.scope = scope
    }

    isolated deinit { reset() }

    func reset() {
        let retired = requests
        requests.removeAll(keepingCapacity: false)
        for request in retired.values { settle(request, cancelling: true) }
    }

    func read(
        _ key: Key, force: Bool = false,
        started: @MainActor (Handle) -> Void = { _ in },
        settled: @escaping @MainActor @Sendable () -> Void = {},
        operation: @escaping @MainActor (Handle) async -> Void
    ) async {
        guard !Task.isCancelled, session.isAvailable else { return }
        let id = UUID()
        let waiter = Waiter()
        let request: Request
        if !force, let existing = requests[key], existing.handle.sessionSnapshot == session.snapshot,
            existing.join(waiter, id: id)
        {
            request = existing
        } else {
            switch scope {
            case .singleSelection: reset()
            case .perKey:
                if let retired = requests.removeValue(forKey: key) { settle(retired, cancelling: true) }
            }
            nextID &+= 1
            let handle = Handle(
                key: key, identity: session.requestIdentity(requestID: nextID), sessionSnapshot: session.snapshot)
            request = Request(handle: handle, settled: settled)
            _ = request.join(waiter, id: id)
            requests[key] = request
            started(handle)
            request.install(
                Task { [weak self] in
                    defer { self?.complete(handle) }
                    guard self?.isCurrent(handle) == true else { return }
                    await operation(handle)
                })
        }
        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: { [weak self] in
            guard let cancelled = request.cancel(id) else { return }
            if cancelled.last {
                Task { @MainActor [weak self] in
                    self?.complete(request.handle)
                    cancelled.waiter.finish()
                }
            } else {
                cancelled.waiter.finish()
            }
        }
    }

    func isCurrent(_ handle: Handle) -> Bool {
        guard let request = requests[handle.key], request.isActive else { return false }
        return handle.identity.isCurrent(
            requestID: request.handle.identity.requestID, accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision, isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled)
    }

    func shouldReport(_ error: any Error, for handle: Handle) -> Bool {
        !isCancellation(error) && isCurrent(handle)
    }

    private func complete(_ handle: Handle) {
        guard requests[handle.key]?.handle.identity.requestID == handle.identity.requestID,
            let request = requests.removeValue(forKey: handle.key)
        else { return }
        settle(request, cancelling: false)
    }

    private func settle(_ request: Request, cancelling: Bool) {
        let retired = request.take()
        if cancelling { retired.task?.cancel() }
        request.settled()
        for waiter in retired.waiters { waiter.finish() }
    }
}

import os

/// Arms one upcoming dependency call. Rearming releases older work; close permanently disarms
/// the fixture and releases pending/active calls. Tests close it in defer on every exit path.
public final class HarnessSuspension: Sendable {
    private struct State {
        var pending: HarnessResponseGate<Void>?
        var active: HarnessResponseGate<Void>?
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}
    deinit { close() }

    public var isWaiting: Bool { state.withLock { ($0.active?.waiterCount ?? 0) > 0 } }

    public func arm() {
        let retired = state.withLock { state -> [HarnessResponseGate<Void>] in
            guard !state.closed else { return [] }
            let retired = [state.pending, state.active].compactMap { $0 }
            state = State(pending: HarnessResponseGate())
            return retired
        }
        retired.forEach { $0.close() }
    }

    public func waitIfArmed() async {
        let gate = state.withLock { state -> HarnessResponseGate<Void>? in
            guard let gate = state.pending else { return nil }
            state.pending = nil
            state.active = gate
            return gate
        }
        guard let gate else { return }
        // Completion never rewrites the slot: an earlier call may finish after a rearm.
        // Resume, rearm or close releases the one bounded gate reference.
        try? await gate.wait()
    }

    public func resume() {
        let gate = state.withLock { state -> HarnessResponseGate<Void>? in
            defer { state.active = nil }
            return state.active
        }
        gate?.finish(())
    }

    public func close() {
        let retired = state.withLock { state in
            let retired = [state.pending, state.active].compactMap { $0 }
            state = State(closed: true)
            return retired
        }
        retired.forEach { $0.close() }
    }
}

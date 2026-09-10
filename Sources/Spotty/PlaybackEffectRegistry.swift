import Foundation

enum PlaybackEffectID: Hashable, Sendable {
    case engineEvents
    case grantRevocations
    case lifecycle
    case queueServiceBootstrap
    case preferencesRestore
    case catalogLoad
    case positionRefresh
    case queueSnapshot
    case connectQueueAccept
    case queueReplacement
    case queueRefresh
    case trackMetadata
    case commandError
    case engineRecovery
    case reconnectRehydration
    case credentialRejection
    case commandDeadline(UUID)
    case command(UUID)
    case queueCommand(UUID)

    var isAccountScoped: Bool {
        switch self {
        case .engineEvents, .grantRevocations, .lifecycle:
            false
        default:
            true
        }
    }
}

/// One owner for every store-level asynchronous lifetime. Replacing a named effect cancels the
/// superseded task; account teardown can invalidate all account work in one operation.
///
/// Transport commands use unique `.command(UUID)` tokens, so this is lifetime ownership rather than
/// kind-level cancel-in-flight. A second pause is refused by the pending-command gate, not by
/// replacing an in-flight token. `replace` may supply a MainActor `onCancel`, which runs for both
/// `cancel` and `replace` of that token so ordinary command cancellation can settle reducer state
/// before the task resumes. `complete` drops a registration only when that same object still
/// owns the token. Sequential Add to Queue keeps unique `.queueCommand(UUID)` tokens so ordered
/// multi-add is not cancelled. Authoritative Connect `set_queue` replacement uses one
/// `.queueReplacement` lifetime plus a MainActor request token: a second removal is refused while
/// one is in flight, because cancellation cannot undo a `set_queue` Spotify already accepted.
/// See `docs/architecture/adrs/ADR-003-playback-command-effects.md`.
final class PlaybackEffectRegistration {}

/// Exact identity of one currently registered effect task. Capture it before the registry
/// invalidates that token; waiting still observes that task after the live entry is gone.
struct PlaybackEffectSettlement: Sendable {
    fileprivate let task: Task<Void, Never>

    func wait() async {
        await task.value
    }
}

/// The result of cancelling a set of effects and giving their tasks a bounded opportunity to
/// unwind. A timed-out effect has already lost registry ownership, but its underlying operation
/// may still be suspended in a non-cancelable system call. Keeping that distinction explicit lets
/// session teardown continue without pretending that cancellation stopped external work.
struct PlaybackEffectDrainReport: Equatable, Sendable {
    let requested: Set<PlaybackEffectID>
    let settled: Set<PlaybackEffectID>
    let timedOut: Set<PlaybackEffectID>

    var didSettleAll: Bool { timedOut.isEmpty && requested == settled }
}

private actor PlaybackEffectDrainState {
    private let requested: Set<PlaybackEffectID>
    private var pending: Set<PlaybackEffectID>
    private var continuation: CheckedContinuation<PlaybackEffectDrainReport, Never>?
    private var didTimeOut = false

    init(requested: Set<PlaybackEffectID>) {
        self.requested = requested
        pending = requested
    }

    func wait() async -> PlaybackEffectDrainReport {
        guard !pending.isEmpty else { return report() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            resumeIfFinished()
        }
    }

    func markSettled(_ id: PlaybackEffectID) {
        pending.remove(id)
        resumeIfFinished()
    }

    func timeOut() {
        guard !pending.isEmpty else { return }
        didTimeOut = true
        resumeIfFinished()
    }

    private func resumeIfFinished() {
        guard let continuation, didTimeOut || pending.isEmpty else { return }
        self.continuation = nil
        continuation.resume(returning: report())
    }

    private func report() -> PlaybackEffectDrainReport {
        PlaybackEffectDrainReport(
            requested: requested,
            settled: requested.subtracting(pending),
            timedOut: pending
        )
    }
}

@MainActor
final class PlaybackEffectRegistry {
    /// A task that cannot observe cancellation must not hold account replacement forever. This is
    /// deliberately short: it is a grace period for cooperative cleanup, not an external I/O
    /// timeout or a claim that an already-sent request was undone.
    nonisolated static let accountDrainTimeoutNanoseconds: UInt64 = 250_000_000

    private var tasks: [PlaybackEffectID: Task<Void, Never>] = [:]
    private var registrations: [PlaybackEffectID: PlaybackEffectRegistration] = [:]
    private var cancellationHandlers: [PlaybackEffectID: @MainActor () -> Void] = [:]

    func settlement(of id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        tasks[id].map(PlaybackEffectSettlement.init(task:))
    }

    func replace(
        _ id: PlaybackEffectID,
        with task: Task<Void, Never>,
        registration: PlaybackEffectRegistration? = nil,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        let previousHandler = cancellationHandlers[id]
        let previousTask = tasks[id]
        let owned = registration ?? PlaybackEffectRegistration()
        tasks[id] = task
        registrations[id] = owned
        cancellationHandlers[id] = onCancel
        previousHandler?()
        previousTask?.cancel()
    }

    @discardableResult
    func cancel(_ id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        guard let task = tasks.removeValue(forKey: id) else {
            cancellationHandlers[id] = nil
            registrations[id] = nil
            return nil
        }
        let settlement = PlaybackEffectSettlement(task: task)
        let handler = cancellationHandlers.removeValue(forKey: id)
        registrations[id] = nil
        handler?()
        task.cancel()
        return settlement
    }

    func complete(_ id: PlaybackEffectID, registration: PlaybackEffectRegistration) {
        guard registrations[id] === registration else { return }
        cancellationHandlers.removeValue(forKey: id)
        registrations[id] = nil
        tasks[id] = nil
    }

    func complete(_ id: PlaybackEffectID) {
        cancellationHandlers.removeValue(forKey: id)
        registrations[id] = nil
        tasks[id] = nil
    }

    /// A lost observation interval makes command confirmation history unknowable. Cancel every
    /// command task, including one whose pending slot was already consumed by a confirmation.
    /// Cancellation fences later completion; it cannot undo a request already sent to Spotify.
    func cancelPlaybackCommands() {
        let ids = tasks.keys.filter { id in
            switch id {
            case .command, .commandDeadline, .queueCommand, .queueReplacement: true
            default: false
            }
        }
        for id in ids { cancel(id) }
    }

    @discardableResult
    func cancelAccountScoped() -> [PlaybackEffectID: PlaybackEffectSettlement] {
        let ids = tasks.keys.filter(\.isAccountScoped)
        var settlements: [PlaybackEffectID: PlaybackEffectSettlement] = [:]
        for id in ids {
            let settlement = settlement(of: id)
            _ = cancel(id)
            if let settlement {
                settlements[id] = settlement
            }
        }
        return settlements
    }

    /// Cancels account-scoped work and waits for each captured task until the bounded grace period
    /// expires. The registry entries are removed before awaiting, so late completion cannot clear
    /// or replace a newer lifetime. Tasks that finish after the report remain inert and are named
    /// in `timedOut` as evidence of a non-cancelable operation.
    func cancelAccountScopedAndDrain(
        timeoutNanoseconds: UInt64 = PlaybackEffectRegistry.accountDrainTimeoutNanoseconds
    ) async -> PlaybackEffectDrainReport {
        await drain(cancelAccountScoped(), timeoutNanoseconds: timeoutNanoseconds)
    }

    func drain(
        _ settlements: [PlaybackEffectID: PlaybackEffectSettlement],
        timeoutNanoseconds: UInt64 = PlaybackEffectRegistry.accountDrainTimeoutNanoseconds
    ) async -> PlaybackEffectDrainReport {
        let requested = Set(settlements.keys)
        let state = PlaybackEffectDrainState(requested: requested)
        guard !requested.isEmpty else {
            return PlaybackEffectDrainReport(requested: [], settled: [], timedOut: [])
        }

        for (id, settlement) in settlements {
            // These monitors must not inherit the registry's MainActor isolation. A cancelled
            // effect can be waiting on MainActor work; if the monitor is actor-bound too, the
            // timeout cannot make progress while that work is stalled and teardown is no longer
            // bounded by the grace period.
            Task.detached {
                await settlement.wait()
                await state.markSettled(id)
            }
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await state.timeOut()
        }
        let report = await state.wait()
        timeoutTask.cancel()
        return report
    }
}

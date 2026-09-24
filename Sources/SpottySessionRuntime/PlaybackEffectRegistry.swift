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

/// Owns every runtime effect from registration through completion. Named entries keep the task,
/// identity and cancellation handler together; callers start work through `run` and retain exact
/// settlement handles when they need to await it after cancellation or replacement.
///
/// Command UUIDs identify requests; admission gates decide which may overlap. Queue replacement
/// uses one effect lifetime: queue code owns its request token and intent deadline, while this
/// registry completes the task. Cancellation cannot undo an already-dispatched replacement.
@SessionRuntimeActor
final class PlaybackEffectRegistry {
    /// A task that cannot observe cancellation must not hold account replacement forever. This is
    /// deliberately short: it is a grace period for cooperative cleanup, not an external I/O
    /// timeout or a claim that an already-sent request was undone.
    nonisolated static let accountDrainTimeoutNanoseconds: UInt64 = 250_000_000

    private final class Registration: Sendable {}

    private struct Entry {
        let registration: Registration
        let task: Task<Void, Never>
        let onCancel: (@SessionRuntimeActor () -> Void)?
    }

    private var entries: [PlaybackEffectID: Entry] = [:]

    func settlement(of id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        entries[id].map { PlaybackEffectSettlement(task: $0.task) }
    }

    /// Snapshot live effect identities for synchronization diagnostics. This does not transfer or
    /// alter ownership; callers that need to await after invalidation retain the returned handles.
    func settlements() -> [PlaybackEffectID: PlaybackEffectSettlement] {
        entries.mapValues { PlaybackEffectSettlement(task: $0.task) }
    }

    /// Registers, starts and completes one effect. The replacement is installed before the old
    /// cancellation handler runs synchronously. Calls to `cancel` or `run` for the same ID from
    /// that handler affect the replacement.
    /// Late completion removes only its own entry, including when cancellation was ignored.
    func run(
        _ id: PlaybackEffectID,
        onCancel: (@SessionRuntimeActor () -> Void)? = nil,
        operation: @escaping @SessionRuntimeActor @Sendable () async -> Void
    ) {
        let registration = Registration()
        let task = Task { [weak self] in
            defer { self?.complete(id, registration: registration) }
            await operation()
        }
        let previous = entries.updateValue(
            Entry(registration: registration, task: task, onCancel: onCancel), forKey: id)
        previous?.onCancel?()
        previous?.task.cancel()
    }

    @discardableResult
    func cancel(_ id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.onCancel?()
        entry.task.cancel()
        return PlaybackEffectSettlement(task: entry.task)
    }

    private func complete(_ id: PlaybackEffectID, registration: Registration) {
        guard entries[id]?.registration === registration else { return }
        entries[id] = nil
    }

    /// A lost observation interval makes command confirmation history unknowable. Cancel every
    /// command task, including one whose pending slot was already consumed by a confirmation.
    /// Cancellation fences later completion; it cannot undo a request already sent to Spotify.
    func cancelPlaybackCommands() {
        let ids = entries.keys.filter { id in
            switch id {
            case .command, .commandDeadline, .queueCommand, .queueReplacement: true
            default: false
            }
        }
        for id in ids { cancel(id) }
    }

    @discardableResult
    func cancelAccountScoped() -> [PlaybackEffectID: PlaybackEffectSettlement] {
        let ids = entries.keys.filter(\.isAccountScoped)
        var settlements: [PlaybackEffectID: PlaybackEffectSettlement] = [:]
        for id in ids {
            if let settlement = cancel(id) {
                settlements[id] = settlement
            }
        }
        return settlements
    }

    /// Waits for captured tasks until the bounded grace period expires. Cancellation removes
    /// registry entries before awaiting, so late completion cannot clear a newer lifetime.
    /// Tasks that finish after the report are named in `timedOut`.
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
            // These monitors must not inherit the registry's SessionRuntimeActor isolation.
            // Cancelled effects can be waiting on that actor or on MainActor UI work. Detached
            // monitors and the watchdog keep drain bookkeeping independent of either executor.
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

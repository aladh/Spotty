import Foundation

enum PlaybackEffectID: Hashable {
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

@MainActor
final class PlaybackEffectRegistry {
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

    func cancel(_ id: PlaybackEffectID) {
        guard let task = tasks.removeValue(forKey: id) else {
            cancellationHandlers[id] = nil
            registrations[id] = nil
            return
        }
        let handler = cancellationHandlers.removeValue(forKey: id)
        registrations[id] = nil
        handler?()
        task.cancel()
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

    func cancelAccountScoped() {
        let ids = tasks.keys.filter(\.isAccountScoped)
        for id in ids { cancel(id) }
    }
}

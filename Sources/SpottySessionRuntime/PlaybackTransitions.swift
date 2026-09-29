import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Synchronization

/// One synchronous consistency boundary for reducer state and queued dispatch authority.
/// Callers cannot mutate state, drain receipts, or reconcile individual permits independently.
@SessionRuntimeActor
final class PlaybackTransitions {
    struct Commit {
        let reduction: PlaybackReduction
        /// A rejected incoming event can still commit an independently accepted dispatch receipt.
        let needsPublication: Bool
    }

    private struct Entry {
        let intentID: UUID
        let permit: PlaybackDispatchPermit
    }

    private(set) var state: PlaybackState
    private let clock: any PlaybackClock
    private var permits: [Entry] = []

    init(initialState: PlaybackState, clock: any PlaybackClock) {
        state = initialState
        self.clock = clock
    }

    isolated deinit { invalidateDispatches() }

    func apply(_ envelope: PlaybackEventEnvelope, currentLifetime: PlaybackLifetime) -> Commit {
        let previousContext = playbackDispatchContext(
            state: state, accountEpoch: currentLifetime.accountEpoch,
            engineGeneration: currentLifetime.engineGeneration)
        if case let .commandTimedOut(id) = envelope.event,
            envelope.accountEpoch == state.accountEpoch, envelope.engineEpoch == state.engineEpoch,
            PlaybackReducer.accepts(
                state, accountEpoch: envelope.accountEpoch, engineEpoch: envelope.engineEpoch,
                source: envelope.source, revision: envelope.revision)
        {
            // Expiry must win against an unclaimed permit before collecting its final receipt.
            // A refused old/future lifetime or source revision has no dispatch authority.
            for entry in permits where entry.intentID == id { entry.permit.invalidate() }
        }

        var next = state
        for entry in permits {
            if let date = entry.permit.takeDispatchReceipt() {
                _ = PlaybackReducer.reduce(
                    &next,
                    envelope: PlaybackEventEnvelope(
                        accountEpoch: currentLifetime.accountEpoch, engineEpoch: currentLifetime.engineGeneration,
                        source: .command, receivedAt: date,
                        event: .commandDispatched(id: entry.intentID, at: date)))
            }
        }
        permits.removeAll { $0.permit.canDiscard }
        let receiptState = next
        let reduction = PlaybackReducer.apply(&next, envelope: envelope)
        guard reduction.accepted else {
            let changed = state != receiptState
            state = receiptState
            return Commit(reduction: .rejected, needsPublication: changed)
        }

        let nextContext = playbackDispatchContext(
            state: next, accountEpoch: envelope.accountEpoch, engineGeneration: next.engineEpoch)
        if envelope.accountEpoch != currentLifetime.accountEpoch
            || envelope.engineEpoch != currentLifetime.engineGeneration || previousContext != nextContext
        {
            invalidateDispatches()
        } else {
            for entry in permits where !ownsAdmission(entry.intentID, in: next) { entry.permit.invalidate() }
            permits.removeAll { $0.permit.canDiscard }
        }
        state = next
        return Commit(reduction: reduction, needsPublication: true)
    }

    func dispatchPermit(
        for intentID: UUID,
        ifStillWanted: @SessionRuntimeActor () -> Bool
    ) -> PlaybackDispatchPermit? {
        permits.removeAll { $0.permit.canDiscard }
        guard ownsAdmission(intentID, in: state),
            state.intents.first(where: { $0.command.id == intentID })?.outcome == .admitted,
            !permits.contains(where: { $0.intentID == intentID })
        else { return nil }
        let permit = PlaybackDispatchPermit(clock: clock)
        // Install before invoking the route predicate: any synchronous reentrant transition
        // must also see and invalidate this permit when it changes the destination.
        permits.append(Entry(intentID: intentID, permit: permit))
        guard ifStillWanted() else {
            permit.invalidate()
            return nil
        }
        return permit
    }

    /// Early lifecycle/event-loss fences use the same ledger as ordinary state transitions.
    /// Claim and invalidation are lock-linearized; an already claimed receipt must still drain.
    func invalidateDispatches() {
        for entry in permits { entry.permit.invalidate() }
        permits.removeAll { $0.permit.canDiscard }
    }

    private func ownsAdmission(_ id: UUID, in state: PlaybackState) -> Bool {
        guard let intent = state.intents.first(where: { $0.command.id == id }), !intent.outcome.isTerminal else {
            return false
        }
        return intent.command.kind == .queue || state.pendingCommands[intent.command.kind]?.id == id
    }

    private func playbackDispatchContext(
        state: PlaybackState,
        accountEpoch: UInt64,
        engineGeneration: UInt64
    ) -> PlaybackDispatchContext {
        let rawRoute = connectCommandRoute(
            owner: state.owner,
            localDeviceID: state.devices.localDeviceID
        )
        // A transport command's own optimistic `.playing` state temporarily hides the idle
        // default-local projection. Keep that intentional target stable so publishing
        // `commandStarted` does not cancel another command merely because the projection changed.
        let isOptimisticIdleLocalPlay =
            (rawRoute == .local || rawRoute == .needsDeviceSelection)
            && state.session == .ready
            && state.devices.localDeviceID?.isEmpty == false
            && state.pendingCommands[.transport]?.expectedTransport == .playing
            && (state.owner == .none || state.owner == .uncertain(nil))
        let route = isOptimisticIdleLocalPlay ? .local : rawRoute
        // A local command's effective destination is this local Connect identity. Keep that
        // identity stable when an idle candidate (`.none`/`.uncertain(nil)`) becomes confirmed
        // `.local`; ownership certainty changes, but the command is still headed to the same Mac.
        // Remote routes retain their exact source/target identity through `route`.
        let defaultLocalDeviceID =
            route == .local
            ? state.devices.localDeviceID
            : ConnectDeviceProjection.defaultLocalDevice(in: state)?.id
        return PlaybackDispatchContext(
            lifetime: PlaybackLifetime(
                accountEpoch: accountEpoch,
                engineGeneration: engineGeneration
            ),
            route: route,
            localDeviceID: state.devices.localDeviceID,
            defaultLocalDeviceID: defaultLocalDeviceID,
            session: state.session
        )
    }
}

/// State that can make a queued transport command target a different lifetime or destination.
/// High-frequency timing and metadata publications intentionally do not participate.
private struct PlaybackDispatchContext: Equatable, Sendable {
    let lifetime: PlaybackLifetime
    let route: ConnectCommandRoute
    let localDeviceID: String?
    let defaultLocalDeviceID: String?
    let session: PlaybackSessionPhase
}

/// A lock-linearized commitment shared by the transition owner and the coordinator actor. Before
/// `claim` succeeds, a lifecycle or route publication can invalidate queued work. Once `claim`
/// succeeds, the operation has crossed the point where it may be sent to the engine or Spotify;
/// later invalidation cannot revoke that already-started work.
final class PlaybackDispatchPermit: Sendable {
    private enum State: Equatable, Sendable {
        case pending
        case invalidated
        case claimed(Date?)
    }

    private let state = Mutex(State.pending)
    private let clock: any PlaybackClock

    fileprivate init(clock: any PlaybackClock = SystemPlaybackClock()) { self.clock = clock }

    fileprivate func takeDispatchReceipt() -> Date? {
        state.withLock { state in
            guard case let .claimed(receipt) = state else { return nil }
            state = .claimed(nil)
            return receipt
        }
    }

    fileprivate func invalidate() {
        state.withLock { state in
            if state == .pending { state = .invalidated }
        }
    }

    func claim() -> Bool {
        state.withLock { state in
            guard state == .pending else { return false }
            state = .claimed(clock.now())
            return true
        }
    }

    fileprivate var canDiscard: Bool {
        state.withLock { state in
            switch state {
            case .pending, .claimed(.some): false
            case .invalidated, .claimed(nil): true
            }
        }
    }

}

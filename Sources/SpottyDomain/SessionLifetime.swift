import Foundation

/// The cumulative result requested while an account teardown is in flight.
/// Clearing the persisted grant is the strongest intent and always resolves to signed out,
/// regardless of whether a weaker token-revocation failure arrived first or last.
public struct SessionTeardownIntent: Equatable, Sendable {
    public let clearGrant: Bool
    public let finalPhase: PlaybackSessionPhase

    public init(clearGrant: Bool, finalPhase: PlaybackSessionPhase) {
        self.clearGrant = clearGrant
        self.finalPhase = clearGrant ? .signedOut : finalPhase
    }

    public func merging(_ other: Self) -> Self {
        if clearGrant || other.clearGrant {
            return Self(clearGrant: true, finalPhase: .signedOut)
        }

        switch (finalPhase, other.finalPhase) {
        case let (.failed(message), _), let (_, .failed(message)):
            return Self(clearGrant: false, finalPhase: .failed(message))
        default:
            return other
        }
    }
}

/// Pure single-flight state shared by the presentation and account lifecycle owners.
/// `request` returns true only for the caller that must start the underlying teardown.
public struct SessionTeardownCoalescer: Sendable {
    public private(set) var intent: SessionTeardownIntent?

    public init() {}

    public var isActive: Bool { intent != nil }

    @discardableResult
    public mutating func request(_ requested: SessionTeardownIntent) -> Bool {
        guard let intent else {
            self.intent = requested
            return true
        }
        self.intent = intent.merging(requested)
        return false
    }

    @discardableResult
    public mutating func complete() -> SessionTeardownIntent? {
        defer { intent = nil }
        return intent
    }
}

/// Identity captured by catalog work before its first suspension. Session revision distinguishes
/// ready → unavailable → ready transitions even when the Spotify account epoch is unchanged.
public struct AccountScopedRequestIdentity: Equatable, Sendable {
    public let requestID: UInt64
    public let accountEpoch: UInt64
    public let sessionRevision: UInt64

    public init(requestID: UInt64, accountEpoch: UInt64, sessionRevision: UInt64) {
        self.requestID = requestID
        self.accountEpoch = accountEpoch
        self.sessionRevision = sessionRevision
    }

    public func isCurrent(
        requestID: UInt64,
        accountEpoch: UInt64,
        sessionRevision: UInt64,
        isAvailable: Bool,
        isCancelled: Bool
    ) -> Bool {
        self.requestID == requestID
            && self.accountEpoch == accountEpoch
            && self.sessionRevision == sessionRevision
            && isAvailable
            && !isCancelled
    }
}

/// Immutable stamp for one playback-scoped async lifetime.
///
/// Account epoch and engine generation intentionally remain distinct values, but command work
/// carries and stamps them as one unit. This is not a writable lifecycle owner, counter,
/// revision, or watermark.
public struct PlaybackLifetime: Equatable, Sendable {
    public let accountEpoch: UInt64
    public let engineGeneration: UInt64

    public init(accountEpoch: UInt64, engineGeneration: UInt64) {
        self.accountEpoch = accountEpoch
        self.engineGeneration = engineGeneration
    }

}

/// Account-scoped request cancellation is inert: it must not publish results or user-facing errors.
public func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
}

/// Connect queue *callback* watermark. Distinct from provenance-snapshot revisions
/// recorded on `PlaybackEventSource.engineQueue`. `engineEpoch` is only a stale-engine floor:
/// adopting that epoch elsewhere must not clear a newer callback generation.
public struct ConnectQueueCallbackWatermark: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var revision: UInt64

    public init(generation: UInt64 = 0, revision: UInt64 = 0) {
        self.generation = generation
        self.revision = revision
    }

    public mutating func reset() {
        generation = 0
        revision = 0
    }

    @discardableResult
    public mutating func accept(
        generation: UInt64?,
        revision: UInt64?,
        engineEpoch: UInt64
    ) -> Bool {
        var next = self
        var advancedGeneration = false
        if let generation {
            guard generation >= max(next.generation, engineEpoch) else { return false }
            if generation > next.generation {
                advancedGeneration = true
                next.generation = generation
                next.revision = 0
            }
        }
        if let revision {
            guard revision > next.revision || advancedGeneration else { return false }
            next.revision = revision
        }
        self = next
        return true
    }
}

/// Pre-reducer store admission for a playback command.
///
/// Route selection, route refusal, and waiting for local Connect identity never consult this,
/// so those paths cannot create pending commands. Duplicate-kind refusal here is the store
/// gate; the reducer also rejects a second `commandStarted` for the same kind.
public func playbackCommandShouldAdmit(
    isTearingDown: Bool,
    allowsCommands: Bool,
    hasPendingCommandForKind: Bool
) -> Bool {
    !isTearingDown && allowsCommands && !hasPendingCommandForKind
}

/// Dependent work after `PlaybackStore.send(.commandFinished)`.
///
/// Same-lifetime is the first gate: epoch invalidation and teardown stay inert even when a
/// confirmation was captured. `applyCommandOutcome` snapshots the finished command's
/// resolution before `commandFinished`; the reducer consumes that map entry.
/// Follow-up then evaluates the captured resolution before `finishAccepted`: confirmed
/// reports success, superseded stays inert, so consume-only acceptance cannot turn a
/// coordinator failure into `reportFailure`. Shuffle and repeat options confirmation use
/// the same per-command-id map. A matching engine shuffle sample records `.confirmed` so a
/// late rejection cannot restore the prior Boolean or rewrite preference. Matching
/// authoritative repeat flags confirm the same way; unrelated authoritative flags
/// supersede; lagging prior flags and non-engine option events do not confirm.
/// Every reconciled transport success carries an explicit command-ID resolution. A missing
/// pending slot is not evidence of success: it can also mean expiration or an unknown ID.
/// Reconnect-required outranks both reconciled-success paths: a confirming snapshot settles
/// what the UI shows, not whether the engine's command channel is alive. A `.confirmed`
/// resolution or an already-reconciled transport finish whose operation failed with
/// reconnect-required reports `.reconnectAfterReconciledSuccess`, which keeps the
/// presentation and rebuilds the connection. Without that, a stale Playing sample after
/// sleep/wake could confirm a resume whose engine call returned a closed channel, and the
/// app would show Playing with no audio and never reconnect.
/// A known play target is confirmed only by that target's identity, not by a lagging prior
/// track that happens to already be `.playing`. An unrelated or empty track supersedes the
/// optimistic target: rollback is cleared and a later finish stays inert.
/// Remote transfer confirmation uses the same per-command-id map. A lagging snapshot of the
/// exact prior owner cannot undo the target. An authoritative connection or devices snapshot
/// whose stable device identity matches the remote target records `.confirmed` so a late
/// rejection cannot restore the prior owner. An unrelated owner, including local/none when that
/// emptiness is not the captured prior owner, records `.superseded` and stays inert.
/// Seek confirmation and track-switch supersession both clear pending `.seek`, so a later
/// finish stays inert: `pendingCommandID == nil` cannot tell those cases apart, and seek
/// completions have no success side effect.
/// Options commands without a captured resolution keep the non-transport inert path when
/// the pending command is already gone. A newer pending id stays inert unless a captured
/// confirmation for the finished id reports success.
public enum PlaybackCommandFollowUp: Equatable, Sendable {
    case reportSuccess
    case reportFailure(reconnect: Bool)
    /// Presentation is already reconciled (a same-lifetime snapshot confirmed the command), so
    /// there is nothing to roll back or announce, but the engine reported a lifecycle failure
    /// for that same command. The connection must still be rebuilt.
    case reconnectAfterReconciledSuccess
    case inert
}

public func playbackCommandFollowUp(
    finishAccepted: Bool,
    operationSucceeded: Bool,
    requiresReconnect: Bool,
    commandKind: PlaybackCommandKind,
    pendingCommandID: UUID?,
    finishedCommandResolution: PlaybackTransportCommandResolution? = nil,
    capturedLifetime: PlaybackLifetime,
    currentLifetime: PlaybackLifetime,
    isTearingDown: Bool
) -> PlaybackCommandFollowUp {
    guard !isTearingDown, capturedLifetime == currentLifetime else {
        return .inert
    }
    let reconciledSuccess: PlaybackCommandFollowUp =
        !operationSucceeded && requiresReconnect ? .reconnectAfterReconciledSuccess : .reportSuccess
    switch finishedCommandResolution {
    case .confirmed:
        return reconciledSuccess
    case .superseded:
        return .inert
    case nil:
        break
    }
    if finishAccepted {
        return operationSucceeded ? .reportSuccess : .reportFailure(reconnect: requiresReconnect)
    }
    return .inert
}

/// Ordinary same-lifetime cancellation of one in-flight command token.
///
/// Teardown, account-epoch changes, engine-generation changes, and a missing or
/// different pending id stay inert: confirmation, supersession, a newer command, and
/// lifetime ownership already cleared the slot. Matching pending identity is the
/// once-gate; a second cancel cannot restore or complete again.
public func playbackCommandShouldSettleOrdinaryCancellation(
    pendingCommandID: UUID?,
    cancelledCommandID: UUID,
    capturedLifetime: PlaybackLifetime,
    currentLifetime: PlaybackLifetime,
    isTearingDown: Bool
) -> Bool {
    !isTearingDown
        && capturedLifetime == currentLifetime
        && pendingCommandID == cancelledCommandID
}

/// Same-lifetime settlement for a command whose route lease expired before dispatch. The command
/// was optimistically admitted, but no local C call or remote request was started, so it rolls back
/// through `commandFinished` without a transport error notice. Once a request has been sent, this
/// predicate is no longer applicable; asynchronous engine/remote reconciliation owns the result.
public func playbackCommandShouldSettleUndispatched(
    pendingCommandID: UUID?,
    undispatchedCommandID: UUID,
    capturedLifetime: PlaybackLifetime,
    currentLifetime: PlaybackLifetime,
    isTearingDown: Bool
) -> Bool {
    !isTearingDown
        && capturedLifetime == currentLifetime
        && pendingCommandID == undispatchedCommandID
}

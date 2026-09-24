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

/// Runtime admission before a playback command reaches the reducer.
///
/// Route selection, route refusal, and waiting for local Connect identity never consult this,
/// so those paths cannot create pending commands. This gate refuses a duplicate kind in
/// production; the reducer can supersede an existing intent when given a new `commandStarted`.
public func playbackCommandShouldAdmit(
    isTearingDown: Bool,
    allowsCommands: Bool,
    hasPendingCommandForKind: Bool
) -> Bool {
    !isTearingDown && allowsCommands && !hasPendingCommandForKind
}

/// Runtime follow-up after reducing `commandFinished`.
///
/// Epoch invalidation and teardown stay inert even with a captured confirmation. The runtime
/// captures the command's resolution before the reducer consumes it: confirmed work reports
/// success, superseded work stays inert, and unresolved work requires an accepted finish before
/// reporting the coordinator's outcome. Command-kind and pending-slot reconciliation belong to
/// the reducer; an absent pending slot alone cannot establish success.
///
/// A confirmed command whose operation failed with reconnect-required keeps its reconciled
/// presentation and rebuilds the connection. Observed playback settles what the UI shows, not
/// whether the engine's command channel remains alive.
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

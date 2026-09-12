import Foundation

/// The account rendered when an action was created stays attached to the request. A runtime
/// authorizes that identity before the gateway begins validation or dispatches a wire attempt.
public struct PlaylistMutationContext: Sendable {
    public let accountEpoch: UInt64
    private let admission: PlaylistMutationAdmission?

    public init(accountEpoch: UInt64) {
        self.accountEpoch = accountEpoch
        admission = nil
    }

    package init(accountEpoch: UInt64, admission: PlaylistMutationAdmission) {
        self.accountEpoch = accountEpoch
        self.admission = admission
    }

    /// This is the dispatch boundary, not a promise that a previously dispatched write can be
    /// undone. Each retry must check again after any credential or request-capacity suspension.
    package func authorizeDispatch() throws {
        try Task.checkCancellation()
        guard let admission, admission.allows(accountEpoch: accountEpoch) else {
            throw CancellationError()
        }
    }
}

/// Shared by account retirement and gateway workers; no UI publication is required to fence a
/// pending request. The lock linearizes retirement against an attempt's dispatch authorization.
package final class PlaylistMutationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var accountEpoch: UInt64
    private var isActive = false

    package init(accountEpoch: UInt64 = 1) { self.accountEpoch = accountEpoch }

    package func activate(accountEpoch: UInt64) {
        lock.withLock {
            guard self.accountEpoch == accountEpoch else { return }
            isActive = true
        }
    }

    package func retire(nextAccountEpoch: UInt64) {
        lock.withLock {
            accountEpoch = nextAccountEpoch
            isActive = false
        }
    }

    package func authorize(_ context: PlaylistMutationContext) throws -> PlaylistMutationContext {
        let authorized = PlaylistMutationContext(accountEpoch: context.accountEpoch, admission: self)
        try authorized.authorizeDispatch()
        return authorized
    }

    fileprivate func allows(accountEpoch: UInt64) -> Bool {
        lock.withLock { isActive && self.accountEpoch == accountEpoch }
    }
}

import Foundation

/// The account rendered when an action was created stays attached to the request. A runtime
/// authorizes that identity before the gateway begins validation or dispatches a wire attempt.
public struct PlaylistMutationContext: Sendable {
    public let accountEpoch: UInt64
    public init(accountEpoch: UInt64) { self.accountEpoch = accountEpoch }
}

/// Admission and a rendered account stamp are different capabilities. This value retains the
/// live fence; it must be checked again at every wire attempt after asynchronous preparation.
package struct PlaylistMutationAuthorization: Sendable {
    private let accountEpoch: UInt64
    private let admission: PlaylistMutationAdmission

    fileprivate init(accountEpoch: UInt64, admission: PlaylistMutationAdmission) {
        self.accountEpoch = accountEpoch
        self.admission = admission
    }

    /// Authorization is the dispatch boundary, not a promise that a sent write can be undone.
    package func authorizeDispatch() throws {
        try Task.checkCancellation()
        guard admission.allows(accountEpoch: accountEpoch) else { throw CancellationError() }
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

    package func authorize(_ context: PlaylistMutationContext) throws -> PlaylistMutationAuthorization {
        let authorized = PlaylistMutationAuthorization(accountEpoch: context.accountEpoch, admission: self)
        try authorized.authorizeDispatch()
        return authorized
    }

    fileprivate func allows(accountEpoch: UInt64) -> Bool {
        lock.withLock { isActive && self.accountEpoch == accountEpoch }
    }
}

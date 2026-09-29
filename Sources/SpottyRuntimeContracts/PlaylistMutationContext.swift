import SpottyDomain
import Synchronization

/// The catalog session rendered with an action stays attached to the request. Account identity
/// alone cannot distinguish validation from before a disconnect/reconnect in the same account.
public struct PlaylistMutationContext: Sendable {
    public let session: CatalogSessionSnapshot
    public init(session: CatalogSessionSnapshot) { self.session = session }
}

/// Admission and a rendered session stamp are different capabilities. This value retains the
/// live fence; it must be checked again at every wire attempt after asynchronous preparation.
package struct PlaylistMutationAuthorization: Sendable {
    private let session: CatalogSessionSnapshot
    private let admission: CatalogSessionAdmission

    fileprivate init(session: CatalogSessionSnapshot, admission: CatalogSessionAdmission) {
        self.session = session
        self.admission = admission
    }

    /// Authorization is the dispatch boundary, not a promise that a sent write can be undone.
    package func authorizeDispatch() throws {
        try Task.checkCancellation()
        guard admission.allows(session) else { throw CancellationError() }
    }
}

/// One catalog-session identity for runtime publication and gateway write admission. AccountStore
/// advances it synchronously; workers consult it without waiting for the desktop to observe it.
package final class CatalogSessionAdmission: Sendable {
    private let state: Mutex<CatalogSessionSnapshot>

    package init(accountEpoch: UInt64 = 1) {
        state = Mutex(CatalogSessionSnapshot(accountEpoch: accountEpoch, isAvailable: false))
    }

    package var snapshot: CatalogSessionSnapshot { state.withLock { $0 } }

    package func updateAvailability(accountEpoch: UInt64, isAvailable: Bool) {
        state.withLock { state in
            guard state.accountEpoch == accountEpoch else { return }
            state.update(accountEpoch: accountEpoch, isAvailable: isAvailable)
        }
    }

    package func retire(nextAccountEpoch: UInt64) {
        state.withLock { $0.update(accountEpoch: nextAccountEpoch, isAvailable: false) }
    }

    package func authorize(_ context: PlaylistMutationContext) throws -> PlaylistMutationAuthorization {
        let authorized = PlaylistMutationAuthorization(session: context.session, admission: self)
        try authorized.authorizeDispatch()
        return authorized
    }

    fileprivate func allows(_ session: CatalogSessionSnapshot) -> Bool {
        state.withLock { $0.isAvailable && $0 == session }
    }
}

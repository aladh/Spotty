import SpottyDomain
import SpottyRuntimeContracts
import Foundation
import Observation

/// Account-scoped catalog work captures this value before suspension and revalidates it before
/// every write. A Boolean alone is insufficient because two different accounts can both be ready.
@MainActor
@Observable
final class CatalogSessionAvailability {
    private(set) var snapshot: CatalogSessionSnapshot

    init(accountEpoch: UInt64 = 1, isAvailable: Bool = false) {
        snapshot = CatalogSessionSnapshot(
            accountEpoch: accountEpoch,
            isAvailable: isAvailable
        )
    }

    var isAvailable: Bool { snapshot.isAvailable }
    var accountEpoch: UInt64 { snapshot.accountEpoch }

    func update(accountEpoch: UInt64, isAvailable: Bool) {
        snapshot.update(accountEpoch: accountEpoch, isAvailable: isAvailable)
    }

    /// Desktop observation preserves the runtime's revision, including transitions skipped by
    /// the bounded publication stream. It must not reconstruct lifetime from visible Booleans.
    func apply(_ value: CatalogSessionSnapshot) {
        snapshot = value
    }

    func requestIdentity(requestID: UInt64) -> AccountScopedRequestIdentity {
        AccountScopedRequestIdentity(
            requestID: requestID,
            accountEpoch: snapshot.accountEpoch,
            sessionRevision: snapshot.revision
        )
    }
}

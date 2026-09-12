import SpottyDomain
import SpottyRuntimeContracts
import Foundation

nonisolated struct CatalogSessionSnapshot: Equatable, Sendable {
    let accountEpoch: UInt64
    let isAvailable: Bool
    let revision: UInt64
}

/// Account-scoped catalog work captures this value before suspension and revalidates it before
/// every write. A Boolean alone is insufficient because two different accounts can both be ready.
@MainActor
final class CatalogSessionAvailability {
    private(set) var snapshot: CatalogSessionSnapshot

    init(accountEpoch: UInt64 = 1, isAvailable: Bool = false) {
        snapshot = CatalogSessionSnapshot(
            accountEpoch: accountEpoch,
            isAvailable: isAvailable,
            revision: 0
        )
    }

    var isAvailable: Bool { snapshot.isAvailable }
    var accountEpoch: UInt64 { snapshot.accountEpoch }

    func update(accountEpoch: UInt64, isAvailable: Bool) {
        guard snapshot.accountEpoch != accountEpoch || snapshot.isAvailable != isAvailable else { return }
        snapshot = CatalogSessionSnapshot(
            accountEpoch: accountEpoch,
            isAvailable: isAvailable,
            revision: snapshot.revision &+ 1
        )
    }

    func requestIdentity(requestID: UInt64) -> AccountScopedRequestIdentity {
        AccountScopedRequestIdentity(
            requestID: requestID,
            accountEpoch: snapshot.accountEpoch,
            sessionRevision: snapshot.revision
        )
    }
}

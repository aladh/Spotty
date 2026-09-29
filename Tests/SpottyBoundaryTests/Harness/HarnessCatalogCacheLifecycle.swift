@testable import SpottySessionRuntime

/// Configurable catalog retirement for checks of account and process teardown ordering.
struct HarnessCatalogCacheLifecycle: CatalogCacheLifecycle {
    var onRetire: @Sendable (UInt64, Bool) async -> Bool = { _, _ in true }

    func activate(accountEpoch: UInt64) async {}
    func retire(accountEpoch: UInt64, purge: Bool) async -> Bool { await onRetire(accountEpoch, purge) }
}

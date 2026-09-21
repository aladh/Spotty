@testable import SpottySessionRuntime

/// Configurable catalog retirement for checks of account and process teardown ordering.
struct HarnessCatalogCacheLifecycle: CatalogCacheLifecycle {
    var onRetire: @Sendable (Bool) async -> Bool = { _ in true }

    func activate() async {}
    func retire(purge: Bool) async -> Bool { await onRetire(purge) }
}

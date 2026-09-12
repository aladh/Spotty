import Foundation

/// Bounded presentation snapshots for completed routes. Session freshness is distinct from
/// account ownership: reconnects can retain useful rows, while replacement accounts cannot.
@MainActor
final class RetainedCatalogRoutes<Value> {
    struct Entry {
        var value: Value
        let session: CatalogSessionSnapshot
        let cost: Int
        var needsRefresh = false
    }

    private let session: CatalogSessionAvailability
    private let routeLimit: Int
    private let costLimit: Int
    private var accountEpoch: UInt64
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(session: CatalogSessionAvailability, routeLimit: Int = 20, costLimit: Int = 20_000) {
        self.session = session
        self.routeLimit = max(1, routeLimit)
        self.costLimit = max(1, costLimit)
        accountEpoch = session.accountEpoch
    }

    func reset() {
        entries.removeAll()
        order.removeAll()
        accountEpoch = session.accountEpoch
    }

    func entry(for uri: String) -> Entry? {
        if accountEpoch != session.accountEpoch { reset() }
        guard let entry = entries[uri] else { return nil }
        touch(uri)
        return entry
    }

    func store(_ value: Value, for uri: String, cost: Int, snapshot: CatalogSessionSnapshot) {
        guard snapshot == session.snapshot, snapshot.isAvailable else { return }
        if accountEpoch != snapshot.accountEpoch { reset() }
        guard cost <= costLimit else {
            entries[uri] = nil
            order.removeAll { $0 == uri }
            return
        }
        entries[uri] = Entry(value: value, session: snapshot, cost: max(0, cost))
        touch(uri)
        while entries.count > routeLimit || entries.values.reduce(0, { $0 + $1.cost }) > costLimit {
            entries[order.removeFirst()] = nil
        }
    }

    func markStale(_ uri: String) {
        entries[uri]?.needsRefresh = true
    }

    var values: [Value] {
        if accountEpoch != session.accountEpoch { reset() }
        return entries.values.map(\.value)
    }

    /// Metadata-only transformations preserve retention order, cost, and the original freshness
    /// evidence. They cannot turn a failed refresh or a retired account into current content.
    func updateValues(_ update: (Value) -> Value) {
        guard accountEpoch == session.accountEpoch else {
            reset()
            return
        }
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            entry.value = update(entry.value)
            entries[key] = entry
        }
    }

    func remove(_ uri: String) {
        entries[uri] = nil
        order.removeAll { $0 == uri }
    }

    private func touch(_ uri: String) {
        order.removeAll { $0 == uri }
        order.append(uri)
    }
}

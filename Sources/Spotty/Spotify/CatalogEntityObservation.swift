import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// One bounded entity query for the current and retained routes of a feature store. It uses the
/// same strict account/session gate as catalog reads; a query never supplies collection authority.
@MainActor
final class CatalogEntityObservation {
    private typealias Flight = AccountScopedSingleFlight<SingleFlightUnitKey>
    private let provider: (any CatalogEntityQueryProviding)?
    private let session: CatalogSessionAvailability
    private let flight: Flight
    private var requestedURIs: Set<String> = []
    private var observedSession: CatalogSessionSnapshot?
    private var subscriptionTask: Task<Void, Never>?

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
        self.provider = provider as? any CatalogEntityQueryProviding
        self.session = session
        flight = Flight(session: session, join: .alwaysSupersede, scope: .singleSelection, publish: .strict)
    }

    deinit { subscriptionTask?.cancel() }

    func reset() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flight.reset()
        requestedURIs = []
        observedSession = nil
    }

    func update(
        uris: Set<String>, apply: @escaping @MainActor ([String: CatalogTrack]) -> Void
    ) {
        guard let provider, session.isAvailable, !uris.isEmpty else {
            reset()
            return
        }
        let bounded = Set(uris.sorted().prefix(CatalogEntityQueryLimits.maximumRequestedURIs))
        guard bounded != requestedURIs || observedSession != session.snapshot else { return }
        reset()
        requestedURIs = bounded
        observedSession = session.snapshot
        let flight = flight
        let handle = flight.begin(.unit)
        subscriptionTask = Task { [weak self] in
            await flight.run(handle) {
                await Self.consume(provider, uris: bounded, flight: flight, handle: handle, apply: apply)
            }
            self?.finish(handle)
        }
    }

    private func finish(_ handle: Flight.Handle) {
        guard flight.owns(handle) else { return }
        requestedURIs = []
        observedSession = nil
        subscriptionTask = nil
    }

    private static func consume(
        _ provider: any CatalogEntityQueryProviding, uris: Set<String>, flight: Flight, handle: Flight.Handle,
        apply: @escaping @MainActor ([String: CatalogTrack]) -> Void
    ) async {
        guard let subscription = try? await provider.subscribeCatalogEntities(uris) else { return }
        if flight.isCurrent(handle) {
            var appliedRevision: UInt64?
            for await change in subscription.updates {
                guard flight.isCurrent(handle) else { break }
                guard change.token == subscription.token,
                    appliedRevision.map({ change.revision > $0 }) ?? true
                else { continue }
                // A superseded read receives another accumulated change. Other failures retire
                // this query so a later route load can retry instead of retaining a stuck stream.
                let entities: [String: CatalogTrack]
                do {
                    entities = try await read(change, provider: provider, uris: uris, flight: flight, handle: handle)
                } catch CatalogEntityQueryFailure.superseded {
                    continue
                } catch {
                    break
                }
                guard flight.isCurrent(handle) else { break }
                apply(entities)
                appliedRevision = change.revision
                await provider.acknowledgeCatalogEntities(subscription.token, revision: change.revision)
                guard flight.isCurrent(handle) else { break }
            }
        }
        await provider.unsubscribeCatalogEntities(subscription.token)
    }

    private static func read(
        _ change: CatalogEntityChange, provider: any CatalogEntityQueryProviding, uris: Set<String>,
        flight: Flight, handle: Flight.Handle
    ) async throws -> [String: CatalogTrack] {
        guard change.totalCount >= 0, change.totalCount <= uris.count else { throw InvalidPublication.bounds }
        var offset = 0
        var entities: [String: CatalogTrack] = [:]
        while offset < change.totalCount {
            let page = try await provider.catalogEntityPage(
                change.token, revision: change.revision, offset: offset, limit: CatalogEntityQueryLimits.pageSize)
            guard flight.isCurrent(handle) else { throw CancellationError() }
            guard page.token == change.token, page.revision == change.revision,
                page.offset == offset, page.totalCount == change.totalCount,
                page.nextOffset > offset,
                page.nextOffset <= min(offset + CatalogEntityQueryLimits.pageSize, change.totalCount),
                page.tracks.count <= page.nextOffset - offset,
                page.tracks.allSatisfy({ uris.contains($0.key) && $0.value.uri == $0.key && entities[$0.key] == nil })
            else { throw InvalidPublication.bounds }
            entities.merge(page.tracks) { _, latest in latest }
            offset = page.nextOffset
        }
        return entities
    }

    private enum InvalidPublication: Error { case bounds }
}

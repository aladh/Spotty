import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Scripted entity publications. Storage invalidation/coalescing is tested by the storage/runtime
/// suites; this harness lets presentation checks stop a page at a precise suspension boundary.
actor HarnessCatalogQueries: CatalogEntityQueryProviding {
    private struct Query {
        let uris: Set<String>
        let continuation: AsyncStream<CatalogEntityChange>.Continuation
    }

    private struct Publication {
        let ordered: [CatalogTrack]
    }

    private let lifetime = UUID()
    private var queries: [CatalogEntitySubscriptionToken: Query] = [:]
    private var publications: [CatalogEntitySubscriptionToken: [UInt64: Publication]] = [:]
    private var entities: [String: CatalogTrack] = [:]
    private var revision: UInt64 = 0
    private var failuresRemaining = 0
    private var pageFailuresRemaining = 0
    private(set) var failedPageCount = 0
    private(set) var subscriptionAttemptCount = 0
    private var heldOffset: Int?
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var acknowledgementCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var subscriptionCount = 0
    var parkedPageCount: Int { parked.count }
    var activeQueryCount: Int { queries.count }

    func failNextSubscription() { failuresRemaining += 1 }

    func finishStreams() {
        for query in queries.values { query.continuation.finish() }
    }

    func failNextPage() { pageFailuresRemaining += 1 }

    func holdPage(at offset: Int) { heldOffset = offset }

    func releasePages() {
        heldOffset = nil
        let continuations = parked
        parked = []
        for continuation in continuations { continuation.resume() }
    }

    func publish(_ changed: [CatalogTrack]) {
        for track in changed { entities[track.uri] = track }
        revision &+= 1
        for (token, query) in queries {
            emit(changed.filter { query.uris.contains($0.uri) }, token: token, query: query)
        }
    }

    func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        subscriptionAttemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CatalogEntityQueryFailure.unavailable
        }
        let token = CatalogEntitySubscriptionToken(accountLifetime: lifetime)
        let (stream, continuation) = AsyncStream<CatalogEntityChange>.makeStream()
        let query = Query(uris: uris, continuation: continuation)
        queries[token] = query
        subscriptionCount += 1
        let initial = uris.compactMap { entities[$0] }
        if !initial.isEmpty { emit(initial, token: token, query: query) }
        return CatalogEntitySubscription(token: token, updates: stream)
    }

    func catalogEntityPage(
        _ token: CatalogEntitySubscriptionToken, revision: UInt64, offset: Int, limit: Int
    ) async throws -> CatalogEntityPage {
        if pageFailuresRemaining > 0 {
            pageFailuresRemaining -= 1
            failedPageCount += 1
            throw CatalogEntityQueryFailure.unavailable
        }
        guard let publication = publications[token]?[revision] else { throw CatalogEntityQueryFailure.superseded }
        let end = min(offset + limit, publication.ordered.count)
        let rows = publication.ordered[offset..<end]
        let page = CatalogEntityPage(
            token: token, revision: revision, offset: offset, totalCount: publication.ordered.count,
            nextOffset: end, tracks: Dictionary(uniqueKeysWithValues: rows.map { ($0.uri, $0) }))
        if heldOffset == offset {
            // Deliberately uncooperative so lifetime checks must reject a late completed page.
            await withCheckedContinuation { parked.append($0) }
        }
        return page
    }

    func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async {
        acknowledgementCount += 1
        publications[token]?[revision] = nil
    }

    func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async {
        unsubscribeCount += 1
        queries.removeValue(forKey: token)?.continuation.finish()
        publications[token] = nil
    }

    private func emit(_ tracks: [CatalogTrack], token: CatalogEntitySubscriptionToken, query: Query) {
        guard !tracks.isEmpty else { return }
        publications[token, default: [:]][revision] = Publication(ordered: tracks.sorted { $0.uri < $1.uri })
        query.continuation.yield(CatalogEntityChange(token: token, revision: revision, totalCount: tracks.count))
    }
}

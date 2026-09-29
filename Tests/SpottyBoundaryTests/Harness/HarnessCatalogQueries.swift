import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport

/// Scripted entity publications. Storage invalidation/coalescing is tested by the storage/runtime
/// suites; this harness lets presentation checks stop a complete read at a precise suspension boundary.
actor HarnessCatalogQueries: CatalogEntityQueryProviding {
    private struct Query {
        let uris: Set<String>
        let continuation: AsyncStream<CatalogEntityChange>.Continuation
    }

    private let lifetime = UUID()
    private var queries: [CatalogEntitySubscriptionToken: Query] = [:]
    private var publications: [CatalogEntitySubscriptionToken: [UInt64: [String: CatalogTrackMetadata]]] = [:]
    private var entities: [String: CatalogTrackMetadata] = [:]
    private var revision: UInt64 = 0
    private var failuresRemaining = 0
    private var readFailuresRemaining = 0
    private(set) var failedReadCount = 0
    private(set) var subscriptionAttemptCount = 0
    private var nextReadCompletion: HarnessResponseGate<Void>?
    private(set) var acknowledgementCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var subscriptionCount = 0
    private(set) var peakQueryCount = 0
    private var nextSubscriptionCompletion: HarnessResponseGate<Void>?
    var activeQueryCount: Int { queries.count }
    var activeRequestedURIs: Set<String> {
        queries.values.reduce(into: Set<String>()) { $0.formUnion($1.uris) }
    }

    func failNextSubscription() { failuresRemaining += 1 }

    func finishStreams() {
        for query in queries.values { query.continuation.finish() }
    }

    func failNextRead() { readFailuresRemaining += 1 }

    func delayNextRead(until completion: HarnessResponseGate<Void>) { nextReadCompletion = completion }
    func delayNextSubscription(until completion: HarnessResponseGate<Void>) { nextSubscriptionCompletion = completion }

    func publish(_ changed: [CatalogTrack]) {
        let metadata = changed.map { CatalogTrackMetadata(track: $0, requestedURI: $0.uri) }
        for track in metadata { entities[track.uri] = track }
        revision &+= 1
        for (token, query) in queries {
            emit(metadata.filter { query.uris.contains($0.uri) }, token: token, query: query)
        }
    }

    func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        subscriptionAttemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CatalogEntityQueryFailure.unavailable
        }
        if let completion = nextSubscriptionCompletion {
            nextSubscriptionCompletion = nil
            try await completion.wait()
        }
        guard queries.count < CatalogEntityQueryLimits.maximumSubscriptions else {
            throw CatalogEntityQueryFailure.capacity
        }
        let token = CatalogEntitySubscriptionToken(accountLifetime: lifetime)
        let (stream, continuation) = AsyncStream<CatalogEntityChange>.makeStream()
        let query = Query(uris: uris, continuation: continuation)
        queries[token] = query
        peakQueryCount = max(peakQueryCount, queries.count)
        subscriptionCount += 1
        let initial = uris.compactMap { entities[$0] }
        if !initial.isEmpty { emit(initial, token: token, query: query) }
        return CatalogEntitySubscription(token: token, updates: stream)
    }

    func catalogEntities(for change: CatalogEntityChange) async throws -> [String: CatalogTrackMetadata] {
        if readFailuresRemaining > 0 {
            readFailuresRemaining -= 1
            failedReadCount += 1
            throw CatalogEntityQueryFailure.unavailable
        }
        guard let entities = publications[change.token]?[change.revision] else {
            throw CatalogEntityQueryFailure.superseded
        }
        if let completion = nextReadCompletion {
            nextReadCompletion = nil
            try await completion.wait()
        }
        return entities
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

    private func emit(_ tracks: [CatalogTrackMetadata], token: CatalogEntitySubscriptionToken, query: Query) {
        guard !tracks.isEmpty else { return }
        publications[token, default: [:]][revision] = Dictionary(uniqueKeysWithValues: tracks.map { ($0.uri, $0) })
        query.continuation.yield(CatalogEntityChange(token: token, revision: revision))
    }
}

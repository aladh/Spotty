import Foundation
import SpottyRuntimeContracts

/// Synchronous observation state confined to the catalog provider's actor. Account admission,
/// cache availability, and write serialization remain with the provider; this value owns the
/// dirty-set, acknowledgement, and retry protocol without exposing its registrations.
struct CatalogEntityObservations: Sendable {
    enum ReadConsistency {
        case stable
        case writesPending
        case crossedWrite
    }

    private struct Observation: Sendable {
        let token: CatalogEntitySubscriptionToken
        let requestedURIs: Set<String>
        let continuation: AsyncStream<CatalogEntityChange>.Continuation
        var pendingURIs: Set<String>
        var revision: UInt64 = 0
        var retryAfterWrite = false

        var change: CatalogEntityChange { CatalogEntityChange(token: token, revision: revision) }

        mutating func committed(_ changedURIs: Set<String>) {
            let relevant = changedURIs.intersection(requestedURIs)
            guard !relevant.isEmpty else { return }
            pendingURIs.formUnion(relevant)
            revision &+= 1
            continuation.yield(change)
        }

        mutating func writesDrained() {
            guard retryAfterWrite else { return }
            retryAfterWrite = false
            continuation.yield(change)
        }
    }

    private var observations: [UUID: Observation] = [:]

    mutating func subscribe(
        _ uris: Set<String>, accountLifetime: UUID,
        onTermination: @escaping @Sendable (CatalogEntitySubscriptionToken) -> Void
    ) throws -> CatalogEntitySubscription {
        guard uris.count <= CatalogEntityQueryLimits.maximumRequestedURIs,
            uris.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 && !$0.contains("\0") })
        else { throw CatalogEntityQueryFailure.invalidRequest }
        guard observations.count < CatalogEntityQueryLimits.maximumSubscriptions else {
            throw CatalogEntityQueryFailure.capacity
        }
        let token = CatalogEntitySubscriptionToken(accountLifetime: accountLifetime)
        let (stream, continuation) = AsyncStream.makeStream(
            of: CatalogEntityChange.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { _ in onTermination(token) }
        let observation = Observation(
            token: token, requestedURIs: uris, continuation: continuation, pendingURIs: uris)
        observations[token.id] = observation
        continuation.yield(observation.change)
        return CatalogEntitySubscription(token: token, updates: stream)
    }

    /// Validate the subscription revision before arranging a write retry: a newer relevant
    /// invalidation already supplied its own replacement event. Call after every storage await.
    mutating func pendingURIs(
        for change: CatalogEntityChange, consistency: ReadConsistency
    ) throws -> Set<String> {
        guard let observation = observations[change.token.id], observation.token == change.token else {
            throw CatalogEntityQueryFailure.retired
        }
        guard observation.revision == change.revision else { throw CatalogEntityQueryFailure.superseded }
        switch consistency {
        case .stable:
            return observation.pendingURIs
        case .writesPending:
            observations[change.token.id]?.retryAfterWrite = true
        case .crossedWrite:
            observation.continuation.yield(observation.change)
        }
        throw CatalogEntityQueryFailure.superseded
    }

    mutating func acknowledge(_ token: CatalogEntitySubscriptionToken, revision: UInt64) {
        guard let observation = observations[token.id], observation.token == token, observation.revision == revision
        else { return }
        observations[token.id]?.pendingURIs.removeAll(keepingCapacity: false)
    }

    mutating func unsubscribe(_ token: CatalogEntitySubscriptionToken) {
        guard observations[token.id]?.token == token else { return }
        let observation = observations.removeValue(forKey: token.id)
        observation?.continuation.finish()
    }

    mutating func committed(changedURIs: Set<String>) {
        guard !changedURIs.isEmpty else { return }
        for id in Array(observations.keys) {
            // Mutate the dictionary entry in place. Copying an observation first would retain
            // its pending Set and force a full copy on every small unacknowledged change.
            observations[id]?.committed(changedURIs)
        }
    }

    /// Called only after the provider's final active or queued write has settled.
    mutating func writesDrained() {
        for id in Array(observations.keys) { observations[id]?.writesDrained() }
    }

    /// Finish existing registrations. Future subscriptions still require provider admission;
    /// there is deliberately no second account-active flag here.
    mutating func finishAll() {
        let retired = observations.values
        observations.removeAll(keepingCapacity: false)
        for observation in retired { observation.continuation.finish() }
    }
}

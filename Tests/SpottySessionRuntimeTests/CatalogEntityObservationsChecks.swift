import Foundation
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@MainActor
private final class EntityObservationFixture {
    var observations = CatalogEntityObservations()
    let subscription: CatalogEntitySubscription
    let changes = RuntimeCallbackRecorder<CatalogEntityChange>()
    let finished = RuntimeCallbackRecorder<Bool>()
    private let reader: Task<Void, Never>

    init() throws {
        subscription = try observations.subscribe(["a", "b"], accountLifetime: UUID(), onTermination: { _ in })
        let updates = subscription.updates
        reader = Task { [changes, finished] in
            for await change in updates { changes.append(change) }
            finished.append(true)
        }
    }

    func update(after count: Int) async throws -> CatalogEntityChange {
        try await requireEventually(description: "Entity invalidation \(count + 1)") { changes.snapshot.count > count }
        return try #require(changes.snapshot.last)
    }

    func cleanUp() async {
        observations.finishAll()
        reader.cancel()
        await reader.value
    }
}

@MainActor
private func withEntityObservation(_ body: (EntityObservationFixture) async throws -> Void) async throws {
    let fixture = try EntityObservationFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

@Suite("Catalog entity observation protocol")
@MainActor
struct CatalogEntityObservationsChecks {
    @Test
    func overlappingReadsRetryTheSameRevisionWhenWritesDrain() async throws {
        try await withEntityObservation { fixture in
            let initial = try await fixture.update(after: 0)
            for _ in 0..<3 {
                #expect(throws: CatalogEntityQueryFailure.superseded) {
                    try fixture.observations.pendingURIs(for: initial, consistency: .writesPending)
                }
            }
            fixture.observations.writesDrained()
            let retry = try await fixture.update(after: 1)
            #expect(retry == initial, "Unrelated or no-op writes still retry without inventing an entity change")
            #expect(try fixture.observations.pendingURIs(for: retry, consistency: .stable) == ["a", "b"])
        }
    }

    @Test
    func aWriteCrossingACompleteReadRepublishesItsCurrentRevision() async throws {
        try await withEntityObservation { fixture in
            let initial = try await fixture.update(after: 0)
            fixture.observations.acknowledge(initial.token, revision: initial.revision)
            #expect(throws: CatalogEntityQueryFailure.superseded) {
                try fixture.observations.pendingURIs(for: initial, consistency: .crossedWrite)
            }
            let retry = try await fixture.update(after: 1)
            #expect(retry == initial)
            #expect(try fixture.observations.pendingURIs(for: retry, consistency: .stable).isEmpty)
        }
    }

    @Test
    func relevantChangesAndOldAcknowledgementsPreserveTheDeferredRetry() async throws {
        try await withEntityObservation { fixture in
            let initial = try await fixture.update(after: 0)
            fixture.observations.acknowledge(initial.token, revision: initial.revision)
            #expect(throws: CatalogEntityQueryFailure.superseded) {
                try fixture.observations.pendingURIs(for: initial, consistency: .writesPending)
            }
            fixture.observations.committed(changedURIs: ["a", "unrelated"])
            let changed = try await fixture.update(after: 1)
            #expect(changed.revision == initial.revision + 1)
            fixture.observations.acknowledge(initial.token, revision: initial.revision)
            #expect(throws: CatalogEntityQueryFailure.superseded) {
                try fixture.observations.pendingURIs(for: initial, consistency: .writesPending)
            }
            fixture.observations.writesDrained()
            let retry = try await fixture.update(after: 2)
            #expect(retry == changed, "The final write retries the newest observation, never the captured old revision")
            #expect(try fixture.observations.pendingURIs(for: retry, consistency: .stable) == ["a"])
            fixture.observations.acknowledge(retry.token, revision: retry.revision)
            #expect(try fixture.observations.pendingURIs(for: retry, consistency: .stable).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func retiringAnObservationDiscardsItsWriteRetry(unsubscribe: Bool) async throws {
        try await withEntityObservation { fixture in
            let initial = try await fixture.update(after: 0)
            #expect(throws: CatalogEntityQueryFailure.superseded) {
                try fixture.observations.pendingURIs(for: initial, consistency: .writesPending)
            }
            if unsubscribe {
                fixture.observations.unsubscribe(initial.token)
            } else {
                fixture.observations.finishAll()
            }
            try await requireEventually { fixture.finished.snapshot == [true] }
            let replacement = try fixture.observations.subscribe(["replacement"], accountLifetime: UUID()) { _ in }
            fixture.observations.writesDrained()
            fixture.observations.acknowledge(initial.token, revision: initial.revision)
            fixture.observations.unsubscribe(initial.token)
            #expect(throws: CatalogEntityQueryFailure.retired) {
                try fixture.observations.pendingURIs(for: initial, consistency: .stable)
            }
            let current = CatalogEntityChange(token: replacement.token, revision: 0)
            #expect(try fixture.observations.pendingURIs(for: current, consistency: .stable) == ["replacement"])
            #expect(fixture.changes.snapshot == [initial])
        }
    }

    @Test
    func matchingIDFromAnotherAccountCannotAcknowledgeOrRemoveAnObservation() async throws {
        try await withEntityObservation { fixture in
            let initial = try await fixture.update(after: 0)
            let forged = CatalogEntitySubscriptionToken(id: initial.token.id, accountLifetime: UUID())
            fixture.observations.acknowledge(forged, revision: initial.revision)
            fixture.observations.unsubscribe(forged)
            #expect(throws: CatalogEntityQueryFailure.retired) {
                try fixture.observations.pendingURIs(
                    for: CatalogEntityChange(token: forged, revision: initial.revision), consistency: .stable)
            }
            #expect(try fixture.observations.pendingURIs(for: initial, consistency: .stable) == ["a", "b"])
        }
    }
}

@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore

@Suite("Catalog entity registration lifetime")
@MainActor
struct CatalogEntityLifetimeTests {
    @Test
    func replacementRetiresItsTokenWithoutWaitingForAnIgnoredRead() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        let observer = CatalogEntityObservation(provider: provider, session: session)
        defer { observer.reset() }
        var titles: [String] = []
        observer.update(collections: [collection("spotify:track:old")]) { titles += $0.values.map(\.title) }
        try await requireEventually { await queries.activeQueryCount == 1 }
        let read = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { read.close() }
        await queries.delayNextRead(until: read)
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:old", title: "Old")])
        try await requireEventually { read.waiterCount == 1 }

        observer.update(collections: [collection("spotify:track:new")]) { titles += $0.values.map(\.title) }
        try await requireEventually { await queries.activeRequestedURIs == ["spotify:track:new"] }
        #expect(await queries.activeQueryCount == 1)
        #expect(await queries.peakQueryCount == 1)
        #expect(read.waiterCount == 1)
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:new", title: "New")])
        try await requireEventually { titles == ["New"] }
        read.finish(())
        observer.reset()
        try await requireEventually { await queries.activeQueryCount == 0 }
        #expect(titles == ["New"])
    }

    @Test
    func pendingRegistrationCoalescesMembershipAndRetiresTheLateToken() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        let observer = CatalogEntityObservation(provider: provider, session: session)
        defer { observer.reset() }
        let registration = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { registration.close() }
        await queries.delayNextSubscription(until: registration)
        observer.update(collections: [collection("spotify:track:old")]) { _ in }
        try await requireEventually { registration.waiterCount == 1 }
        for index in 0..<12 { observer.update(collections: [collection("spotify:track:\(index)")]) { _ in } }
        registration.finish(())

        try await requireEventually { await queries.activeRequestedURIs == ["spotify:track:11"] }
        #expect(await queries.subscriptionAttemptCount == 2)
        #expect(await queries.unsubscribeCount == 1)
        #expect(await queries.peakQueryCount == 1)
    }

    @Test
    func disposalRetiresARegisteredTokenWhileItsReadIgnoresCancellation() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        var observer: CatalogEntityObservation? = CatalogEntityObservation(provider: provider, session: session)
        weak let released = observer
        let read = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { read.close() }
        var applied = false
        observer?.update(collections: [collection("spotify:track:old")]) { _ in applied = true }
        try await requireEventually { await queries.activeQueryCount == 1 }
        await queries.delayNextRead(until: read)
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:old")])
        try await requireEventually { read.waiterCount == 1 }
        observer = nil

        #expect(released == nil)
        try await requireEventually { await queries.activeQueryCount == 0 }
        #expect(read.waiterCount == 1)
        #expect(applied == false)
    }

    @Test
    func disposalRetiresALateRegistrationWithoutKeepingTheOwnerAlive() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        var observer: CatalogEntityObservation? = CatalogEntityObservation(provider: provider, session: session)
        weak let released = observer
        let registration = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { registration.close() }
        await queries.delayNextSubscription(until: registration)
        var applied = false
        observer?.update(collections: [collection("spotify:track:old")]) { _ in applied = true }
        try await requireEventually { registration.waiterCount == 1 }
        observer = nil
        #expect(released == nil)

        registration.finish(())
        try await requireEventually { await queries.unsubscribeCount == 1 }
        #expect(await queries.activeQueryCount == 0)
        #expect(applied == false)
    }
    private func collection(_ uri: String) -> CatalogTrackCollection {
        CatalogTrackCollection(tracks: [HarnessFixtures.track(uri: uri)])
    }
}

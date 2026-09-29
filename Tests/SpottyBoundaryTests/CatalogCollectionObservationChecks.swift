@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore

@Suite("Catalog collection membership")
@MainActor
struct CatalogCollectionObservationTests {
    @Test
    func metadataVersionsAndDuplicateCopiesKeepAnOutstandingReadCurrent() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        let observer = CatalogEntityObservation(provider: provider, session: session)
        defer { observer.reset() }
        let original = collection(["spotify:track:shared", "spotify:track:first"])
        let other = collection(["spotify:track:shared", "spotify:track:second"])
        var titles: [String] = []
        observer.update(collections: [original, other, original]) { titles += $0.values.map(\.title) }
        try await requireEventually { await queries.activeRequestedURIs.count == 3 }
        let read = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { read.close() }
        await queries.delayNextRead(until: read)
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:shared", title: "Pending")])
        try await requireEventually { read.waiterCount == 1 }

        let entity = CatalogTrackMetadata(
            track: HarnessFixtures.track(uri: "spotify:track:shared", title: "Enriched"),
            requestedURI: "spotify:track:shared")
        let enriched = try #require(original.applyingMetadata([entity.uri: entity]))
        #expect(enriched.version != original.version)
        observer.update(collections: [other, enriched, enriched]) { titles += $0.values.map(\.title) }
        read.finish(())
        try await requireEventually { titles == ["Pending"] && read.waiterCount == 0 }
        try await requireEventually { await queries.acknowledgementCount == 1 }
        #expect(await queries.subscriptionCount == 1)
        #expect(await queries.unsubscribeCount == 0)
    }

    @Test
    func identicalCollectionsStillReplaceAdmissionAfterAHiddenSessionTransition() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let observer = CatalogEntityObservation(provider: provider, session: session)
        defer { observer.reset() }
        let rows = collection(["spotify:track:shared"])
        var retiredApplied = false
        observer.update(collections: [rows]) { _ in retiredApplied = true }
        try await requireEventually { await queries.activeQueryCount == 1 }
        let read = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { read.close() }
        await queries.delayNextRead(until: read)
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:shared", title: "Old read")])
        try await requireEventually { read.waiterCount == 1 }

        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        var currentTitles: [String] = []
        observer.update(collections: [rows, rows]) { currentTitles += $0.values.map(\.title) }
        try await requireEventually { await queries.subscriptionCount == 2 }
        #expect(await queries.unsubscribeCount == 1)
        #expect(await queries.peakQueryCount == 1)
        read.finish(())
        await queries.publish([HarnessFixtures.track(uri: "spotify:track:shared", title: "Current")])
        try await requireEventually { currentTitles.contains("Current") }
        #expect(retiredApplied == false)

        session.update(accountEpoch: 1, isAvailable: false)
        observer.update(collections: [rows]) { _ in retiredApplied = true }
        try await requireEventually { await queries.activeQueryCount == 0 }
        #expect(retiredApplied == false)
    }

    @Test
    func boundedUnionIsIndependentOfInputOrderAndEvictionAdmitsPreviouslyClippedRows() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let session = CatalogSessionAvailability(isAvailable: true)
        let observer = CatalogEntityObservation(provider: provider, session: session)
        defer { observer.reset() }
        let count = CatalogEntityQueryLimits.maximumRequestedURIs / 2 + 1
        let firstURIs = (0..<count).map { "spotify:track:a-\($0)" }
        let secondURIs = (0..<count).map { "spotify:track:b-\($0)" }
        let first = collection(firstURIs)
        let second = collection(secondURIs)
        let bounded = Set((firstURIs + secondURIs).sorted().prefix(CatalogEntityQueryLimits.maximumRequestedURIs))
        observer.update(collections: [second, first, second]) { _ in }
        try await requireEventually { await queries.activeRequestedURIs == bounded }

        observer.reset()
        observer.update(collections: [first, second]) { _ in }
        try await requireEventually { await queries.subscriptionCount == 2 }
        #expect(await queries.activeRequestedURIs == bounded)
        observer.update(collections: [second]) { _ in }
        try await requireEventually { await queries.activeRequestedURIs == Set(secondURIs) }
        #expect(await queries.subscriptionCount == 3)
        #expect(await queries.peakQueryCount == 1)

        observer.update(collections: []) { _ in }
        try await requireEventually { await queries.activeQueryCount == 0 }
    }

    private func collection(_ uris: [String]) -> CatalogTrackCollection {
        CatalogTrackCollection(tracks: uris.map { HarnessFixtures.track(uri: $0) })
    }
}

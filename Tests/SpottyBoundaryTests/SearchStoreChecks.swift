import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

/// Gates `HarnessCatalog.searchTracks` so a check can park and release admitted queries one at a
/// time, mirroring the pre-harness `GatedSearchCatalog` actor.
private actor SearchGate {
    enum Outcome: Sendable {
        case tracks([PathfinderTrack])
        case failure
        case cancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var trackQueries: [String] = []

    var requestCount: Int { trackQueries.count }

    func searchTracks(_ term: String) async throws -> [PathfinderTrack] {
        trackQueries.append(term)
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .tracks(items):
            return items
        case .failure:
            throw HarnessFailure.unavailable
        case .cancelled:
            throw CancellationError()
        }
    }

    func completeNext(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: outcome)
    }
}

private func makeGatedSearchCatalog() -> (catalog: HarnessCatalog, gate: SearchGate) {
    let gate = SearchGate()
    let catalog = HarnessCatalog()
    catalog.onSearchTracks = { [gate] term, _ in try await gate.searchTracks(term) }
    return (catalog, gate)
}

private func decodeTrack(_ json: String) throws -> PathfinderTrack {
    try JSONDecoder().decode(PathfinderTrack.self, from: Data(json.utf8))
}

private let firstTrackJSON = """
    {"uri":"spotify:track:first","name":"First Track","albumOfTrack":{"name":"First Album"},"artists":{"items":[{"profile":{"name":"First Artist"}}]},"duration":{"totalMilliseconds":1000}}
    """
private let secondTrackJSON = """
    {"uri":"spotify:track:second","name":"Second Track","albumOfTrack":{"name":"Second Album"},"artists":{"items":[{"profile":{"name":"Second Artist"}}]},"duration":{"totalMilliseconds":2000}}
    """

@MainActor
private func makeStore(
    provider: HarnessCatalog,
    session: CatalogSessionAvailability,
    clock: any PlaybackClock
) -> SearchStore {
    let metadata = CatalogMetadataRepository(
        attributesProvider: HarnessTrackAttributes(),
        session: session
    )
    return SearchStore(provider: provider, metadata: metadata, session: session, clock: clock)
}

@MainActor
private func commitImmediateSearch(
    _ store: SearchStore,
    gate: SearchGate,
    query: String,
    tracks: [PathfinderTrack]
) async -> Bool {
    let task = Task { await store.search(query) }
    guard await waitUntil({ await gate.requestCount == 1 }) else { return false }
    await gate.completeNext(.tracks(tracks))
    await task.value
    return true
}

@Suite("Search Store")
struct SearchStoreTests {
    @Test
    @MainActor
    func testSearchStore() async {
        let first: PathfinderTrack
        let second: PathfinderTrack
        do {
            first = try decodeTrack(firstTrackJSON)
            second = try decodeTrack(secondTrackJSON)
        } catch {
            #expect((false) == true, "synthetic search fixtures decode")
            return
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            #expect(
                (await commitImmediateSearch(store, gate: gate, query: "alpha", tracks: [first])) == true,
                "seeded results commit immediately")
            #expect(
                (store.tracks.map(\.uri))
                    == ([
                        "spotify:track:first"
                    ]), "committed tracks stay visible before a later query is admitted")
            #expect((!store.isSearching) == true, "seeded search is not left searching")

            let pending = Task { await store.scheduleSearch("beta") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "the debounce clock parks before admission")
            #expect(
                (clock.requestedSleeps) == ([SearchStore.queryAdmissionDelay]),
                "debounce asks for the catalog admission delay")
            #expect((!store.isSearching) == true, "debounce does not publish isSearching before admission")
            #expect((await gate.requestCount) == (1), "debounce does not start a catalog fetch before admission")
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]),
                "committed results survive a query that has not been admitted")

            pending.cancel()
            await pending.value
            #expect((await gate.requestCount) == (1), "cancelled debounce never starts a fetch")
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]), "cancelled debounce leaves committed results")
            #expect((!store.isSearching) == true, "cancelled debounce does not publish isSearching")
            #expect((clock.waiterCount) == (0), "cancelled debounce leaves no clock waiter")
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            let pending = Task { await store.scheduleSearch("  beta  ") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "admission waits on the injected clock")
            #expect((await gate.requestCount == 0) == true, "exact admission has not fetched yet")
            #expect((!store.isSearching) == true, "exact admission has not published isSearching yet")

            clock.releaseAll()
            #expect(
                (await waitUntil { await gate.trackQueries == ["beta"] }) == true,
                "exact admission starts the trimmed query")
            #expect((store.isSearching) == true, "admitted search publishes isSearching")
            await gate.completeNext(.tracks([second]))
            await pending.value
            #expect(
                (store.tracks.map(\.uri))
                    == ([
                        "spotify:track:second"
                    ]), "admitted search publishes the current query")
            #expect((!store.isSearching) == true, "admitted search clears isSearching")
            #expect((clock.waiterCount) == (0), "admitted search leaves no clock waiter")
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            let firstQuery = Task { await store.scheduleSearch("alpha") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "the first query parks on the clock")
            let secondQuery = Task { await store.scheduleSearch("beta") }
            #expect(
                (await waitUntil { clock.waiterCount == 1 && clock.requestedSleeps.count == 2 }) == true,
                "the newer query replaces the parked timer")
            await firstQuery.value
            #expect((await gate.requestCount) == (0), "the superseded timer never fetched")

            clock.releaseAll()
            #expect(
                (await waitUntil { await gate.trackQueries == ["beta"] }) == true,
                "only the latest query is admitted")
            await gate.completeNext(.tracks([second]))
            await secondQuery.value
            #expect(
                (store.tracks.map(\.uri))
                    == ([
                        "spotify:track:second"
                    ]), "supersession publishes the latest query")
            #expect((await gate.requestCount) == (1), "supersession fetches once")
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            #expect(
                (await commitImmediateSearch(store, gate: gate, query: "alpha", tracks: [first])) == true,
                "reset fixture commits")

            let resetPending = Task { await store.scheduleSearch("beta") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "reset parks the later query")
            store.reset()
            #expect((store.isEmpty) == true, "reset clears committed results immediately")
            clock.releaseAll()
            await resetPending.value
            #expect((await gate.requestCount) == (1), "reset prevents the parked timer from fetching")
            #expect((store.isEmpty) == true, "reset leaves the store empty")

            let disconnectPending = Task { await store.scheduleSearch("gamma") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "disconnect parks before session change")
            session.update(accountEpoch: 1, isAvailable: false)
            clock.releaseAll()
            await disconnectPending.value
            #expect((await gate.requestCount) == (1), "a session change refuses the parked timer")
            #expect((!store.isSearching) == true, "a refused timer does not publish isSearching")

            session.update(accountEpoch: 2, isAvailable: true)
            let stale = Task { await store.search("delta") }
            #expect((await waitUntil { await gate.requestCount == 2 }) == true, "stale identity parks the fetch")
            session.update(accountEpoch: 3, isAvailable: true)
            await gate.completeNext(.tracks([second]))
            await stale.value
            #expect((store.isEmpty) == true, "a stale success does not publish")
            #expect((!store.isSearching) == true, "a stale success is not left searching")
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            let scheduled = Task { await store.scheduleSearch("retry") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "retry parks the view-driven timer")

            let retry = Task { await store.search("retry") }
            #expect(
                (await waitUntil { await gate.trackQueries == ["retry"] }) == true,
                "Try Again fetches without waiting for the clock")
            #expect(
                (clock.requestedSleeps)
                    == ([
                        SearchStore.queryAdmissionDelay
                    ]), "immediate retry uses one sleep from the cancelled timer")
            await gate.completeNext(.tracks([first]))
            await retry.value
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "immediate retry publishes")

            clock.releaseAll()
            await scheduled.value
            #expect((await gate.requestCount) == (1), "a later timer does not fetch after Try Again")
            #expect(
                (store.tracks.map(\.uri))
                    == ([
                        "spotify:track:first"
                    ]), "a later timer does not replace retry results")
        }

        do {
            let (provider, gate) = makeGatedSearchCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let clock = CooperativeParkedClock()
            let store = makeStore(provider: provider, session: session, clock: clock)

            #expect(
                (await commitImmediateSearch(store, gate: gate, query: "alpha", tracks: [first])) == true,
                "empty-query fixture commits")

            let cancelledEmpty = Task { await store.scheduleSearch("   ") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "empty query parks before admission")
            cancelledEmpty.cancel()
            await cancelledEmpty.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]), "cancelled empty query leaves committed results"
            )
            #expect((await gate.requestCount) == (1), "cancelled empty query does not fetch")

            let admittedEmpty = Task { await store.scheduleSearch("\n\t") }
            #expect((await waitUntil { clock.waiterCount == 1 }) == true, "admitted empty query parks")
            clock.releaseAll()
            await admittedEmpty.value
            #expect((store.isEmpty) == true, "admitted empty query clears committed results")
            #expect((await gate.requestCount) == (1), "admitted empty query does not fetch")
            #expect((!store.isSearching) == true, "admitted empty query is not left searching")
        }
    }
}

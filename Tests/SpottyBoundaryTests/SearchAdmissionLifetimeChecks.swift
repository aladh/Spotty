@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore

@Suite("Search admission lifetime")
@MainActor
struct SearchAdmissionLifetimeTests {
    @Test
    func cancellingAPendingAdmissionReleasesItsCallerAndStoreBeforeTheTimerReturns() async throws {
        let clock = HarnessClock(sleep: .uncooperativelyParked)
        defer { clock.releaseAll() }
        let provider = catalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let completed = HarnessCounters()
        weak var released: SearchStore?
        do {
            let store = makeStore(provider, session: session, clock: clock)
            released = store
            await store.search("saved")
            let version = store.trackCollection.version
            let caller = Task.immediate {
                defer { completed.record("caller") }
                await store.scheduleSearch("pending")
            }
            defer { caller.cancel() }
            try await requireEventually { clock.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            #expect(store.trackCollection.version == version)
            #expect(!store.isSearching)
            #expect(provider.searchTrackRequestCount == 1)
            await caller.value
        }
        try await requireEventually { released == nil }
        #expect(clock.waiterCount == 1)
    }

    @Test(arguments: [false, true])
    func resetOrImmediateRetrySettlesTheRetiredAdmissionBeforeItsTimerReturns(retry: Bool) async throws {
        let clock = HarnessClock(sleep: .uncooperativelyParked)
        defer { clock.releaseAll() }
        let provider = catalog()
        let store = makeStore(provider, session: CatalogSessionAvailability(isAvailable: true), clock: clock)
        let completed = HarnessCounters()
        await store.search("saved")
        let caller = Task.immediate {
            defer { completed.record("caller") }
            await store.scheduleSearch("pending")
        }
        defer { caller.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        if retry { await store.search("retry") } else { store.reset() }
        try await requireEventually { completed.count("caller") == 1 }
        #expect(clock.waiterCount == 1)
        #expect(store.tracks.map(\.title) == (retry ? ["retry"] : []))
        #expect(provider.searchTrackRequestCount == (retry ? 2 : 1))
        await caller.value
    }

    @Test(arguments: ["same", "different"])
    func newerAdmissionSettlesTheOlderCallerBeforeEitherTimerReturns(newQuery: String) async throws {
        let clock = HarnessClock(sleep: .uncooperativelyParked)
        defer { clock.releaseAll() }
        let provider = catalog()
        let store = makeStore(provider, session: CatalogSessionAvailability(isAvailable: true), clock: clock)
        let completed = HarnessCounters()
        let first = Task.immediate {
            defer { completed.record("first") }
            await store.scheduleSearch("same")
        }
        defer { first.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        let second = Task.immediate { await store.scheduleSearch(newQuery) }
        defer { second.cancel() }
        try await requireEventually { clock.waiterCount == 2 }
        try await requireEventually { completed.count("first") == 1 }
        #expect(provider.searchTrackRequestCount == 0)
        clock.releaseAll()
        await second.value
        await first.value
        #expect(provider.searchTrackCalls.map(\.term) == [newQuery])
        #expect(store.tracks.map(\.title) == [newQuery])
    }

    @Test
    func cancellingAfterAdmissionSettlesLoadingAndReleasesTheStoreWhileAReadRemainsParked() async throws {
        let clock = HarnessClock.parked()
        defer { clock.releaseAll() }
        let read = HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored)
        defer { read.close() }
        let provider = catalog()
        provider.onSearchTracks = { _, _ in try await read.wait() }
        let completed = HarnessCounters()
        weak var released: SearchStore?
        do {
            let store = makeStore(provider, session: CatalogSessionAvailability(isAvailable: true), clock: clock)
            released = store
            let caller = Task.immediate {
                defer { completed.record("caller") }
                await store.scheduleSearch("pending")
            }
            defer { caller.cancel() }
            try await requireEventually { clock.waiterCount == 1 }
            clock.releaseNext()
            try await requireEventually { read.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            try await requireEventually { !store.isSearching }
            await caller.value
        }
        try await requireEventually { released == nil }
        #expect(read.waiterCount == 1)
    }

    @Test
    func coalescedReconnectRejectsTheOldTimerAndAdmitsANewSchedule() async throws {
        let clock = HarnessClock.parked()
        defer { clock.releaseAll() }
        let provider = catalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makeStore(provider, session: session, clock: clock)
        let old = Task.immediate { await store.scheduleSearch("old") }
        defer { old.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        clock.releaseNext()
        await old.value
        #expect(provider.searchTrackRequestCount == 0)
        let current = Task.immediate { await store.scheduleSearch("current") }
        defer { current.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        clock.releaseNext()
        await current.value
        #expect(provider.searchTrackCalls.map(\.term) == ["current"])
    }

    @Test(arguments: [false, true])
    func pendingReplacementPreservesImmediateFetchButRetiresAnOlderScheduledFetch(scheduled: Bool) async throws {
        let clock = HarnessClock.parked()
        defer { clock.releaseAll() }
        let response = HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored)
        defer { response.close() }
        let provider = catalog()
        provider.onSearchTracks = { term, _ in
            if term == "old" { return try await response.wait() }
            return [HarnessFixtures.track(uri: "spotify:track:new", title: "new")]
        }
        let store = makeStore(provider, session: CatalogSessionAvailability(isAvailable: true), clock: clock)
        let completed = HarnessCounters()
        let old = Task.immediate {
            defer { completed.record("old") }
            if scheduled { await store.scheduleSearch("old") } else { await store.search("old") }
        }
        defer { old.cancel() }
        if scheduled {
            try await requireEventually { clock.waiterCount == 1 }
            clock.releaseNext()
        }
        try await requireEventually { response.waiterCount == 1 }
        let next = Task.immediate { await store.scheduleSearch("new") }
        defer { next.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        if scheduled {
            try await requireEventually { completed.count("old") == 1 && !store.isSearching }
        } else {
            #expect(completed.count("old") == 0)
            #expect(store.isSearching)
        }
        response.finish([HarnessFixtures.track(uri: "spotify:track:old", title: "old")])
        await old.value
        #expect(store.tracks.map(\.title) == (scheduled ? [] : ["old"]))
        #expect(clock.waiterCount == 1)
        clock.releaseNext()
        await next.value
        #expect(store.tracks.map(\.title) == ["new"])
        #expect(provider.searchTrackCalls.map(\.term) == ["old", "new"])
    }

    @Test
    func disconnectedSchedulingClearsResultsWithoutStartingATimerOrFetch() async throws {
        let clock = HarnessClock.parked()
        defer { clock.releaseAll() }
        let provider = catalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makeStore(provider, session: session, clock: clock)
        await store.search("saved")
        session.update(accountEpoch: 1, isAvailable: false)
        let completed = HarnessCounters()
        let caller = Task.immediate {
            await store.scheduleSearch("offline")
            completed.record("caller")
        }
        defer { caller.cancel() }
        try await requireEventually { completed.count("caller") == 1 }
        await caller.value
        #expect(store.isEmpty)
        #expect(!store.isSearching)
        #expect(clock.requestedSleeps.isEmpty)
        #expect(provider.searchTrackRequestCount == 1)
    }

    private func catalog() -> HarnessCatalog {
        let provider = HarnessCatalog()
        provider.onSearchTracks = { term, _ in [HarnessFixtures.track(uri: "spotify:track:\(term)", title: term)] }
        return provider
    }

    private func makeStore(
        _ provider: HarnessCatalog, session: CatalogSessionAvailability, clock: HarnessClock
    ) -> SearchStore {
        SearchStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session, clock: clock)
    }
}

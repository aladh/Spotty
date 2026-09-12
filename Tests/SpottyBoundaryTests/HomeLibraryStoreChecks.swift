import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

/// Gates `HarnessCatalog.libraryPlaylists` so a check can park and release admitted requests one
/// at a time, mirroring the pre-harness `GatedPlaylistCatalog` actor.
private actor PlaylistGate {
    enum Outcome: Sendable {
        case playlists([PathfinderPlaylist])
        case failure
        case cancelled
        case urlCancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var requestCount = 0

    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        requestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .playlists(items):
            return items
        case .failure:
            throw HarnessFailure.unavailable
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        }
    }

    func completeNext(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: outcome)
    }
}

private func makeGatedPlaylistCatalog() -> (catalog: HarnessCatalog, gate: PlaylistGate) {
    let gate = PlaylistGate()
    let catalog = HarnessCatalog()
    catalog.onLibraryPlaylists = { [gate] in try await gate.libraryPlaylists() }
    return (catalog, gate)
}

private func decodePlaylist(_ json: String) throws -> PathfinderPlaylist {
    try JSONDecoder().decode(PathfinderPlaylist.self, from: Data(json.utf8))
}

private let firstPlaylistJSON = """
    {"uri":"spotify:playlist:first","name":"First Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
    """
private let secondPlaylistJSON = """
    {"uri":"spotify:playlist:second","name":"Second Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
    """

private func firstPlaylist() throws -> PathfinderPlaylist { try decodePlaylist(firstPlaylistJSON) }
private func secondPlaylist() throws -> PathfinderPlaylist { try decodePlaylist(secondPlaylistJSON) }

@MainActor
private func makeStore(
    provider: HarnessCatalog,
    session: CatalogSessionAvailability
) -> HomeLibraryStore {
    let metadata = CatalogMetadataRepository(
        attributesProvider: HarnessTrackAttributes(),
        session: session
    )
    return HomeLibraryStore(provider: provider, metadata: metadata, session: session)
}

/// Test-only: mark entry on MainActor immediately before `loadPlaylists`.
/// After `waitUntil` observes `entered`, that call has either reached its first
/// `await` (join) or returned, which would already have set `finished`.
@MainActor
private struct PlaylistLoadProbe {
    let task: Task<Void, Never>
    let hasEntered: () -> Bool
    let hasFinished: () -> Bool
}

@MainActor
private func startJoiningPlaylistLoad(_ store: HomeLibraryStore) -> PlaylistLoadProbe {
    var entered = false
    var finished = false
    let task = Task { @MainActor in
        entered = true
        await store.loadPlaylists()
        finished = true
    }
    return PlaylistLoadProbe(
        task: task,
        hasEntered: { entered },
        hasFinished: { finished }
    )
}

@Suite("Home Library Store")
struct HomeLibraryStoreTests {
    @Test
    @MainActor
    func testHomeLibraryStore() async {
        let first: PathfinderPlaylist
        let second: PathfinderPlaylist
        do {
            first = try firstPlaylist()
            second = try secondPlaylist()
        } catch {
            #expect((false) == true, "synthetic playlist fixtures decode")
            return
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let firstLoad = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 1 }) == true, "the first playlist request parks")
            let follower = startJoiningPlaylistLoad(store)
            #expect((await waitUntil { follower.hasEntered() }) == true, "the duplicate caller entered loadPlaylists")
            #expect(
                (await gate.requestCount) == (1), "a duplicate current-section request joins the in-flight work")
            #expect((store.isLoading(.playlists)) == true, "the joined section stays loading")
            #expect((!follower.hasFinished()) == true, "the duplicate caller is still waiting on the in-flight request")

            await gate.completeNext(.playlists([first]))
            await firstLoad.value
            await follower.task.value
            #expect((follower.hasFinished()) == true, "the duplicate caller finishes after the in-flight request")

            #expect((store.playlists.map(\.uri)) == (["spotify:playlist:first"]), "joined consumers publish one result")
            #expect((store.loadedSections.contains(.playlists)) == true, "the joined section is loaded once")
            #expect((!store.isLoading(.playlists)) == true, "joined loading finishes")
            #expect((store.error(for: .playlists)) == nil, "join does not surface an error")
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let stale = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 1 }) == true, "the superseded request parks")

            let forced = Task { await store.loadPlaylists(force: true) }
            #expect(
                (await waitUntil { await gate.requestCount == 2 }) == true,
                "force starts a new section request instead of joining")
            #expect((store.isLoading(.playlists)) == true, "the newest flight owns loading")
            #expect((store.error(for: .playlists)) == nil, "force clears the previous section error slot")

            await gate.completeNext(.playlists([first]))
            await stale.value
            #expect((store.isLoading(.playlists)) == true, "a stale success leaves the new request loading")
            #expect(
                (!store.loadedSections.contains(.playlists)) == true, "a stale success does not mark the section loaded"
            )
            #expect((store.playlists.map(\.uri)) == ([]), "a stale success does not publish")
            #expect((store.error(for: .playlists)) == nil, "a stale success does not surface an error")

            let joiner = startJoiningPlaylistLoad(store)
            #expect(
                (await waitUntil { joiner.hasEntered() }) == true, "the later non-forced caller entered loadPlaylists")
            #expect(
                (await gate.requestCount) == (2), "the old request cannot clear the new request's in-flight task")
            #expect((!joiner.hasFinished()) == true, "a later non-forced caller is still waiting on the newest flight")

            await gate.completeNext(.playlists([second]))
            await forced.value
            await joiner.task.value
            #expect((joiner.hasFinished()) == true, "the later non-forced caller finishes with the newest flight")

            #expect(
                (store.playlists.map(\.uri)) == (["spotify:playlist:second"]),
                "only the current forced request publishes")
            #expect((store.loadedSections.contains(.playlists)) == true, "the newest flight marks the section loaded")
            #expect((!store.isLoading(.playlists)) == true, "the newest flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let initial = Task { await store.loadPlaylists() }
            #expect(
                (await waitUntil { await gate.requestCount == 1 }) == true, "the initial playlist request parks")
            await gate.completeNext(.playlists([first]))
            await initial.value
            #expect(
                (store.playlists.map(\.uri)) == (["spotify:playlist:first"]),
                "the section is loaded before the forced refresh")

            let forced = Task { await store.loadPlaylists(force: true) }
            #expect(
                (await waitUntil { await gate.requestCount == 2 }) == true,
                "force refreshes an already-loaded section")
            let follower = startJoiningPlaylistLoad(store)
            #expect((await waitUntil { follower.hasEntered() }) == true, "the non-forced caller entered loadPlaylists")
            #expect((await gate.requestCount) == (2), "a non-forced caller joins the in-flight forced refresh")
            #expect((store.isLoading(.playlists)) == true, "the forced refresh keeps loading while the follower waits")
            #expect((!follower.hasFinished()) == true, "the non-forced caller is still waiting on the forced refresh")

            await gate.completeNext(.playlists([second]))
            await forced.value
            await follower.task.value
            #expect((follower.hasFinished()) == true, "the non-forced caller finishes after the forced refresh")
            #expect(
                (store.playlists.map(\.uri)) == (["spotify:playlist:second"]),
                "joined callers observe the forced refresh")
            #expect((!store.isLoading(.playlists)) == true, "the joined forced refresh finishes loading")
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let stale = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 1 }) == true, "the failing request parks")
            let forced = Task { await store.loadPlaylists(force: true) }
            #expect(
                (await waitUntil { await gate.requestCount == 2 }) == true, "force supersedes the failing request")

            await gate.completeNext(.failure)
            await stale.value
            #expect((store.isLoading(.playlists)) == true, "a stale failure leaves the new request loading")
            #expect((store.error(for: .playlists)) == nil, "a stale failure does not surface an error")

            await gate.completeNext(.urlCancelled)
            await forced.value
            #expect(
                (!store.loadedSections.contains(.playlists)) == true, "cancellation does not mark the section loaded")
            #expect((!store.isLoading(.playlists)) == true, "cancellation clears only the cancelled flight's loading")
            #expect((store.error(for: .playlists)) == nil, "cancellation does not surface a user-facing error")
            #expect((store.playlists.map(\.uri)) == ([]), "cancellation does not publish playlists")
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let staleEpoch = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 1 }) == true, "the pre-epoch request parks")
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.playlists([first]))
            await staleEpoch.value
            #expect((store.playlists.map(\.uri)) == ([]), "an older account epoch cannot publish")
            #expect(
                (!store.loadedSections.contains(.playlists)) == true,
                "an older account epoch cannot mark the section loaded")

            let staleRevision = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 2 }) == true, "the pre-reconnect request parks")
            session.update(accountEpoch: 2, isAvailable: false)
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.playlists([first]))
            await staleRevision.value
            #expect((store.playlists.map(\.uri)) == ([]), "a pre-reconnect result cannot publish")

            let current = Task { await store.loadPlaylists() }
            #expect(
                (await waitUntil { await gate.requestCount == 3 }) == true,
                "a new session starts a distinct request")
            await gate.completeNext(.playlists([second]))
            await current.value
            #expect((store.playlists.map(\.uri)) == (["spotify:playlist:second"]), "the current session publishes")
            #expect((store.loadedSections.contains(.playlists)) == true, "the current session marks the section loaded")

            session.update(accountEpoch: 3, isAvailable: true)
            let afterEpoch = Task { await store.loadPlaylists() }
            #expect(
                (await waitUntil { await gate.requestCount == 4 }) == true,
                "a later account epoch reloads a previously loaded section")
            await gate.completeNext(.playlists([first]))
            await afterEpoch.value
            #expect((store.playlists.map(\.uri)) == (["spotify:playlist:first"]), "the later account epoch publishes")

            session.update(accountEpoch: 3, isAvailable: false)
            session.update(accountEpoch: 3, isAvailable: true)
            let afterRevision = Task { await store.loadPlaylists() }
            #expect(
                (await waitUntil { await gate.requestCount == 5 }) == true,
                "a new session revision reloads a previously loaded section")
            await gate.completeNext(.playlists([second]))
            await afterRevision.value
            #expect((store.playlists.map(\.uri)) == (["spotify:playlist:second"]), "the new session revision publishes")
        }

        do {
            let (provider, gate) = makeGatedPlaylistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeStore(provider: provider, session: session)

            let inflight = Task { await store.loadPlaylists() }
            #expect((await waitUntil { await gate.requestCount == 1 }) == true, "the torn-down request parks")
            #expect((store.isLoading(.playlists)) == true, "teardown starts from a loading section")

            store.reset()
            #expect((!store.isLoading) == true, "reset clears loading")
            #expect((store.loadedSections.isEmpty) == true, "reset clears loaded sections")
            #expect((store.playlists.map(\.uri)) == ([]), "reset clears playlists")
            #expect((store.error(for: .playlists)) == nil, "reset clears section errors")

            await gate.completeNext(.playlists([first]))
            await inflight.value
            #expect((store.playlists.map(\.uri)) == ([]), "a torn-down success cannot publish")
            #expect((!store.isLoading) == true, "a torn-down success cannot restore loading")
            #expect((store.loadedSections.isEmpty) == true, "a torn-down success cannot mark the section loaded")
            #expect((store.error(for: .playlists)) == nil, "a torn-down success cannot surface an error")
        }
    }
}

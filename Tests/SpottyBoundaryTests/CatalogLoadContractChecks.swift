@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Shared catalog load contract")
@MainActor
struct CatalogLoadContractChecks {
    @Test(arguments: [false, true])
    func cancelledRefreshNeverRestoresCurrentAuthority(saved: Bool) {
        let session = CatalogSessionAvailability(isAvailable: true)
        var state = CatalogLoadState()
        state.receive(session: session.snapshot, freshness: saved ? .cached(fetchedAt: HarnessDates.fixed) : .current)
        #expect(state.isCurrent(in: session.snapshot) == !saved)
        state.begin()
        #expect(state.isLoading && state.hasContent)
        #expect(!state.isCurrent(in: session.snapshot))
        state.finish()  // Cancelled reads finish without publishing or inventing an error.
        #expect(!state.isLoading && state.error == nil)
        #expect(state.isShowingSavedContent(in: session.snapshot))
        state.begin()
        state.receive(session: session.snapshot)
        #expect(!state.isCurrent(in: session.snapshot), "receiving saved or live data does not finish a request")
        state.finish()
        #expect(state.isCurrent(in: session.snapshot))
        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        #expect(!state.isCurrent(in: session.snapshot), "reconnect requires new proof")
    }

    @Test(arguments: ["playlist", "album", "artist", "discography"], [false, true])
    func detailStoresRetainTransientFailuresAndRetireCredentialRefusals(surface: String, empty: Bool) async {
        let provider = HarnessCatalog()
        let tracks = empty ? [] : [HarnessFixtures.track(uri: "spotify:track:kept")]
        let releases = empty ? [] : [item("release", kind: .album)]
        provider.onPlaylist = { _ in .init(description: "Kept", ownerURI: nil, tracks: tracks) }
        provider.onAlbum = { _ in .init(tracks: tracks, releaseDate: "2026") }
        provider.onArtist = { _ in .init(name: "Artist", releases: releases) }
        provider.onArtistDiscography = provider.onArtist
        let session = CatalogSessionAvailability(isAvailable: true)
        let adapter = detail(surface, provider: provider, session: session)
        await adapter.load(false)
        let expected = empty ? 0 : 1
        #expect(adapter.count() == expected && !adapter.saved() && adapter.error() == nil)
        for failure in [CatalogReadFailure.offline, .timedOut, .throttled, .compatibility, .sessionExpired] {
            provider.onPlaylist = { _ in throw failure }
            provider.onAlbum = { _ in throw failure }
            provider.onArtist = { _ in throw failure }
            provider.onArtistDiscography = { _ in throw failure }
            await adapter.load(true)
            #expect(adapter.error() != nil)
            #expect(adapter.count() == (failure == .sessionExpired ? 0 : expected))
            #expect(adapter.saved() == (failure != .sessionExpired))
        }
    }

    #if DEBUG
        @Test func libraryRefusalRetiresEverySectionAndFencesALateSibling() async throws {
            let provider = HarnessCatalog()
            let playlist = item("kept", kind: .playlist)
            let album = item("album", kind: .album)
            let artist = item("artist", kind: .artist)
            let track = HarnessFixtures.track(uri: "spotify:track:kept")
            provider.onHome = { .init(greeting: "Kept", sections: []) }
            provider.onProfile = { .init(name: "Kept", uri: "spotify:user:fixture") }
            provider.onPlaylistLibrary = { [PlaylistLibraryNode(playlist: playlist)] }
            provider.onLibraryAlbums = { [album] }
            provider.onLibraryArtists = { [artist] }
            provider.onLibraryTracks = { [track] }
            let session = CatalogSessionAvailability(isAvailable: true)
            let metadata = CatalogMetadataRepository(session: session)
            let store = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
            let responses = HarnessResponseGate<Void>(cancellation: .ignored)
            let operations = CatalogContractOperations(
                responses: responses, snapshot: { store.workerSettlements() }, reset: { store.reset() })
            try await operations.run { owned in
                await store.loadHome()
                await store.loadProfile()
                await store.loadPlaylists()
                await store.loadAlbums()
                await store.loadArtists()
                await store.loadLikedTracks()
                try #require(store.loadedSections == Set(HomeLibraryStore.Section.allCases))
                #expect(store.playlists == [playlist])
                #expect(store.albums == [album] && store.artists == [artist] && store.likedTracks == [track])
                provider.onPlaylistLibrary = {
                    try await responses.wait()
                    return [PlaylistLibraryNode(playlist: playlist)]
                }
                let late = owned.start { await store.loadPlaylists(force: true) }
                try await requireEventually(description: "The late playlist sibling enters its response gate") {
                    responses.requestCount == 1 && responses.waiterCount == 1
                }
                let workers = try owned.captureWorkers(expected: 1)
                provider.onLibraryAlbums = { throw CatalogReadFailure.sessionExpired }
                await store.loadAlbums(force: true)
                #expect(store.playlists.isEmpty && store.loadedSections.isEmpty && store.isLoading == false)
                #expect(store.albums.isEmpty && store.artists.isEmpty && store.likedTracks.isEmpty)
                #expect(store.profileURI == nil && store.homeSections.isEmpty)
                #expect(store.errors.count == HomeLibraryStore.Section.allCases.count)
                responses.finish(())
                // Refusal settles the caller immediately. Join the captured real worker to
                // prove that its late response has also passed through the publication guard.
                for worker in workers { await worker.value }
                await late.value
                #expect(store.playlists.isEmpty && store.loadedSections.isEmpty)
                #expect(store.errors.count == HomeLibraryStore.Section.allCases.count)
                provider.onPlaylistLibrary = { [] }
                await store.loadPlaylists()
                #expect(store.loadedSections.contains(.playlists), "A fresh successful empty result clears the refusal")
                #expect(store.error(for: .playlists) == nil)
                #expect(store.playlists.isEmpty, "Fresh successful empty data replaces refused content")
            }
        }

        @Test func cancelledRefreshStaysStaleAcrossRouteRevisits() async throws {
            let provider = HarnessCatalog()
            provider.onPlaylist = { _ in .init(description: "Kept", ownerURI: nil, tracks: []) }
            let session = CatalogSessionAvailability(isAvailable: true)
            let store = PlaylistStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            let selected = item("fixture", kind: .playlist)
            let clock = HarnessClock.parked()
            let operations = CatalogContractOperations(
                responses: HarnessResponseGate<Void>(cancellation: .ignored), clock: clock,
                snapshot: { store.workerSettlements() }, reset: { store.reset() })
            try await operations.run { owned in
                await store.load(selected)
                try #require(store.canEditLoadedContent)
                provider.onPlaylist = { _ in
                    try await clock.sleep(seconds: 1)
                    throw CatalogReadFailure.offline
                }
                let refresh = owned.start { await store.load(selected, force: true) }
                try await requireEventually(description: "The playlist refresh enters its parked provider") {
                    clock.waiterCount == 1
                }
                let workers = try owned.captureWorkers(expected: 1)
                refresh.cancel()
                try await requireEventually(description: "The cancelled refresh caller returns") {
                    owned.completedCallerCount == 1
                }
                await refresh.value
                for worker in workers { await worker.value }
                #expect(clock.waiterCount == 0)
                #expect(store.canEditLoadedContent == false && store.error == nil)
                store.prepare(item("other", kind: .playlist))
                store.prepare(selected)
                #expect(store.isShowingCachedContent && store.canEditLoadedContent == false)
                provider.onPlaylist = { _ in .init(description: "Fresh", ownerURI: nil, tracks: []) }
                await store.load(selected)
                #expect(store.description == "Fresh" && store.canEditLoadedContent)
            }
        }

        @Test func earlyLibraryReplyFinishesWithoutARegisteredWaiter() async throws {
            let provider = HarnessCatalog()
            let responses = HarnessResponseGate<Void>(cancellation: .ignored)
            provider.onLibraryAlbums = {
                try await responses.wait()
                return []
            }
            let session = CatalogSessionAvailability(isAvailable: true)
            let store = HomeLibraryStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            let operations = CatalogContractOperations(
                responses: responses, snapshot: { store.workerSettlements() }, reset: { store.reset() })
            try await operations.run { owned in
                responses.finish(())
                let loading = owned.start { await store.loadAlbums() }
                await loading.value
                #expect(responses.requestCount == 1 && responses.waiterCount == 0)
                #expect(store.loadedSections.contains(.albums) && store.error(for: .albums) == nil)
                #expect(store.workerSettlements().isEmpty)
            }
        }

        @Test func fixtureFailureBeforeRegistrationClosesFutureLibraryCalls() async throws {
            let provider = HarnessCatalog()
            let responses = HarnessResponseGate<Void>(cancellation: .ignored)
            provider.onLibraryAlbums = {
                try await responses.wait()
                return []
            }
            let session = CatalogSessionAvailability(isAvailable: true)
            let store = HomeLibraryStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            let operations = CatalogContractOperations(
                responses: responses, snapshot: { store.workerSettlements() }, reset: { store.reset() })
            do {
                try await operations.run { owned in
                    _ = owned.start { await store.loadAlbums() }
                    // Throw on MainActor before the admitted caller can register a waiter.
                    throw CatalogCleanupProbe.interrupted
                }
                Issue.record("The injected prerequisite failure must propagate")
            } catch CatalogCleanupProbe.interrupted {}
            #expect(operations.completedCallerCount == 1)
            #expect(responses.waiterCount == 0 && store.isLoading == false)
            do {
                try await responses.wait()
                Issue.record("Terminal closure must also refuse future calls")
            } catch is CancellationError {}
            #expect(responses.waiterCount == 0)
        }

        @Test func extraLibraryFixtureCallCannotStrandFailureCleanup() async throws {
            let provider = HarnessCatalog()
            let responses = HarnessResponseGate<Void>(cancellation: .ignored)
            provider.onLibraryAlbums = {
                try await responses.wait()
                return []
            }
            provider.onLibraryArtists = {
                try await responses.wait()
                return []
            }
            let session = CatalogSessionAvailability(isAvailable: true)
            let store = HomeLibraryStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            let operations = CatalogContractOperations(
                responses: responses, snapshot: { store.workerSettlements() }, reset: { store.reset() })
            do {
                try await operations.run { owned in
                    _ = owned.start { await store.loadAlbums() }
                    _ = owned.start { await store.loadArtists() }
                    try await requireEventually(description: "Both fixture calls register their independent waiters") {
                        responses.requestCount == 2 && responses.waiterCount == 2
                    }
                    _ = try owned.captureWorkers(expected: 2)
                    throw CatalogCleanupProbe.interrupted
                }
                Issue.record("The injected prerequisite failure must propagate")
            } catch CatalogCleanupProbe.interrupted {}
            #expect(operations.completedCallerCount == 2)
            #expect(responses.waiterCount == 0 && store.isLoading == false)
            #expect(store.workerSettlements().isEmpty)
            do {
                try await responses.wait()
                Issue.record("An extra future fixture call must observe terminal closure")
            } catch is CancellationError {}
            #expect(responses.requestCount == 3 && responses.waiterCount == 0)
        }
    #endif

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id, subtitle: "", artworkURL: nil,
            kind: kind)
    }

    private struct Detail {
        let load: (Bool) async -> Void
        let count: () -> Int
        let saved: () -> Bool
        let error: () -> String?
    }

    private func detail(_ surface: String, provider: HarnessCatalog, session: CatalogSessionAvailability) -> Detail {
        let metadata = CatalogMetadataRepository(session: session)
        switch surface {
        case "playlist":
            let store = PlaylistStore(provider: provider, metadata: metadata, session: session)
            return Detail(
                load: { await store.load(item("fixture", kind: .playlist), force: $0) }, count: { store.tracks.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        case "album":
            let store = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
            return Detail(
                load: { await store.load(item("fixture", kind: .album), force: $0) }, count: { store.tracks.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        default:
            let store = ArtistDetailStore(
                provider: provider, session: session, content: surface == "artist" ? .overview : .discography)
            return Detail(
                load: { await store.load(item("fixture", kind: .artist), force: $0) }, count: { store.releases.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        }
    }
}

#if DEBUG
    private enum CatalogCleanupProbe: Error { case interrupted }

    /// Owns test callers and snapshots of the stores' actual workers. It introduces no
    /// completion task: a retained worker's value includes processing and complete(handle).
    @MainActor
    private final class CatalogContractOperations {
        private let responses: HarnessResponseGate<Void>
        private let clock: HarnessClock?
        private let snapshot: () -> [Task<Void, Never>]
        private let reset: () -> Void
        private let completedCallers = HarnessCounters()
        private var callers: [Task<Void, Never>] = []
        private var workers: [Task<Void, Never>] = []

        init(
            responses: HarnessResponseGate<Void>, clock: HarnessClock? = nil,
            snapshot: @escaping () -> [Task<Void, Never>], reset: @escaping () -> Void
        ) {
            self.responses = responses
            self.clock = clock
            self.snapshot = snapshot
            self.reset = reset
        }

        var completedCallerCount: Int { completedCallers.count("completed") }

        func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
            let caller = Task {
                defer { completedCallers.record("completed") }
                await operation()
            }
            callers.append(caller)
            return caller
        }

        func captureWorkers(expected: Int, sourceLocation: SourceLocation = #_sourceLocation) throws
            -> [Task<Void, Never>]
        {
            let accepted = snapshot()
            // Own every observed task before a throwing assertion or any cancellation/reset.
            workers.append(contentsOf: accepted)
            try #require(
                accepted.count == expected, "The admitted calls must own actual workers",
                sourceLocation: sourceLocation)
            return accepted
        }

        func run(_ body: (CatalogContractOperations) async throws -> Void) async throws {
            do {
                try await body(self)
            } catch {
                await cleanUp()
                throw error
            }
            await cleanUp()
        }

        private func cleanUp() async {
            // Capture current slots before reset/cancellation can clear them, including any
            // unexpected worker that appeared before a failed admission prerequisite.
            workers.append(contentsOf: snapshot())
            responses.close()
            // releaseAll alone is not terminal for future sleepers. Switch future calls to
            // immediate cooperative completion before releasing current clock waiters.
            clock?.sleepBehavior = .immediate
            clock?.releaseAll()
            for caller in callers { caller.cancel() }
            for worker in workers { worker.cancel() }
            reset()
            for caller in callers { await caller.value }
            for worker in workers { await worker.value }
        }
    }
#endif

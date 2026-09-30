@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import Synchronization
import Testing
@testable import SpottyCore

#if DEBUG
    @Suite("Playlist query ownership")
    @MainActor
    struct PlaylistQueryOwnerTests {
        @Test
        func cancellingTheOriginalCallerPreservesTheJoinedCachedAndLiveLoad() async throws {
            let saved = snapshot("Saved", freshness: .cached(fetchedAt: HarnessDates.fixed))
            try await PlaylistOwnerFixture(saved: saved).run { fixture in
                let selected = item("first")
                let original = fixture.start(selected)
                let worker = try await fixture.requireRequest(1)
                try #require(fixture.store.description == "Saved")
                let joined = fixture.start(selected)
                original.task.cancel()
                try await fixture.joinCaller(original)

                #expect(fixture.hasReturned(joined) == false)
                #expect(fixture.store.isLoading)
                #expect(fixture.store.isShowingCachedContent)
                #expect(fixture.store.canEditLoadedContent == false)
                #expect(fixture.responses.pendingRequestIDs == [1])
                #expect(fixture.provider.count("cachedPlaylist") == 1 && fixture.provider.playlistRequestCount == 1)
                fixture.responses.finish(1, snapshot("Live"))
                await worker.value
                try await fixture.joinCaller(joined)

                #expect(fixture.store.description == "Live")
                #expect(fixture.store.isLoading == false && fixture.store.canEditLoadedContent)
                #expect(fixture.store.freshness == .current)
                #expect(fixture.store.tracks.map(\.id) == saved.tracks.map(\.id))
                #expect(fixture.store.tracks.map(\.occurrenceUID) == ["server-a", "server-b"])
                #expect(fixture.store.tracks.map(\.uri) == ["spotify:track:duplicate", "spotify:track:duplicate"])
            }
        }

        @Test(arguments: [false, true])
        func finalCancellationSettlesLoadingAndFencesTheReplyFromItsReplacement(
            replacementPublishesFirst: Bool
        ) async throws {
            try await PlaylistOwnerFixture().run { fixture in
                let store = fixture.store
                let selected = item("first")
                let cancelled = fixture.start(selected)
                // Retain the actual task while its response is parked, before cancellation
                // removes its slot. Its value includes publication checks and complete(handle).
                let oldWorker = try await fixture.requireRequest(1)
                cancelled.task.cancel()
                try await fixture.joinCaller(cancelled)
                #expect(store.isLoading == false)
                #expect(fixture.responses.pendingRequestIDs == [1])
                #expect(store.tracks.isEmpty)

                let fresh = fixture.start(selected)
                let replacementWorker = try await fixture.requireRequest(2)
                try #require(store.isLoading)
                let parkedVersion = store.trackCollection.version
                let parkedFreshness = store.freshness
                var publishedVersion = parkedVersion
                if replacementPublishesFirst {
                    fixture.responses.finish(2, snapshot("Replacement"))
                    await replacementWorker.value
                    try await fixture.joinCaller(fresh)
                    expectReplacement(fixture)
                    publishedVersion = store.trackCollection.version
                }

                fixture.responses.finish(1, snapshot("Forbidden old"))
                await oldWorker.value
                let replacementIsLoading = store.isLoading
                if replacementPublishesFirst {
                    expectReplacement(fixture)
                    #expect(store.trackCollection.version == publishedVersion)
                } else {
                    #expect(store.tracks.isEmpty, "the obsolete worker cannot publish while its replacement is parked")
                    #expect(store.description.isEmpty)
                    // The retained worker has now executed complete(handle). This assertion
                    // consumes owner settlement, rather than a provider-return/caller receipt.
                    try #require(replacementIsLoading, "the obsolete worker cannot settle its replacement")
                    #expect(store.hasLoadedContent == false && store.canEditLoadedContent == false)
                    #expect(store.isShowingCachedContent == false)
                    #expect(store.freshness == parkedFreshness)
                    #expect(store.trackCollection.version == parkedVersion)
                    #expect(fixture.metadata.knownTrack(for: "spotify:track:duplicate") == nil)
                    fixture.responses.finish(2, snapshot("Replacement"))
                    await replacementWorker.value
                    try await fixture.joinCaller(fresh)
                    expectReplacement(fixture)
                }

                #expect(fixture.provider.playlistRequestCount == 2)
                let version = store.trackCollection.version
                store.prepare(item("other"))
                store.prepare(selected)
                expectReplacement(fixture)
                #expect(
                    store.trackCollection.version == version, "A → B → A reuses the authoritative retained collection")
                let revisited = fixture.start(selected)
                try await fixture.joinCaller(revisited)
                #expect(fixture.provider.playlistRequestCount == 2)
                #expect(store.trackCollection.version == version)
            }
        }

        @Test(arguments: [false, true], [false, true])
        func numberedRepliesRetainSuccessAndFailureBeforeOrAfterRegistration(early: Bool, success: Bool) async throws {
            let script = PlaylistOwnerResponses()
            defer { script.close() }
            let reply: Result<CatalogPlaylistSnapshot, any Error> =
                success ? .success(snapshot("Early")) : .failure(PlaylistOwnerResponses.Failure.scriptedRejection)
            if early { script.resolve(1, reply) }
            let caller = Task { try await script.next() }
            do {
                if !early {
                    try await requireEventually { script.pendingRequestIDs == [1] }
                    script.resolve(1, reply)
                }
                switch await caller.result {
                case let .success(value):
                    #expect(success)
                    #expect(value.description == "Early")
                    #expect(value.tracks.map(\.occurrenceUID) == ["server-a", "server-b"])
                case let .failure(error):
                    #expect(success == false)
                    #expect(error as? PlaylistOwnerResponses.Failure == .scriptedRejection)
                }
            } catch {
                script.close()
                caller.cancel()
                _ = await caller.result
                throw error
            }
            #expect(script.pendingRequestIDs.isEmpty)
        }

        @Test(arguments: [0, 1, 2])
        func throwingPrerequisitesCloseCurrentAndFutureCallsAndJoinAcceptedWorkers(admitted: Int) async throws {
            let fixture = PlaylistOwnerFixture()
            do {
                try await fixture.run { fixture in
                    if admitted > 0 {
                        _ = fixture.start(item("first"))
                        _ = try await fixture.requireRequest(1)
                    } else {
                        try #require(fixture.store.workerSettlements().isEmpty)
                    }
                    if admitted > 1 {
                        fixture.store.reset()
                        _ = fixture.start(item("first"))
                        _ = try await fixture.requireRequest(2)
                    }
                    try #require(fixture.responses.requestCount == admitted)
                    throw PlaylistOwnerPrerequisiteFailure.injected
                }
                Issue.record("The injected prerequisite must throw")
            } catch PlaylistOwnerPrerequisiteFailure.injected {}
            #expect(fixture.responses.pendingRequestIDs.isEmpty)
            #expect(fixture.store.workerSettlements().isEmpty)
            #expect(fixture.store.isLoading == false)
            fixture.responses.finish(1, snapshot("Late"))
            fixture.responses.close()
            do {
                _ = try await fixture.responses.next()
                Issue.record("Terminal cleanup must reject future requests even after a late reply")
            } catch is CancellationError {}
        }

        @Test
        func anUnexpectedThirdProviderCallFailsImmediatelyAndItsActualWorkerJoins() async throws {
            try await PlaylistOwnerFixture().run { fixture in
                let selected = item("first")
                for requestID in 1...2 {
                    let caller = fixture.start(selected, force: true)
                    let worker = try await fixture.requireRequest(requestID)
                    fixture.responses.finish(requestID, snapshot("Accepted"))
                    await worker.value
                    try await fixture.joinCaller(caller)
                }
                // Task.immediate admits the read in this MainActor turn. Capture its installed
                // task before the finite script's immediate failure can complete and clear it.
                let extra = fixture.start(selected, force: true)
                let extraWorker = try fixture.captureWorker()
                await extraWorker.value
                try await fixture.joinCaller(extra)
                #expect(fixture.responses.requestCount == 3)
                #expect(fixture.responses.pendingRequestIDs.isEmpty)
                #expect(fixture.store.isLoading == false && fixture.store.canEditLoadedContent == false)
                #expect(fixture.store.description == "Accepted")
                #expect(fixture.store.error != nil)
            }
            let script = PlaylistOwnerResponses()
            defer { script.close() }
            script.finish(1, snapshot("One"))
            script.finish(2, snapshot("Two"))
            _ = try await script.next()
            _ = try await script.next()
            do {
                _ = try await script.next()
                Issue.record("An unexpected third call must not park or silently succeed")
            } catch let error as PlaylistOwnerResponses.Failure {
                #expect(error == .unexpectedRequest(3))
            }
        }

        private func expectReplacement(_ fixture: PlaylistOwnerFixture) {
            let store = fixture.store
            #expect(store.description == "Replacement")
            #expect(store.isLoading == false && store.canEditLoadedContent)
            #expect(store.hasLoadedContent && store.isShowingCachedContent == false)
            #expect(store.freshness == .current)
            #expect(store.ownerURI == "spotify:user:owner")
            #expect(store.tracks.map(\.id) == ["display-a", "display-b"])
            #expect(store.tracks.map(\.occurrenceUID) == ["server-a", "server-b"])
            #expect(store.tracks.map(\.uri) == ["spotify:track:duplicate", "spotify:track:duplicate"])
            #expect(fixture.metadata.knownTrack(for: "spotify:track:duplicate")?.title == "Replacement")
        }

        private func item(_ id: String) -> CatalogItem {
            CatalogItem(
                id: id, uri: "spotify:playlist:\(id)", title: id, subtitle: "", artworkURL: nil,
                kind: .playlist)
        }

        private func snapshot(_ title: String, freshness: CatalogFreshness = .current) -> CatalogPlaylistSnapshot {
            let tracks = ["a", "b"].map { suffix in
                CatalogTrack(
                    id: "display-\(suffix)", uri: "spotify:track:duplicate", title: title,
                    artist: "Artist", album: "Album", duration: 100, artworkURL: nil,
                    addedAt: HarnessDates.fixed, occurrenceUID: "server-\(suffix)")
            }
            return CatalogPlaylistSnapshot(
                description: title, ownerURI: "spotify:user:owner", tracks: tracks, freshness: freshness)
        }
    }

    private enum PlaylistOwnerPrerequisiteFailure: Error { case injected }

    /// The joined old/replacement provider calls need a numbered script the single-response
    /// harness cannot express. Exact early results are retained once for requests1/2; request3
    /// fails immediately. Close overrides unused replies and cancels registered/future calls.
    private final class PlaylistOwnerResponses: Sendable {
        enum Failure: Error, Equatable { case unexpectedRequest(Int), scriptedRejection }
        private struct State {
            var nextRequestID = 0
            var closed = false
        }
        private let state = Mutex(State())
        private let responses = (0..<2).map { _ in
            HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        }

        var requestCount: Int { state.withLock { $0.nextRequestID } }
        var pendingRequestIDs: Set<Int> {
            Set(responses.enumerated().compactMap { $0.element.waiterCount == 1 ? $0.offset + 1 : nil })
        }

        func next() async throws -> CatalogPlaylistSnapshot {
            let id = try state.withLock { state in
                guard !state.closed else { throw CancellationError() }
                state.nextRequestID += 1
                guard state.nextRequestID <= responses.count else {
                    throw Failure.unexpectedRequest(state.nextRequestID)
                }
                return state.nextRequestID
            }
            return try await responses[id - 1].wait()
        }

        func finish(_ requestID: Int, _ value: CatalogPlaylistSnapshot) { resolve(requestID, .success(value)) }
        func resolve(_ requestID: Int, _ value: Result<CatalogPlaylistSnapshot, any Error>) {
            responses[requestID - 1].resolve(value)
        }

        func close() {
            state.withLock { $0.closed = true }
            responses.forEach { $0.close() }
        }
    }

    /// Keeps the stores' real workers across slot retirement. Caller-return counts only bound
    /// prompt subscriber joins; owner publication/complete assertions always join worker.value.
    @MainActor
    private final class PlaylistOwnerFixture {
        struct Caller {
            let id: Int
            let task: Task<Void, Never>
        }
        let responses: PlaylistOwnerResponses
        let provider: HarnessCatalog
        let metadata: CatalogMetadataRepository
        let store: PlaylistStore
        private let returnedCallers = HarnessCounters()
        private var callers: [Caller] = []
        private var workers: [Task<Void, Never>] = []

        init(saved: CatalogPlaylistSnapshot? = nil) {
            let responses = PlaylistOwnerResponses()
            let provider = HarnessCatalog()
            provider.onCachedPlaylist = { _ in saved }
            provider.onPlaylist = { _ in try await responses.next() }
            let session = CatalogSessionAvailability(isAvailable: true)
            let metadata = CatalogMetadataRepository(session: session)
            self.responses = responses
            self.provider = provider
            self.metadata = metadata
            store = PlaylistStore(provider: provider, metadata: metadata, session: session)
        }

        func start(_ item: CatalogItem, force: Bool = false) -> Caller {
            let id = callers.count + 1
            let store = store
            let returned = returnedCallers
            let task = Task.immediate {
                defer { returned.record("caller-\(id)") }
                await store.load(item, force: force)
            }
            let caller = Caller(id: id, task: task)
            callers.append(caller)
            // Admission completes synchronously before the caller awaits its shared waiter.
            // Retain any installed task before even an early scripted reply can finish it.
            workers.append(contentsOf: store.workerSettlements())
            return caller
        }

        func hasReturned(_ caller: Caller) -> Bool { returnedCallers.count("caller-\(caller.id)") == 1 }
        func joinCaller(_ caller: Caller) async throws {
            try await requireEventually { hasReturned(caller) }
            await caller.task.value
        }

        func captureWorker() throws -> Task<Void, Never> {
            let accepted = store.workerSettlements()
            workers.append(contentsOf: accepted)
            try #require(accepted.count == 1, "The admitted query owns one actual worker")
            return accepted[0]
        }

        func requireRequest(_ requestID: Int) async throws -> Task<Void, Never> {
            try await requireEventually { responses.pendingRequestIDs.contains(requestID) }
            return try captureWorker()
        }

        func run(_ body: @MainActor (PlaylistOwnerFixture) async throws -> Void) async throws {
            do {
                try await body(self)
            } catch {
                await closeAndJoin()
                throw error
            }
            await closeAndJoin()
        }

        private func closeAndJoin() async {
            workers.append(contentsOf: store.workerSettlements())
            responses.close()
            store.reset()
            callers.forEach { $0.task.cancel() }
            workers.forEach { $0.cancel() }
            for caller in callers { await caller.task.value }
            for worker in workers { await worker.value }
        }
    }
#endif

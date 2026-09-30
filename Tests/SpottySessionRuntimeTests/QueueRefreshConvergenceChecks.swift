@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import Testing
import SpottyDomain
@testable import SpottySessionRuntime
import SpottyRuntimeContracts

private func queueRefreshTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

@Suite("Queue refresh convergence")
struct QueueRefreshConvergenceTests {
    @Test
    @MainActor
    func connectOrderingAdvancesPresentationAfterMetadataRevisionOvertakesWireRevision() async throws {
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: HarnessRemote(metadata: .park)))
        await service.reset(accountEpoch: 1)
        let context = "spotify:track:current"
        let a = QueueEntry(uri: "spotify:track:a", provider: "connect")
        let b = QueueEntry(uri: "spotify:track:b", provider: "connect")
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                trackURI: context,
                next: HarnessFixtures.queueTracks([a])),
            accountEpoch: 1, fallbackTrackURI: nil)
        let hydrated = try #require(
            await service.refresh(
                fallbackEntries: [a],
                cachedTracks: [queueRefreshTrack(a.uri)], currentTrackURI: context, accountEpoch: 1))
        #expect(hydrated.revision >= 2, "metadata has advanced the presentation counter")
        let replacement = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 2,
                    trackURI: context,
                    next: HarnessFixtures.queueTracks([b])),
                accountEpoch: 1, fallbackTrackURI: nil))
        #expect(replacement.snapshot.entries.map(\.uri) == [b.uri])
        #expect(
            replacement.snapshot.revision > hydrated.revision,
            "fresh Connect ordering must pass the store's strict presentation revision gate")
        #expect(replacement.mutation.sourceRevision == 2, "the independent wire revision stays unchanged")
        let stale = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 1,
                    trackURI: context,
                    next: HarnessFixtures.queueTracks([a])),
                accountEpoch: 1, fallbackTrackURI: nil))
        #expect(stale.snapshot.entries.map(\.uri) == [b.uri])
        #expect(stale.snapshot.revision == replacement.snapshot.revision)
    }

    @Test
    @MainActor
    func metadataPublishesInBatchesAndFlushesWhileAnotherRequestIsStalled() async throws {
        let clock = HarnessClock.parked()
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: remote), clock: clock)
        await service.reset(accountEpoch: 1)
        let uris = ["spotify:track:a", "spotify:track:b", "spotify:track:c"]
        let updates = RuntimeCallbackRecorder<ProvenanceQueueSnapshot>()
        let refresh = Task {
            await service.refresh(
                fallbackEntries: uris.enumerated().map {
                    QueueEntry(uri: $0.element, provider: "connect", occurrence: $0.offset)
                }, currentTrackURI: "spotify:track:current", accountEpoch: 1,
                onUpdate: { updates.append($0) })
        }
        defer {
            refresh.cancel()
            for uri in remote.parkedMetadataURIs { _ = remote.failMetadata(for: uri) }
            clock.releaseAll()
        }
        try await requireEventually { remote.parkedMetadataURIs == Set(uris) }
        #expect(remote.requestedURIs.count == 3)
        #expect(updates.snapshot.count == 1, "order appears before enrichment")
        #expect(remote.completeMetadata(for: uris[0]))
        #expect(remote.completeMetadata(for: uris[1]))
        try await requireEventually { await service.refreshDiagnostics.metadataResults == 2 }
        try await requireEventually { clock.waiterCount == 1 }
        #expect(updates.snapshot.count == 1, "a burst does not publish per track")
        clock.releaseAll()
        #expect(await waitUntil { updates.snapshot.count == 2 })
        #expect(Set(updates.snapshot.last?.tracks.map(\.uri) ?? []) == Set(uris.prefix(2)))
        #expect(remote.completeMetadata(for: uris[2]))
        try await requireEventually { await service.refreshDiagnostics.metadataResults == 3 }
        try await requireEventually { clock.waiterCount == 1 }
        clock.releaseAll()
        let result = await refresh.value
        #expect(result?.tracks.count == 3)
        #expect(updates.snapshot.count == 3)
        #expect(clock.requestedSleeps == [0.05, 0.05])
    }

    @Test
    @MainActor
    func accountReplacementCancelsAnUnpublishedMetadataBatch() async throws {
        let clock = HarnessClock.parked()
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: remote), clock: clock)
        await service.reset(accountEpoch: 1)
        let uri = "spotify:track:old-account"
        let updates = HarnessCounters()
        let refresh = Task {
            await service.refresh(
                fallbackEntries: [QueueEntry(uri: uri, provider: "connect")],
                currentTrackURI: "spotify:track:current", accountEpoch: 1, onUpdate: { _ in updates.record("update") })
        }
        defer { refresh.cancel(); _ = remote.failMetadata(for: uri); clock.releaseAll() }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        #expect(remote.completeMetadata(for: uri))
        try await requireEventually { clock.waiterCount == 1 }
        await service.reset(accountEpoch: 2)
        #expect(await refresh.value == nil)
        #expect(await waitUntil { clock.waiterCount == 0 })
        #expect(updates.count("update") == 1, "old metadata never publishes after reset")
    }

    @Test
    @MainActor
    func webFallbackRetainsAlreadyKnownConnectMetadata() async throws {
        let web = HarnessWebQueue(.park)
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(webQueue: web, metadata: TrackMetadataService(remote: remote))
        await service.reset(accountEpoch: 1)
        let context = "spotify:track:current"
        let known = "spotify:track:known"
        let missing = "spotify:track:missing"
        let first = Task {
            await service.refresh(fallbackEntries: [], currentTrackURI: context, accountEpoch: 1)
        }
        defer { first.cancel(); web.fail(); _ = remote.failMetadata(for: missing) }
        try await requireEventually { web.isParked }
        #expect(web.requestCount == 1)
        web.complete(with: [queueRefreshTrack(known)])
        _ = await first.value
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 2,
                trackURI: context,
                next: HarnessFixtures.queueTracks([
                    QueueEntry(uri: known, provider: "connect", occurrence: 0),
                    QueueEntry(uri: missing, provider: "connect", occurrence: 1),
                ])),
            accountEpoch: 1, fallbackTrackURI: nil)
        let second = Task {
            await service.refresh(fallbackEntries: [], currentTrackURI: context, accountEpoch: 1)
        }
        try await requireEventually { web.isParked }
        #expect(web.requestCount == 2)
        web.complete(with: [])
        try await requireEventually { remote.parkedMetadataURIs.contains(missing) }
        #expect(remote.requestedURIs == [missing])
        #expect(remote.completeMetadata(for: missing))
        let result = await second.value
        #expect(result?.entries.map(\.uri) == [known, missing])
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([known, missing]))
    }

    @Test
    @MainActor
    func changedFallbackReplacesTheSharedFlight() async throws {
        try await QueueResponseFixture().run { fixture in
            await fixture.service.reset(accountEpoch: 1)
            let oldURI = "spotify:track:old-fallback"
            let newURI = "spotify:track:new-fallback"
            let first = fixture.start(
                fallbackEntries: [QueueEntry(uri: oldURI, provider: "fallback", occurrence: 0)],
                cachedTracks: [queueRefreshTrack(oldURI)])
            let oldWorker = try await fixture.requireRequest(1)
            #expect(fixture.web.requestCount == 1)
            let second = fixture.start(
                fallbackEntries: [QueueEntry(uri: newURI, provider: "fallback", occurrence: 0)],
                cachedTracks: [queueRefreshTrack(newURI)])
            let replacementWorker = try await fixture.requireRequest(2)
            #expect(fixture.web.requestCount == 2)
            fixture.script.fail429(1)
            await oldWorker.value
            #expect(try await fixture.value(first) == nil)
            fixture.script.fail429(2)
            await replacementWorker.value
            let result = try await fixture.value(second)
            #expect(result?.entries.map(\.uri) == [newURI])
            #expect(result?.tracks.map(\.uri) == [newURI])
        }
    }

    @Test
    @MainActor
    func concurrentRefreshesJoinOneWebFlightAndPublishToBothSubscribers() async throws {
        try await QueueResponseFixture().run { fixture in
            await fixture.service.reset(accountEpoch: 1)
            let firstUpdates = HarnessCounters()
            let secondUpdates = HarnessCounters()
            let first = fixture.start(onUpdate: { _ in firstUpdates.record("update") })
            let worker = try await fixture.requireRequest(1)
            let second = fixture.start(onUpdate: { _ in secondUpdates.record("update") })
            try await requireEventually { await fixture.service.refreshSubscriberCount == 2 }
            #expect(fixture.web.requestCount == 1, "concurrent callers share one Web queue request")
            fixture.script.complete(1, with: [queueRefreshTrack("spotify:track:joined")])
            await worker.value
            #expect((try await fixture.value(first))?.entries.map(\.uri) == ["spotify:track:joined"])
            #expect((try await fixture.value(second))?.entries.map(\.uri) == ["spotify:track:joined"])
            #expect(firstUpdates.count("update") == 1)
            #expect(secondUpdates.count("update") == 1)
        }
    }

    @Test
    @MainActor
    func cancelledSubscriberCanRejoinWithoutCancellingSharedFlight() async throws {
        try await QueueResponseFixture().run { fixture in
            await fixture.service.reset(accountEpoch: 1)
            let cancelledUpdates = HarnessCounters()
            let cancelled = fixture.start(onUpdate: { _ in cancelledUpdates.record("update") })
            let worker = try await fixture.requireRequest(1)
            let joined = fixture.start()
            try await requireEventually { await fixture.service.refreshSubscriberCount == 2 }
            cancelled.cancel()
            #expect(
                try await fixture.value(cancelled) == nil, "cancellation settles while the Web request remains parked")
            try await requireEventually { await fixture.service.refreshSubscriberCount == 1 }
            #expect(fixture.script.pendingRequestIDs == [1], "one caller cannot cancel shared transport")
            #expect(fixture.web.requestCount == 1)
            fixture.script.complete(1, with: [queueRefreshTrack("spotify:track:rejoined")])
            await worker.value
            #expect((try await fixture.value(joined))?.entries.map(\.uri) == ["spotify:track:rejoined"])
            #expect(cancelledUpdates.count("update") == 0)
        }
    }

    @Test
    @MainActor
    func cancellingDuringPublicationDoesNotSkipOtherSubscribers() async throws {
        let web = HarnessWebQueue(.park)
        let remote = HarnessRemote(metadata: .park)
        let clock = HarnessClock.parked()
        let service = QueueService(
            webQueue: web, metadata: TrackMetadataService(remote: remote), clock: clock)
        await service.reset(accountEpoch: 1)
        let uri = "spotify:track:shared-hydration"
        let initialOrder = RuntimeCallbackRecorder<Int>()
        let metadataUpdates = RuntimeCallbackRecorder<Int>()
        let publication = HarnessResponseGate<Void>(cancellation: .ignored)
        let refreshes = (0..<3).map { subscriber in
            Task {
                await service.refresh(
                    fallbackEntries: [QueueEntry(uri: uri, provider: "connect")],
                    currentTrackURI: "spotify:track:current", accountEpoch: 1,
                    onUpdate: { snapshot in
                        if snapshot.tracks.isEmpty {
                            initialOrder.append(subscriber)
                        } else {
                            metadataUpdates.append(subscriber)
                            if subscriber == initialOrder.snapshot.first {
                                _ = try? await publication.wait()
                            }
                        }
                    })
            }
        }
        defer {
            refreshes.forEach { $0.cancel() }
            publication.close()
            web.fail()
            _ = remote.failMetadata(for: uri)
            clock.releaseAll()
        }
        try await requireEventually { await service.refreshSubscriberCount == 3 }
        try await requireEventually { web.isParked }
        web.fail()
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        let order = initialOrder.snapshot
        #expect(order.count == 3, "every subscriber sees initial ordering before hydration")
        let removed = try #require(order.dropFirst().first)
        #expect(remote.completeMetadata(for: uri))
        try await requireEventually { clock.waiterCount == 1 }
        clock.releaseAll()
        try await requireEventually { publication.waiterCount == 1 }

        // The dictionary has not changed between publications. Remove the next subscriber
        // while the first callback is suspended, leaving a later subscriber still waiting.
        refreshes[removed].cancel()
        try await requireEventually { await service.refreshSubscriberCount == 2 }
        publication.finish(())

        for (subscriber, refresh) in refreshes.enumerated() {
            let result = await refresh.value
            #expect((result != nil) == (subscriber != removed))
        }
        #expect(Set(metadataUpdates.snapshot) == Set(order).subtracting([removed]))
        #expect(web.requestCount == 1, "subscriber cancellation preserves the shared request")
    }

    @Test
    @MainActor
    func connectOrderingDuringHydrationAddsOnlyNewURIsAndKeepsOrder() async throws {
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: remote)
        )
        await service.reset(accountEpoch: 1)
        let a = "spotify:track:a"
        let b = "spotify:track:b"
        let c = "spotify:track:c"
        let initialEntries = [
            QueueEntry(uri: a, provider: "connect", occurrence: 0),
            QueueEntry(uri: a, provider: "connect", occurrence: 1),
            QueueEntry(uri: b, provider: "connect", occurrence: 2),
        ]
        let refresh = Task {
            await service.refresh(
                fallbackEntries: initialEntries,
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        defer {
            refresh.cancel()
            for uri in remote.parkedMetadataURIs { _ = remote.failMetadata(for: uri) }
        }
        try await requireEventually { remote.parkedMetadataURIs == Set([a, b]) }
        #expect(remote.requestedURIs.sorted() == [a, b], "duplicate fallback occurrences hydrate once")

        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                trackURI: "spotify:track:current",
                next: HarnessFixtures.queueTracks([
                    QueueEntry(uri: b, provider: "connect", occurrence: 0),
                    QueueEntry(uri: a, provider: "connect", occurrence: 1),
                    QueueEntry(uri: b, provider: "connect", occurrence: 2),
                    QueueEntry(uri: c, provider: "connect", occurrence: 3),
                ])),
            accountEpoch: 1, fallbackTrackURI: nil)
        #expect(remote.completeMetadata(for: a))
        #expect(remote.completeMetadata(for: b))
        try await requireEventually { remote.parkedMetadataURIs.contains(c) }
        #expect(remote.requestedURIs.filter { $0 == b }.count == 1)
        #expect(remote.completeMetadata(for: c))

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [b, a, b, c], "Connect remains authoritative for order")
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([a, b, c]))
        #expect(remote.requestedURIs.count == 3, "only the new Connect URI starts another lookup")
    }

    @Test
    @MainActor
    func connectOrderingArrivingDuringWebSuccessGetsHydratedBeforeFlightCompletes() async throws {
        let web = HarnessWebQueue(.park)
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: remote)
        )
        await service.reset(accountEpoch: 1)
        let refresh = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        defer { refresh.cancel(); web.fail(); _ = remote.failMetadata() }
        try await requireEventually { web.isParked }
        #expect(web.requestCount == 1)
        let connectURI = "spotify:track:connect-only"
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                trackURI: "spotify:track:current",
                next: HarnessFixtures.queueTracks([QueueEntry(uri: connectURI, provider: "connect", occurrence: 0)])),
            accountEpoch: 1, fallbackTrackURI: nil)
        web.complete(with: [queueRefreshTrack("spotify:track:web-only")])
        try await requireEventually { remote.parkedMetadataURIs.contains(connectURI) }
        #expect(remote.completeMetadata(for: connectURI))

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [connectURI])
        #expect(result?.tracks.map(\.uri) == [connectURI])
    }

    @Test
    @MainActor
    func resetAndContextChangeInvalidatePendingRefreshes() async throws {
        let web = HarnessWebQueue(.park)
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: HarnessRemote(metadata: .park))
        )
        await service.reset(accountEpoch: 1)

        let oldAccount = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-account",
                accountEpoch: 1
            )
        }
        defer { oldAccount.cancel(); web.fail() }
        try await requireEventually { web.isParked }
        #expect(web.requestCount == 1)
        await service.reset(accountEpoch: 2)
        #expect((await oldAccount.value) == nil, "reset invalidates the old account flight")

        let oldContext = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-context",
                accountEpoch: 2
            )
        }
        defer { oldContext.cancel() }
        try await requireEventually { web.isParked }
        #expect(web.requestCount == 2)
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                trackURI: "spotify:track:new-context"),
            accountEpoch: 2, fallbackTrackURI: nil)
        web.complete(with: [queueRefreshTrack("spotify:track:stale-context")])
        #expect((await oldContext.value) == nil, "a context change rejects the old flight result")
    }

    @Test(arguments: [false, true])
    @MainActor
    func staleWebFailureCannotSetCooldownForTheReplacementAccount(replacementPublishesFirst: Bool) async throws {
        try await QueueResponseFixture().run { fixture in
            await fixture.service.reset(accountEpoch: 1)
            let oldAccount = fixture.start(context: "spotify:track:old-account")
            let oldWorker = try await fixture.requireRequest(1)
            await fixture.service.reset(accountEpoch: 2)
            #expect(try await fixture.value(oldAccount) == nil)
            let replacement = fixture.start(accountEpoch: 2, context: "spotify:track:new-account")
            let replacementWorker = try await fixture.requireRequest(2)
            if replacementPublishesFirst {
                fixture.script.complete(2, with: [queueRefreshTrack("spotify:track:fresh")])
                await replacementWorker.value
            }
            fixture.script.fail429(1)
            // This is the actual worker task, whose end follows acceptWebResult and flight finish.
            // The cancelled old subscriber's completion cannot establish this ordering.
            await oldWorker.value
            if !replacementPublishesFirst {
                #expect(await fixture.service.refreshSubscriberCount == 1)
                fixture.script.complete(2, with: [queueRefreshTrack("spotify:track:fresh")])
                await replacementWorker.value
            }
            #expect((try await fixture.value(replacement))?.entries.map(\.uri) == ["spotify:track:fresh"])
            // A third refresh must reach transport despite the old 429. Its typed immediate
            // failure selects the ordinary empty fallback rather than parking another waiter.
            let publication = fixture.probePublication
            let probe = fixture.start(
                accountEpoch: 2, context: "spotify:track:new-account",
                onUpdate: { _ in _ = try? await publication.wait() })
            let probeWorker = try await fixture.requireProbeWorker()
            #expect(fixture.web.requestCount == 3, "a retired 429 cannot install replacement-account cooldown")
            publication.finish(())
            await probeWorker.value
            #expect(try await fixture.value(probe) != nil)
            #expect(fixture.script.pendingRequestIDs.isEmpty)
        }
    }
}

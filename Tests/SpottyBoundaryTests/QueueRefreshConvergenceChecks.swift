import Foundation
import Testing
import SpottyDomain
@testable import SpottyCore

/// Gates `HarnessWebQueue.onQueue` so a check can track multiple concurrent Web Player flights
/// independently and fail or complete each one by its own request id, mirroring the pre-harness
/// `QueueRefreshLateFailureWebQueue` actor. Unlike `HarnessWebQueue`'s built-in `.park` (a single
/// continuation slot), this keeps one continuation per in-flight request, and — like the actor it
/// replaces — installs no cancellation handler.
private actor LateFailureWebQueueGate {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<[CatalogTrack], any Error>] = [:]

    func next() async throws -> [CatalogTrack] {
        nextRequestID += 1
        let requestID = nextRequestID
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func fail429(_ requestID: Int) {
        continuations.removeValue(forKey: requestID)?.resume(
            throwing: SpotifyWebPlayerAPIError.requestFailed(429)
        )
    }

    func complete(_ requestID: Int, with tracks: [CatalogTrack]) {
        continuations.removeValue(forKey: requestID)?.resume(returning: tracks)
    }
}

/// A `HarnessWebQueue` whose requests are routed through a `LateFailureWebQueueGate`, so a check
/// can fail or complete concurrent flights independently by request id. `requestCount` still comes
/// from the harness queue itself.
private func makeLateFailureWebQueue() -> (webQueue: HarnessWebQueue, gate: LateFailureWebQueueGate) {
    let gate = LateFailureWebQueueGate()
    let webQueue = HarnessWebQueue()
    webQueue.onQueue = { [gate] in try await gate.next() }
    return (webQueue, gate)
}

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
        _ = await service.acceptConnect([a], accountEpoch: 1, sourceRevision: 1, contextURI: context)
        let hydrated = try #require(
            await service.refresh(
                fallbackEntries: [a],
                cachedTracks: [queueRefreshTrack(a.uri)], currentTrackURI: context, accountEpoch: 1))
        #expect(hydrated.revision >= 2, "metadata has advanced the presentation counter")
        let replacement = try #require(
            await service.acceptConnect(
                [b], accountEpoch: 1,
                sourceRevision: 2, contextURI: context))
        #expect(replacement.snapshot.entries.map(\.uri) == [b.uri])
        #expect(
            replacement.snapshot.revision > hydrated.revision,
            "fresh Connect ordering must pass the store's strict presentation revision gate")
        #expect(replacement.mutation.sourceRevision == 2, "the independent wire revision stays unchanged")
        let stale = try #require(
            await service.acceptConnect(
                [a], accountEpoch: 1,
                sourceRevision: 1, contextURI: context))
        #expect(stale.snapshot.entries.map(\.uri) == [b.uri])
        #expect(stale.snapshot.revision == replacement.snapshot.revision)
    }

    @Test
    @MainActor
    func metadataPublishesInBatchesAndFlushesWhileAnotherRequestIsStalled() async {
        let clock = CooperativeParkedClock()
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: remote), clock: clock)
        await service.reset(accountEpoch: 1)
        let uris = ["spotify:track:a", "spotify:track:b", "spotify:track:c"]
        var updates: [ProvenanceQueueSnapshot] = []
        let refresh = Task {
            await service.refresh(
                fallbackEntries: uris.enumerated().map {
                    QueueEntry(uri: $0.element, provider: "connect", occurrence: $0.offset)
                }, currentTrackURI: "spotify:track:current", accountEpoch: 1,
                onUpdate: { updates.append($0) })
        }
        #expect(await waitUntil { remote.requestedURIs.count == 3 })
        #expect(updates.count == 1, "order appears before enrichment")
        remote.completeMetadata(for: uris[0])
        remote.completeMetadata(for: uris[1])
        #expect(await waitUntil { await service.refreshDiagnostics.metadataResults == 2 })
        #expect(await waitUntil { clock.waiterCount == 1 })
        #expect(updates.count == 1, "a burst does not publish per track")
        clock.releaseAll()
        #expect(await waitUntil { updates.count == 2 })
        #expect(Set(updates.last?.tracks.map(\.uri) ?? []) == Set(uris.prefix(2)))
        remote.completeMetadata(for: uris[2])
        #expect(await waitUntil { await service.refreshDiagnostics.metadataResults == 3 })
        #expect(await waitUntil { clock.waiterCount == 1 })
        clock.releaseAll()
        let result = await refresh.value
        #expect(result?.tracks.count == 3)
        #expect(updates.count == 3)
        #expect(clock.requestedSleeps == [0.05, 0.05])
    }

    @Test
    @MainActor
    func accountReplacementCancelsAnUnpublishedMetadataBatch() async {
        let clock = CooperativeParkedClock()
        let remote = HarnessRemote(metadata: .park)
        let service = QueueService(
            webQueue: HarnessWebQueue(.unavailable),
            metadata: TrackMetadataService(remote: remote), clock: clock)
        await service.reset(accountEpoch: 1)
        let uri = "spotify:track:old-account"
        var updates = 0
        let refresh = Task {
            await service.refresh(
                fallbackEntries: [QueueEntry(uri: uri, provider: "connect")],
                currentTrackURI: "spotify:track:current", accountEpoch: 1, onUpdate: { _ in updates += 1 })
        }
        #expect(await waitUntil { remote.requestedURIs.count == 1 })
        remote.completeMetadata(for: uri)
        #expect(await waitUntil { clock.waiterCount == 1 })
        await service.reset(accountEpoch: 2)
        #expect(await refresh.value == nil)
        #expect(await waitUntil { clock.waiterCount == 0 })
        #expect(updates == 1, "old metadata never publishes after reset")
    }

    @Test
    @MainActor
    func webFallbackRetainsAlreadyKnownConnectMetadata() async {
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
        #expect(await waitUntil { web.requestCount == 1 })
        web.complete(with: [queueRefreshTrack(known)])
        _ = await first.value
        _ = await service.acceptConnect(
            [
                QueueEntry(uri: known, provider: "connect", occurrence: 0),
                QueueEntry(uri: missing, provider: "connect", occurrence: 1),
            ],
            accountEpoch: 1, sourceRevision: 2, contextURI: context
        )
        let second = Task {
            await service.refresh(fallbackEntries: [], currentTrackURI: context, accountEpoch: 1)
        }
        #expect(await waitUntil { web.requestCount == 2 })
        web.complete(with: [])
        #expect(await waitUntil { remote.requestedURIs.contains(missing) })
        #expect(remote.requestedURIs == [missing])
        remote.completeMetadata(for: missing)
        let result = await second.value
        #expect(result?.entries.map(\.uri) == [known, missing])
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([known, missing]))
    }

    @Test
    @MainActor
    func changedFallbackReplacesTheSharedFlight() async {
        let (web, gate) = makeLateFailureWebQueue()
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: HarnessRemote(metadata: .park))
        )
        await service.reset(accountEpoch: 1)
        let oldURI = "spotify:track:old-fallback"
        let newURI = "spotify:track:new-fallback"
        let first = Task {
            await service.refresh(
                fallbackEntries: [QueueEntry(uri: oldURI, provider: "fallback", occurrence: 0)],
                cachedTracks: [queueRefreshTrack(oldURI)],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        #expect(await waitUntil { web.requestCount == 1 })
        let second = Task {
            await service.refresh(
                fallbackEntries: [QueueEntry(uri: newURI, provider: "fallback", occurrence: 0)],
                cachedTracks: [queueRefreshTrack(newURI)],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        #expect(await waitUntil { web.requestCount == 2 })
        await gate.fail429(1)
        #expect(await first.value == nil)
        await gate.fail429(2)
        let result = await second.value
        #expect(result?.entries.map(\.uri) == [newURI])
        #expect(result?.tracks.map(\.uri) == [newURI])
    }

    @Test
    @MainActor
    func concurrentRefreshesJoinOneWebFlightAndPublishToBothSubscribers() async {
        let web = HarnessWebQueue(.park)
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: HarnessRemote(metadata: .park))
        )
        await service.reset(accountEpoch: 1)

        var firstUpdates = 0
        var secondUpdates = 0
        let first = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1,
                onUpdate: { _ in firstUpdates += 1 }
            )
        }
        #expect(await waitUntil { web.requestCount == 1 })
        let second = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1,
                onUpdate: { _ in secondUpdates += 1 }
            )
        }
        #expect(await waitUntil { await service.refreshSubscriberCount == 2 })
        #expect((web.requestCount) == 1, "concurrent callers share one Web queue request")

        web.complete(with: [queueRefreshTrack("spotify:track:joined")])
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult?.entries.map(\.uri) == ["spotify:track:joined"])
        #expect(secondResult?.entries.map(\.uri) == ["spotify:track:joined"])
        #expect(firstUpdates == 1, "the first subscriber receives the shared publication")
        #expect(secondUpdates == 1, "the joining subscriber receives the shared publication")
    }

    @Test
    @MainActor
    func cancelledSubscriberCanRejoinWithoutCancellingSharedFlight() async {
        let web = HarnessWebQueue(.park)
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: HarnessRemote(metadata: .park))
        )
        await service.reset(accountEpoch: 1)

        var cancelledUpdates = 0
        var cancelledSettled = false
        let cancelled = Task {
            let result = await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1,
                onUpdate: { _ in cancelledUpdates += 1 }
            )
            cancelledSettled = true
            return result
        }
        #expect(await waitUntil { web.requestCount == 1 })
        let joined = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        #expect(await waitUntil { await service.refreshSubscriberCount == 2 })
        cancelled.cancel()
        #expect(await waitUntil { cancelledSettled }, "cancellation settles before the shared Web request finishes")
        #expect(await waitUntil { await service.refreshSubscriberCount == 1 })

        #expect((web.requestCount) == 1, "rejoin does not start a duplicate Web request")
        web.complete(with: [queueRefreshTrack("spotify:track:rejoined")])
        #expect((await cancelled.value) == nil, "the cancelled caller cannot adopt the result")
        #expect((await joined.value)?.entries.map(\.uri) == ["spotify:track:rejoined"])
        #expect(cancelledUpdates == 0, "a removed subscriber cannot publish after an await")
    }

    @Test
    @MainActor
    func connectOrderingDuringHydrationAddsOnlyNewURIsAndKeepsOrder() async {
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
        #expect(await waitUntil { remote.requestedURIs.count == 2 })
        #expect(remote.requestedURIs.sorted() == [a, b], "duplicate fallback occurrences hydrate once")

        _ = await service.acceptConnect(
            [
                QueueEntry(uri: b, provider: "connect", occurrence: 0),
                QueueEntry(uri: a, provider: "connect", occurrence: 1),
                QueueEntry(uri: b, provider: "connect", occurrence: 2),
                QueueEntry(uri: c, provider: "connect", occurrence: 3),
            ],
            accountEpoch: 1,
            sourceRevision: 1,
            contextURI: "spotify:track:current"
        )
        remote.completeMetadata(for: a)
        remote.completeMetadata(for: b)
        #expect(await waitUntil { remote.requestedURIs.contains(c) })
        #expect(remote.requestedURIs.filter { $0 == b }.count == 1)
        remote.completeMetadata(for: c)

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [b, a, b, c], "Connect remains authoritative for order")
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([a, b, c]))
        #expect(remote.requestedURIs.count == 3, "only the new Connect URI starts another lookup")
    }

    @Test
    @MainActor
    func connectOrderingArrivingDuringWebSuccessGetsHydratedBeforeFlightCompletes() async {
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
        #expect(await waitUntil { web.requestCount == 1 })
        let connectURI = "spotify:track:connect-only"
        _ = await service.acceptConnect(
            [QueueEntry(uri: connectURI, provider: "connect", occurrence: 0)],
            accountEpoch: 1,
            sourceRevision: 1,
            contextURI: "spotify:track:current"
        )
        web.complete(with: [queueRefreshTrack("spotify:track:web-only")])
        #expect(await waitUntil { remote.requestedURIs.contains(connectURI) })
        remote.completeMetadata(for: connectURI)

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [connectURI])
        #expect(result?.tracks.map(\.uri) == [connectURI])
    }

    @Test
    @MainActor
    func resetAndContextChangeInvalidatePendingRefreshes() async {
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
        #expect(await waitUntil { web.requestCount == 1 })
        await service.reset(accountEpoch: 2)
        #expect((await oldAccount.value) == nil, "reset invalidates the old account flight")

        let oldContext = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-context",
                accountEpoch: 2
            )
        }
        #expect(await waitUntil { web.requestCount == 2 })
        _ = await service.acceptConnect(
            [],
            accountEpoch: 2,
            sourceRevision: 1,
            contextURI: "spotify:track:new-context"
        )
        web.complete(with: [queueRefreshTrack("spotify:track:stale-context")])
        #expect((await oldContext.value) == nil, "a context change rejects the old flight result")
    }

    @Test
    @MainActor
    func staleWebFailureCannotSetCooldownForTheReplacementAccount() async {
        let (web, gate) = makeLateFailureWebQueue()
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
        #expect(await waitUntil { web.requestCount == 1 })
        await service.reset(accountEpoch: 2)
        await gate.fail429(1)
        #expect((await oldAccount.value) == nil)

        let replacement = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:new-account",
                accountEpoch: 2
            )
        }
        #expect(await waitUntil { web.requestCount == 2 }, "the replacement account probes Web again")
        await gate.complete(2, with: [queueRefreshTrack("spotify:track:fresh")])
        #expect((await replacement.value)?.entries.map(\.uri) == ["spotify:track:fresh"])
    }
}

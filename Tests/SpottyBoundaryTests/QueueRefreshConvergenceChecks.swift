import Foundation
import Testing
import SpottyDomain
@testable import SpottyCore

private actor QueueRefreshWebQueue: WebQueueClient {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<[CatalogTrack], any Error>] = [:]
    private(set) var requestCount = 0

    func queue() async throws -> [CatalogTrack] {
        nextRequestID += 1
        let requestID = nextRequestID
        requestCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
    }

    func complete(_ requestID: Int, with tracks: [CatalogTrack]) {
        continuations.removeValue(forKey: requestID)?.resume(returning: tracks)
    }

    private func cancel(_ requestID: Int) {
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }
}

private actor QueueRefreshMetadataRemote: RemotePlaybackClient {
    private var continuations: [String: [CheckedContinuation<SpotifyConnectTrackMetadata, any Error>]] = [:]
    private(set) var requestedURIs: [String] = []

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        requestedURIs.append(uri)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[uri, default: []].append(continuation)
            }
        } onCancel: {
            Task { await self.cancel(uri) }
        }
    }

    func completeAll(_ uri: String) {
        let pending = continuations.removeValue(forKey: uri) ?? []
        for continuation in pending {
            continuation.resume(
                returning: SpotifyConnectTrackMetadata(
                    uri: uri,
                    title: "Title \(uri)",
                    artist: "Artist",
                    artworkURL: nil,
                    duration: 180
                )
            )
        }
    }

    private func cancel(_ uri: String) {
        guard var pending = continuations[uri], !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if pending.isEmpty {
            continuations.removeValue(forKey: uri)
        } else {
            continuations[uri] = pending
        }
        continuation.resume(throwing: CancellationError())
    }
}

private actor QueueRefreshFailingWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private actor QueueRefreshLateFailureWebQueue: WebQueueClient {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<[CatalogTrack], any Error>] = [:]
    private(set) var requestCount = 0

    func queue() async throws -> [CatalogTrack] {
        nextRequestID += 1
        let requestID = nextRequestID
        requestCount += 1
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
    func concurrentRefreshesJoinOneWebFlightAndPublishToBothSubscribers() async {
        let web = QueueRefreshWebQueue()
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: QueueRefreshMetadataRemote())
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
        #expect(await waitUntil { await web.requestCount == 1 })
        let second = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1,
                onUpdate: { _ in secondUpdates += 1 }
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect((await web.requestCount) == 1, "concurrent callers share one Web queue request")

        await web.complete(1, with: [queueRefreshTrack("spotify:track:joined")])
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
        let web = QueueRefreshWebQueue()
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: QueueRefreshMetadataRemote())
        )
        await service.reset(accountEpoch: 1)

        var cancelledUpdates = 0
        let cancelled = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1,
                onUpdate: { _ in cancelledUpdates += 1 }
            )
        }
        #expect(await waitUntil { await web.requestCount == 1 })
        let joined = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 1
            )
        }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        for _ in 0..<10 { await Task.yield() }

        #expect((await web.requestCount) == 1, "rejoin does not start a duplicate Web request")
        await web.complete(1, with: [queueRefreshTrack("spotify:track:rejoined")])
        #expect((await cancelled.value) == nil, "the cancelled caller cannot adopt the result")
        #expect((await joined.value)?.entries.map(\.uri) == ["spotify:track:rejoined"])
        #expect(cancelledUpdates == 0, "a removed subscriber cannot publish after an await")
    }

    @Test
    @MainActor
    func connectOrderingDuringHydrationAddsOnlyNewURIsAndKeepsOrder() async {
        let remote = QueueRefreshMetadataRemote()
        let service = QueueService(
            webQueue: QueueRefreshFailingWebQueue(),
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
        #expect(await waitUntil { await remote.requestedURIs.count == 2 })
        #expect((await remote.requestedURIs).sorted() == [a, b], "duplicate fallback occurrences hydrate once")

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
        await remote.completeAll(a)
        await remote.completeAll(b)
        #expect(await waitUntil { await remote.requestedURIs.contains(c) })
        #expect((await remote.requestedURIs).filter { $0 == b }.count == 1)
        await remote.completeAll(c)

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [b, a, b, c], "Connect remains authoritative for order")
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([a, b, c]))
        #expect((await remote.requestedURIs).count == 3, "only the new Connect URI starts another lookup")
    }

    @Test
    @MainActor
    func connectOrderingArrivingDuringWebSuccessGetsHydratedBeforeFlightCompletes() async {
        let web = QueueRefreshWebQueue()
        let remote = QueueRefreshMetadataRemote()
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
        #expect(await waitUntil { await web.requestCount == 1 })
        let connectURI = "spotify:track:connect-only"
        _ = await service.acceptConnect(
            [QueueEntry(uri: connectURI, provider: "connect", occurrence: 0)],
            accountEpoch: 1,
            sourceRevision: 1,
            contextURI: "spotify:track:current"
        )
        await web.complete(1, with: [queueRefreshTrack("spotify:track:web-only")])
        #expect(await waitUntil { await remote.requestedURIs.contains(connectURI) })
        await remote.completeAll(connectURI)

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [connectURI])
        #expect(result?.tracks.map(\.uri) == [connectURI])
    }

    @Test
    @MainActor
    func resetAndContextChangeInvalidatePendingRefreshes() async {
        let web = QueueRefreshWebQueue()
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: QueueRefreshMetadataRemote())
        )
        await service.reset(accountEpoch: 1)

        let oldAccount = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-account",
                accountEpoch: 1
            )
        }
        #expect(await waitUntil { await web.requestCount == 1 })
        await service.reset(accountEpoch: 2)
        #expect((await oldAccount.value) == nil, "reset invalidates the old account flight")

        let oldContext = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-context",
                accountEpoch: 2
            )
        }
        #expect(await waitUntil { await web.requestCount == 2 })
        _ = await service.acceptConnect(
            [],
            accountEpoch: 2,
            sourceRevision: 1,
            contextURI: "spotify:track:new-context"
        )
        await web.complete(2, with: [queueRefreshTrack("spotify:track:stale-context")])
        #expect((await oldContext.value) == nil, "a context change rejects the old flight result")
    }

    @Test
    @MainActor
    func staleWebFailureCannotSetCooldownForTheReplacementAccount() async {
        let web = QueueRefreshLateFailureWebQueue()
        let service = QueueService(
            webQueue: web,
            metadata: TrackMetadataService(remote: QueueRefreshMetadataRemote())
        )
        await service.reset(accountEpoch: 1)
        let oldAccount = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old-account",
                accountEpoch: 1
            )
        }
        #expect(await waitUntil { await web.requestCount == 1 })
        await service.reset(accountEpoch: 2)
        await web.fail429(1)
        #expect((await oldAccount.value) == nil)

        let replacement = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:new-account",
                accountEpoch: 2
            )
        }
        #expect(await waitUntil { await web.requestCount == 2 }, "the replacement account probes Web again")
        await web.complete(2, with: [queueRefreshTrack("spotify:track:fresh")])
        #expect((await replacement.value)?.entries.map(\.uri) == ["spotify:track:fresh"])
    }
}

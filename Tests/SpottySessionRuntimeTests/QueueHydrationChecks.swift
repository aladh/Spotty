@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@MainActor
struct QueueHydrationTests {
    @Test func hydrationBoundsConcurrencyAndWaitsForTheFinalBatch() async throws {
        let uris = (0..<9).map { "spotify:track:\($0)" }
        let gates = Dictionary(
            uniqueKeysWithValues: uris.map { ($0, HarnessResponseGate<SpotifyConnectTrackMetadata>()) })
        let web = HarnessResponseGate<[CatalogTrack]>()
        let clock = HarnessClock.parked()
        defer { web.close(); gates.values.forEach { $0.close() }; clock.releaseAll() }
        web.resolve(.failure(WebQueueFailure.requestFailed(403)))
        let calls = HarnessCounters()
        let service = QueueService(
            webQueue: GatedQueue(responses: web),
            metadata: TrackMetadataService(
                remote: MetadataResponses { uri in
                    calls.record("active")
                    defer { calls.adjust("active", by: -1) }
                    #expect(calls.count("active") <= 8)
                    return try await #require(gates[uri]).wait()
                }), clock: clock)
        await service.reset(accountEpoch: 1)
        let entries = Self.entries(uris)
        let refresh = Task {
            defer { calls.record("completed") }
            return await service.refresh(
                fallbackEntries: entries, currentTrackURI: nil, accountEpoch: 1,
                onUpdate: { _ in calls.record("publication") })
        }
        defer { refresh.cancel() }
        try await requireEventually { uris.prefix(8).allSatisfy { gates[$0]?.waiterCount == 1 } }
        #expect(gates[uris[8]]?.requestCount == 0)
        gates[uris[0]]?.finish(Self.metadata(uris[0]))
        try await requireEventually { gates[uris[8]]?.waiterCount == 1 }
        for uri in uris.dropFirst() { gates[uri]?.finish(Self.metadata(uri)) }
        try await requireEventually { await service.refreshDiagnostics.metadataResults == uris.count }
        try await requireEventually { clock.waiterCount == 1 }
        #expect(calls.count("completed") == 0)
        #expect(calls.count("publication") == 1)
        clock.releaseAll()
        let result = await refresh.value
        #expect(result?.entries == entries)
        #expect(result?.tracks.count == uris.count)
        #expect(calls.count("publication") == 2)
        #expect(gates.values.allSatisfy { $0.requestCount == 1 })
    }

    @Test func provisionalEmptyOrderingCannotEraseTheAcceptedHydrationBaseline() async throws {
        let web = HarnessResponseGate<[CatalogTrack]>()
        let metadata = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { web.close(); metadata.close() }
        web.resolve(.failure(WebQueueFailure.requestFailed(403)))
        let service = QueueService(
            webQueue: GatedQueue(responses: web),
            metadata: TrackMetadataService(remote: MetadataResponses { _ in try await metadata.wait() }),
            clock: HarnessClock.advancing())
        await service.reset(accountEpoch: 1)
        let uri = "spotify:track:accepted"
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                next: HarnessFixtures.queueTracks(Self.entries([uri]))),
            accountEpoch: 1, fallbackTrackURI: nil)
        let refresh = Task { await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1) }
        defer { refresh.cancel() }
        try await requireEventually { metadata.waiterCount == 1 }
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(revision: 2),
            accountEpoch: 1, fallbackTrackURI: nil)
        metadata.finish(Self.metadata(uri))
        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [uri])
        #expect(result?.entries.map(\.uid) == ["uid-0"])
        #expect(result?.tracks.map(\.uri) == [uri])
    }

    @Test(arguments: [false, true])
    func orderingArrivingDuringInitialPublicationStillHydrates(webAvailable: Bool) async throws {
        let web = HarnessResponseGate<[CatalogTrack]>()
        let publication = HarnessResponseGate<Void>()
        let metadata = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { web.close(); publication.close(); metadata.close() }
        if webAvailable { web.finish([]) } else { web.resolve(.failure(WebQueueFailure.requestFailed(403))) }
        let uri = "spotify:track:arrived"
        metadata.finish(Self.metadata(uri))
        let calls = HarnessCounters()
        let service = QueueService(
            webQueue: GatedQueue(responses: web),
            metadata: TrackMetadataService(remote: MetadataResponses { _ in try await metadata.wait() }),
            clock: HarnessClock.advancing())
        await service.reset(accountEpoch: 1)
        let refresh = Task {
            defer { calls.record("completed") }
            return await service.refresh(
                fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1,
                onUpdate: { _ in
                    calls.record("publication")
                    if calls.count("publication") == 1 { _ = try? await publication.wait() }
                })
        }
        defer { refresh.cancel() }
        try await requireEventually { publication.waiterCount == 1 }
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                next: HarnessFixtures.queueTracks(Self.entries([uri, uri]))),
            accountEpoch: 1, fallbackTrackURI: nil)
        publication.finish(())
        try await requireEventually { calls.count("completed") == 1 }
        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [uri, uri])
        #expect(result?.entries.map(\.uid) == ["uid-0", "uid-1"])
        #expect(result?.tracks.map(\.uri) == [uri])
        #expect(metadata.requestCount == 1)
    }

    @Test
    func repeatedOrderingDoesNotHideNewTracksInLaterObservations() async throws {
        let a = "spotify:track:a", b = "spotify:track:b", c = "spotify:track:c"
        let gates = [a, b, c].reduce(into: [:]) { $0[$1] = HarnessResponseGate<SpotifyConnectTrackMetadata>() }
        let web = HarnessResponseGate<[CatalogTrack]>()
        web.resolve(.failure(WebQueueFailure.requestFailed(403)))
        let clock = HarnessClock.parked()
        defer { web.close(); gates.values.forEach { $0.close() }; clock.releaseAll() }
        let service = QueueService(
            webQueue: GatedQueue(responses: web),
            metadata: TrackMetadataService(
                remote: MetadataResponses { uri in
                    let gate = try #require(gates[uri])
                    return try await gate.wait()
                }),
            clock: clock)
        let context = "spotify:track:current"
        await service.reset(accountEpoch: 1)
        let initial = Self.entries([a, a, b])
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                trackURI: context,
                next: HarnessFixtures.queueTracks(initial)),
            accountEpoch: 1, fallbackTrackURI: nil)
        let refresh = Task {
            await service.refresh(fallbackEntries: initial, currentTrackURI: context, accountEpoch: 1)
        }
        defer { refresh.cancel() }
        try await requireEventually { gates[a]?.waiterCount == 1 && gates[b]?.waiterCount == 1 }

        // Identical ordering arrives at a newer wire revision while hydration is suspended.
        // A later observation must still schedule new URIs and retain duplicate occurrences.
        let repeated = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 2,
                    trackURI: context,
                    next: HarnessFixtures.queueTracks(Self.entries([a, a, b]))),
                accountEpoch: 1, fallbackTrackURI: nil))
        gates[a]?.finish(Self.metadata(a))
        try await requireEventually { await service.refreshDiagnostics.metadataResults == 1 }
        _ = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: repeated.mutation.sourceRevision + 1,
                trackURI: context,
                next: HarnessFixtures.queueTracks(Self.entries([b, a, b, c]))),
            accountEpoch: 1, fallbackTrackURI: nil)
        gates[b]?.finish(Self.metadata(b))
        try await requireEventually { gates[c]?.waiterCount == 1 }
        gates[c]?.finish(Self.metadata(c))
        try await requireEventually { await service.refreshDiagnostics.metadataResults == 3 }
        try await requireEventually { clock.waiterCount == 1 }
        clock.releaseAll()

        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [b, a, b, c])
        #expect(result?.entries.map(\.uid) == ["uid-0", "uid-1", "uid-2", "uid-3"])
        #expect(Set(result?.tracks.map(\.uri) ?? []) == Set([a, b, c]))
        #expect(gates.values.allSatisfy { $0.requestCount == 1 })
    }

    private static func entries(_ uris: [String]) -> [QueueEntry] {
        uris.enumerated().map {
            QueueEntry(uri: $0.element, provider: "connect", occurrence: $0.offset, uid: "uid-\($0.offset)")
        }
    }

    private static func metadata(_ uri: String) -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(uri: uri, title: "Track", artist: "Artist", artworkURL: nil, duration: 180)
    }
}

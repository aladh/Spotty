import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@MainActor
struct TrackMetadataServiceTests {
    @Test func cancelledConsumerSettlesBeforeAnUncooperativeFetch() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        defer { responses.close() }
        let completed = HarnessCounters()
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        let consumer = await startMetadata(service, completed: completed)
        defer { consumer.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        consumer.cancel()
        try await requireEventually(description: "caller cancellation settles independently of remote completion") {
            completed.count("consumer") == 1
        }
        #expect(await consumer.value == nil)
        #expect(responses.waiterCount == 1, "the dependency has not acknowledged cancellation or replied")
    }

    @Test func cancellingOneConsumerPreservesItsSiblingAndTheSharedCache() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { responses.close() }
        let completed = HarnessCounters()
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        let first = await startMetadata(service, completed: completed, name: "first")
        let sibling = await startMetadata(service, completed: completed, name: "sibling")
        defer { first.cancel(); sibling.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        first.cancel()
        try await requireEventually { completed.count("first") == 1 }
        #expect(await first.value == nil)
        #expect(completed.count("sibling") == 0)
        #expect(responses.requestCount == 1)
        #expect(responses.waiterCount == 1, "a sibling still owns the cooperative fetch")
        responses.finish(metadataValue())
        #expect(await sibling.value?.title == "Current")
        #expect(try await service.metadata(for: metadataURI).title == "Current")
        #expect(responses.requestCount == 1)
    }

    @Test func cancellingTheLastConsumerCancelsCooperativeWorkAndAllowsRetry() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { responses.close() }
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        let cancelled = await startMetadata(service)
        defer { cancelled.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        cancelled.cancel()
        try await requireEventually { responses.waiterCount == 0 }
        #expect(await cancelled.value == nil)
        let replacement = await startMetadata(service)
        defer { replacement.cancel() }
        try await requireEventually { responses.waiterCount == 1 && responses.requestCount == 2 }
        responses.finish(metadataValue())
        #expect(await replacement.value?.title == "Current")
    }

    @Test(arguments: [false, true])
    func preCancelledConsumerDoesNotFetchOrReceiveCachedMetadata(primeCache: Bool) async throws {
        let calls = HarnessCounters()
        let service = TrackMetadataService(
            remote: MetadataResponses { uri in
                calls.record("fetch")
                return metadataValue(uri: uri)
            })
        if primeCache { _ = try await service.metadata(for: metadataURI) }
        let cancelled = Task { try? await service.metadata(for: metadataURI) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(calls.count("fetch") == (primeCache ? 1 : 0))
    }

    @Test(arguments: [false, true], [false, true])
    func retiredResponsesCannotCompleteOrEvictTheirReplacement(reset: Bool, failOld: Bool) async throws {
        let oldResponses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        let newResponses = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { oldResponses.close(); newResponses.close() }
        let completed = HarnessCounters()
        let service = TrackMetadataService(
            remote: MetadataResponses { _ in
                if oldResponses.requestCount == 0 { return try await oldResponses.wait() }
                return try await newResponses.wait()
            })
        let old = await startMetadata(service, completed: completed, name: "old")
        defer { old.cancel() }
        try await requireEventually { oldResponses.waiterCount == 1 }
        if reset { await service.reset() } else { old.cancel() }
        try await requireEventually { completed.count("old") == 1 }
        #expect(await old.value == nil, "retirement settles the caller before a late response")
        let replacement = await startMetadata(service, completed: completed, name: "replacement")
        defer { replacement.cancel() }
        try await requireEventually { newResponses.waiterCount == 1 }
        if failOld {
            oldResponses.resolve(.failure(MetadataFailure.unavailable))
        } else {
            oldResponses.finish(metadataValue(title: "Retired"))
        }
        let sibling = await startMetadata(service, completed: completed, name: "sibling")
        defer { sibling.cancel() }
        #expect(completed.count("replacement") == 0)
        newResponses.finish(metadataValue())
        try await requireEventually { completed.count("replacement") == 1 && completed.count("sibling") == 1 }
        try #require(await replacement.value?.title == "Current")
        try #require(await sibling.value?.title == "Current")
        newResponses.finish(metadataValue(title: "Unexpected cache miss"))
        #expect(try await service.metadata(for: metadataURI).title == "Current")
        #expect(newResponses.requestCount == 1)
    }

    @Test func resetSettlesAllWaitersAndClearsCachedValues() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        defer { responses.close() }
        responses.finish(metadataValue())
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        _ = try await service.metadata(for: metadataURI)
        let completed = HarnessCounters()
        let first = await startMetadata(service, uri: "spotify:track:other", completed: completed)
        let second = await startMetadata(service, uri: "spotify:track:other", completed: completed)
        defer { first.cancel(); second.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        await service.reset()
        try await requireEventually { completed.count("consumer") == 2 }
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        let replacement = await startMetadata(service)
        defer { replacement.cancel() }
        try await requireEventually { responses.waiterCount == 2 }
        responses.finish(metadataValue(title: "Retired"))
        responses.finish(metadataValue(title: "Replacement"))
        #expect(await replacement.value?.title == "Replacement")
        #expect(try await service.metadata(for: metadataURI).title == "Replacement")
    }

    @Test func failedFetchIsSharedWithoutPoisoningARetry() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { responses.close() }
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        let first = await startMetadata(service)
        let second = await startMetadata(service)
        defer { first.cancel(); second.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        responses.resolve(.failure(MetadataFailure.unavailable))
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(responses.requestCount == 1)
        responses.finish(metadataValue())
        #expect(try await service.metadata(for: metadataURI).title == "Current")
        #expect(responses.requestCount == 2)
    }

    @Test func aParkedURIAllowsUnrelatedLookupsAndTheCacheStaysBounded() async throws {
        let parked = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        defer { parked.close() }
        let calls = HarnessCounters()
        let service = TrackMetadataService(
            remote: MetadataResponses { uri in
                if uri == metadataURI { return try await parked.wait() }
                calls.record("fetch")
                return metadataValue(uri: uri)
            })
        let consumer = await startMetadata(service)
        defer { consumer.cancel() }
        try await requireEventually { parked.waiterCount == 1 }
        for index in 0..<512 { _ = try await service.metadata(for: "spotify:track:\(index)") }
        for index in 0..<512 { _ = try await service.metadata(for: "spotify:track:\(index)") }
        #expect(calls.count("fetch") == 512, "every entry fits before the eviction boundary")
        _ = try await service.metadata(for: "spotify:track:512")
        #expect(calls.count("fetch") == 513)
        _ = try await service.metadata(for: "spotify:track:512")
        #expect(calls.count("fetch") == 513, "the last inserted value is retained")
        for index in 0..<513 { _ = try await service.metadata(for: "spotify:track:\(index)") }
        #expect(calls.count("fetch") > 513, "at least one value was evicted from the bounded cache")
        #expect(parked.waiterCount == 1)
    }

    @Test func cancelledCallsReleaseTheirOwnerWhileRemoteWorkRemainsParked() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        defer { responses.close() }
        weak var released: TrackMetadataService?
        let completed = HarnessCounters()
        do {
            let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
            released = service
            let consumer = await startMetadata(service, completed: completed)
            defer { consumer.cancel() }
            try await requireEventually { responses.waiterCount == 1 }
            consumer.cancel()
            try await requireEventually { completed.count("consumer") == 1 }
            #expect(await consumer.value == nil)
        }
        try await requireEventually { released == nil }
        #expect(responses.waiterCount == 1)
    }

    @Test func cancellationSettlesStructuredChildrenBeforeTheRemoteResponds() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        defer { responses.close() }
        let completed = HarnessCounters()
        let service = TrackMetadataService(remote: MetadataResponses { _ in try await responses.wait() })
        let group = Task {
            defer { completed.record("group") }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try? await service.metadata(for: metadataURI) }
                }
            }
        }
        defer { group.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        group.cancel()
        try await requireEventually { completed.count("group") == 1 }
        #expect(responses.waiterCount == 1)
        await group.value
    }
}

private let metadataURI = "spotify:track:metadata"

private func metadataValue(uri: String = metadataURI, title: String = "Current") -> SpotifyConnectTrackMetadata {
    SpotifyConnectTrackMetadata(uri: uri, title: title, artist: "Artist", artworkURL: nil, duration: 180)
}

// Immediate tasks inherit this actor and register through the first suspension before returning.
// Tests can admit shared callers deterministically without exposing the service's waiter storage.
private func startMetadata(
    _ service: isolated TrackMetadataService, uri: String = metadataURI,
    completed: HarnessCounters = HarnessCounters(), name: String = "consumer"
) -> Task<SpotifyConnectTrackMetadata?, Never> {
    Task.immediate {
        defer { completed.record(name) }
        return try? await service.metadata(for: uri)
    }
}

private enum MetadataFailure: Error { case unavailable }

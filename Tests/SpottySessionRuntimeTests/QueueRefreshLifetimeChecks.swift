import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@MainActor
struct QueueRefreshLifetimeTests {
    enum SuspendedPhase: CaseIterable { case web, metadata, timer, callback }

    @Test(arguments: SuspendedPhase.allCases)
    func detachedWorkDoesNotRetainItsDiscardedOwner(_ phase: SuspendedPhase) async throws {
        let web = HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored)
        let metadata = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        let callback = HarnessResponseGate<Void>(cancellation: .ignored)
        let clock = HarnessClock(sleep: .uncooperativelyParked)
        defer { web.close(); metadata.close(); callback.close(); clock.releaseAll() }
        let completed = HarnessCounters()
        weak var released: QueueService?
        do {
            let service = QueueService(
                webQueue: GatedQueue(responses: web),
                metadata: TrackMetadataService(remote: MetadataResponses { _ in try await metadata.wait() }),
                clock: clock)
            released = service
            await service.reset(accountEpoch: 1)
            let entries: [QueueEntry]
            switch phase {
            case .web, .callback: entries = []
            case .metadata, .timer:
                entries = [QueueEntry(uri: "spotify:track:queued", provider: "connect")]
                web.resolve(.failure(WebQueueFailure.requestFailed(403)))
            }
            if phase == .callback { web.finish([]) }
            if phase == .timer {
                metadata.finish(
                    SpotifyConnectTrackMetadata(
                        uri: "spotify:track:queued", title: "Queued", artist: "Artist", artworkURL: nil, duration: 180))
            }
            let caller = Task {
                defer { completed.record("caller") }
                return await service.refresh(
                    fallbackEntries: entries, currentTrackURI: nil, accountEpoch: 1,
                    onUpdate: { _ in if phase == .callback { _ = try? await callback.wait() } })
            }
            defer { caller.cancel() }
            try await requireEventually {
                switch phase {
                case .web: web.waiterCount == 1
                case .metadata: metadata.waiterCount == 1
                case .timer: clock.waiterCount == 1
                case .callback: callback.waiterCount == 1
                }
            }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            #expect(await caller.value == nil)
            #expect(await service.refreshSubscriberCount == 0)
        }
        try await requireEventually { released == nil }
        switch phase {
        case .web: #expect(web.waiterCount == 1)
        case .metadata: #expect(metadata.waiterCount == 1)
        case .timer: #expect(clock.waiterCount == 1)
        case .callback: #expect(callback.waiterCount == 1)
        }
    }

    @Test func discardingTheOwnerCancelsItsDetachedCooperativeRequest() async throws {
        let web = HarnessResponseGate<[CatalogTrack]>()
        defer { web.close() }
        weak var released: QueueService?
        do {
            let service = QueueService(
                webQueue: GatedQueue(responses: web),
                metadata: TrackMetadataService(remote: UnexpectedQueueRemote()), clock: HarnessClock.sticky())
            released = service
            await service.reset(accountEpoch: 1)
            let caller = Task {
                await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1)
            }
            defer { caller.cancel() }
            try await requireEventually { web.waiterCount == 1 }
            caller.cancel()
            #expect(await caller.value == nil)
            #expect(await service.refreshSubscriberCount == 0)
            #expect(web.waiterCount == 1, "Leaving the panel retains work while its service remains alive")
        }
        try await requireEventually { released == nil }
        try await requireEventually { web.waiterCount == 0 }
        #expect(web.requestCount == 1)
    }

    @Test func identicalRequestRejoinsAfterAllPreviousSubscribersHaveLeft() async throws {
        let web = HarnessResponseGate<[CatalogTrack]>()
        defer { web.close() }
        let service = QueueService(
            webQueue: GatedQueue(responses: web), metadata: TrackMetadataService(remote: UnexpectedQueueRemote()),
            clock: HarnessClock.sticky())
        await service.reset(accountEpoch: 1)
        let calls = HarnessCounters()
        let first = Task {
            defer { calls.record("first") }
            return await service.refresh(
                fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1,
                onUpdate: { _ in calls.record("cancelled update") })
        }
        defer { first.cancel() }
        try await requireEventually { web.waiterCount == 1 }
        first.cancel()
        try await requireEventually { calls.count("first") == 1 }
        #expect(await first.value == nil)
        #expect(await service.refreshSubscriberCount == 0)
        #expect(web.waiterCount == 1, "the retained service keeps useful work across a zero-subscriber interval")
        let replacement = Task {
            await service.refresh(
                fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1,
                onUpdate: { _ in calls.record("replacement update") })
        }
        defer { replacement.cancel() }
        try await requireEventually { await service.refreshSubscriberCount == 1 }
        #expect(web.requestCount == 1)
        web.finish([])
        #expect(await replacement.value != nil)
        #expect(calls.count("cancelled update") == 0)
        #expect(calls.count("replacement update") == 1)
        let diagnostics = await service.refreshDiagnostics
        #expect(diagnostics.starts == 1)
        #expect(diagnostics.joins == 1)
        #expect(diagnostics.cancellations == 0)
    }
}

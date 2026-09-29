@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@MainActor
struct QueueAdmissionTests {
    enum RejectedRequest: CaseIterable { case oldReset, cancelledReset, cancelledRefresh }

    @Test(arguments: RejectedRequest.allCases)
    func rejectedRequestCannotDisturbCurrentRefresh(_ request: RejectedRequest) async throws {
        let responses = HarnessResponseGate<[CatalogTrack]>()
        defer { responses.close() }
        let service = QueueService(
            webQueue: GatedQueue(responses: responses), metadata: TrackMetadataService(remote: UnexpectedQueueRemote()),
            clock: HarnessClock.sticky())
        await service.reset(accountEpoch: 2)
        let refresh = Task { await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 2) }
        defer { refresh.cancel() }
        try await requireEventually { responses.waiterCount == 1 }

        // Inherit MainActor so cancellation happens before this task can enter the service.
        let rejected = Task {
            switch request {
            case .oldReset: await service.reset(accountEpoch: 1)
            case .cancelledReset: await service.reset(accountEpoch: 2)
            case .cancelledRefresh:
                _ = await service.refresh(
                    fallbackEntries: [], currentTrackURI: "spotify:track:different", accountEpoch: 2)
            }
        }
        if request != .oldReset { rejected.cancel() }
        await rejected.value
        let diagnostics = await service.refreshDiagnostics
        #expect(await service.accountEpoch == 2)
        #expect(diagnostics.cancellations == 0)
        #expect(diagnostics.starts == 1)
        let queued = CatalogTrack(
            id: "queued", uri: "spotify:track:queued", title: "Queued", artist: "Artist", album: "Album",
            duration: 180, artworkURL: nil, addedAt: nil)
        responses.finish([queued])
        let result = await refresh.value
        #expect(result?.entries.map(\.uri) == [queued.uri])
    }

    #if DEBUG
        @Test func suspendedResetCannotReplaceANewerAccount() async throws {
            let suspension = HarnessSuspension()
            defer { suspension.close() }
            let service = QueueService(
                webQueue: GatedQueue(responses: HarnessResponseGate()),
                metadata: TrackMetadataService(remote: UnexpectedQueueRemote()),
                clock: HarnessClock.sticky(), hook: QueueServiceSuspensionHook(reset: suspension))
            await service.reset(accountEpoch: 1)
            suspension.arm()
            let older = Task { await service.reset(accountEpoch: 2) }
            defer { older.cancel() }
            try await requireEventually { suspension.isWaiting }
            await service.reset(accountEpoch: 3)
            let queued = QueueEntry(uri: "spotify:track:current", provider: "connect", occurrence: 0, uid: "current")
            _ = await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 1,
                    next: HarnessFixtures.queueTracks([queued])),
                accountEpoch: 3, fallbackTrackURI: nil)
            suspension.resume()
            await older.value
            #expect(await service.accountEpoch == 3)
            #expect(await service.mutationSnapshot()?.accountEpoch == 3)
        }
    #endif
}

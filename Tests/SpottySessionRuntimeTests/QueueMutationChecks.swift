@testable import SpottyRuntimeTestSupport
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@MainActor
struct QueueMutationTests {
    @Test func connectAndReplacementCommitWithoutSchedulerHooks() async {
        let service = isolatedQueueService()
        await service.reset(accountEpoch: 1)
        let accepted = await service.acceptConnect(
            HarnessFixtures.queueState(
                revision: 1,
                generation: 7,
                trackURI: "spotify:track:now",
                next: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
                queueRevision: "rev-1"),
            accountEpoch: 1, fallbackTrackURI: nil)
        #expect(accepted?.snapshot.revision == 1)
        let committed = await service.recordCommittedReplacement(replacement(), accountEpoch: 1, engineEpoch: 7)
        #expect(committed?.next.first?.uid == "q1")
    }

    #if DEBUG
        @Test func suspendedConnectAcceptanceResumesOnceAndHonorsCancellation() async throws {
            let suspension = HarnessSuspension()
            defer { suspension.close() }
            let service = isolatedQueueService(hook: QueueServiceSuspensionHook(accept: suspension))
            await service.reset(accountEpoch: 1)
            suspension.arm()
            let accepted = Task {
                await service.acceptConnect(
                    HarnessFixtures.queueState(
                        revision: 4,
                        next: HarnessFixtures.queueTracks([entry("spotify:track:parked")])),
                    accountEpoch: 1, fallbackTrackURI: nil)
            }
            defer { accepted.cancel() }
            try await requireEventually { suspension.isWaiting }
            suspension.resume()
            suspension.resume()
            #expect((await accepted.value)?.snapshot.revision == 4)
            #expect(suspension.isWaiting == false)

            suspension.arm()
            let cancelled = Task {
                await service.acceptConnect(
                    HarnessFixtures.queueState(
                        revision: 5,
                        next: HarnessFixtures.queueTracks([entry("spotify:track:cancel")])),
                    accountEpoch: 1, fallbackTrackURI: nil)
            }
            defer { cancelled.cancel() }
            try await requireEventually { suspension.isWaiting }
            cancelled.cancel()
            try await requireEventually { suspension.isWaiting == false }
            #expect(await cancelled.value == nil)
            #expect(await service.mutationSnapshot()?.sourceRevision == 4)
        }

        @Test func suspendedReplacementCommitsAfterOneResume() async throws {
            let suspension = HarnessSuspension()
            defer { suspension.close() }
            let service = isolatedQueueService(hook: QueueServiceSuspensionHook(replacement: suspension))
            await service.reset(accountEpoch: 1)
            _ = await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 1,
                    generation: 3,
                    next: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
                    queueRevision: "rev-1"),
                accountEpoch: 1, fallbackTrackURI: nil)
            suspension.arm()
            let committed = Task {
                await service.recordCommittedReplacement(replacement(), accountEpoch: 1, engineEpoch: 3)
            }
            defer { committed.cancel() }
            try await requireEventually { suspension.isWaiting }
            suspension.resume()
            suspension.resume()
            #expect((await committed.value)?.next.first?.uid == "q1")
            #expect(suspension.isWaiting == false)
        }
    #endif
}

private func entry(_ uri: String) -> QueueEntry {
    QueueEntry(uri: uri, provider: "connect", occurrence: 0)
}

private func replacement() -> QueueReplacement {
    QueueReplacement(
        next: [QueueProtocolTrack(uri: "spotify:track:b", uid: "q1", provider: "queue")],
        prev: [], queueRevision: "rev-2", removedCount: 1)
}

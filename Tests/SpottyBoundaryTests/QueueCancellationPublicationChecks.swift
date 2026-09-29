@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyDomain
import Testing

@Suite("Queue cancellation publication")
@MainActor
struct QueueCancellationPublicationTests {
    @Test func cancelledRefreshCannotPublishOrderingOrMetadata() async throws {
        let webQueue = HarnessWebQueue(.park)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(webQueue: webQueue))
        var refresh: PlaybackEffectSettlement?
        do {
            await player.restore()
            _ = player.send(.session(.ready), source: .account)
            player.withRuntime { $0.accountStore.publishPhase(.ready) }
            player.refreshQueue()
            refresh = player.effects.settlement(of: .queueRefresh)
            let effect = try #require(refresh)
            try await requireEventually(description: "queue refresh reaches the parked Web queue") { webQueue.isParked }
            player.cancelQueueRefresh()
            webQueue.complete(with: [HarnessFixtures.track(uri: "spotify:track:cancelled-queue", title: "Cancelled")])
            await effect.wait()
            #expect(player.state.queue.entries.isEmpty)
            #expect(player.catalog.metadata.knownTrack(for: "spotify:track:cancelled-queue") == nil)
        } catch {
            player.cancelQueueRefresh()
            webQueue.fail(CancellationError())
            await refresh?.wait()
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }
}

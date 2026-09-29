import SpottyDomain
import SpottyEngineAdapter
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

#if DEBUG
    @Suite("Connect queue publication")
    @MainActor
    struct ConnectQueuePublicationTests {
        @Test func resumedAcceptancePublishesRowsOrderingGenerationAndLabels() async throws {
            let hook = QueueServiceTestHook()
            let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(queueServiceHook: hook))
            let runtime = player.runtime
            do {
                await runtime.queueService.reset(accountEpoch: runtime.accountEpoch)
                await hook.parkNextConnectAccept()
                await runtime.receive(
                    RustPlaybackEventEnvelope(
                        sequence: 1, receivedAt: HarnessDates.fixed,
                        event: .queue(
                            HarnessFixtures.queueState(
                                revision: 1, generation: 1, trackURI: "spotify:track:now",
                                next: [QueueProtocolTrack(uri: "spotify:track:next", uid: "q0", provider: "queue")]))))
                try await requireEventually { await hook.connectAcceptIsParked() }
                #expect(player.queueNextEntries.isEmpty)
                #expect(player.queueInspectorOrderingVersion == 0)
                await hook.resumeConnectAccept()
                // Only subscription-published properties after release: compatibility runtime
                // access and settlement wrappers can force a desktop refresh themselves.
                try await requireEventually {
                    player.queueNextEntries.map(\.uri) == ["spotify:track:next"]
                        && player.queueInspectorOrderingVersion == 1
                        && player.engineGeneration == 1 && player.trackTitle == "Metadata"
                }
                #expect(player.queueNextEntries.map(\.uid) == ["q0"])
            } catch {
                hook.close()
                await player.shutdownForTermination()
                throw error
            }
            hook.close()
            await player.shutdownForTermination()
        }
    }
#endif

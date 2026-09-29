import SpottyTestSupport
import SpottyDomain
import SpottyEngineAdapter
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottyCore

@Suite("Connect readiness publication")
struct ConnectReadinessPublicationTests {
    @Test
    @MainActor
    func initializationReturnDoesNotPublishCommandReadiness() async {
        let store = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(remote: HarnessRemote(metadataTitle: "Resolved"))
        )
        store.accountStore.onPhaseChange?(.connecting)
        store.accountStore.onPhaseChange?(.ready)
        #expect(store.phase == .connecting)
        #expect(!store.canStartPlayback)

        store.receive(
            RustConnectionState(
                revision: 1, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                isActiveDevice: false, resumePending: false, lastError: nil, deviceID: nil
            ),
            revision: 1,
            receivedAt: HarnessDates.fixed
        )
        #expect(store.phase == .connecting)
        #expect(!store.canStartPlayback)
        store.receive(
            HarnessFixtures.connectCluster(revision: 2, activeID: "", trackURI: ""), receivedAt: HarnessDates.fixed)
        #expect(store.phase == .ready)
        #expect(store.canStartPlayback)
        #expect(store.defaultLocalPlaybackDevice?.id == "local")
        await store.shutdownForTermination()
    }

}

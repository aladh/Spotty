@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import Testing
import SpottyDomain
@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyEngineAdapter
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Credential Rejection")
struct CredentialRejectionTests {
    @Test @MainActor
    func testAcceptedRejectionPreservesGrantAndOffersExplicitReauthorization() async throws {
        let engine = HarnessEngine()
        let account = HarnessAccount(hasGrant: true, authorization: .succeed)
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            clock: HarnessClock(sleep: .immediate)
        )
        let player = PlaybackStore(
            environment: environment,
            feedback: TransientFeedbackPresenter(clock: environment.clock)
        )

        do {
            let rejection = player.withRuntime { runtime in
                runtime.receive(
                    RustConnectionState(
                        revision: 1,
                        sessionGeneration: 0,
                        sessionConnected: false,
                        spircReady: false,
                        isActiveDevice: true,
                        resumePending: true,
                        lastError: "private upstream detail",
                        deviceID: "local",
                        credentialsRejected: true
                    ),
                    revision: 1,
                    receivedAt: Date(timeIntervalSince1970: 1)
                )
                // Teardown removes account-scoped registrations as soon as it starts. Capture the
                // exact effect before the independent runtime can begin that teardown transition.
                return runtime.effects.settlement(of: .credentialRejection)
            }

            #expect(
                (player.statusText) == (ConnectionSnapshotProjection.credentialsRejectedMessage),
                "credential rejection projects stable actionable text"
            )
            #expect((player.requiresReauthentication) == true, "accepted rejection enables reauthorization")
            #expect((account.clearCount) == (0), "credential rejection does not clear the Keymaster grant")

            let acceptedRejection = try #require(rejection, "accepted rejection owns its teardown effect")
            await acceptedRejection.wait()
            try await requireEventually(description: "Teardown publishes its actionable rejection phase") {
                player.phase == .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
            }
            #expect((engine.clearStreamingCredentialsCount) == (1), "only streaming credentials are cleared")
            #expect((account.clearCount) == (0), "teardown preserves the independent account grant")
            #expect(
                (player.phase) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
                "teardown keeps the actionable rejection phase"
            )
            #expect((engine.executeCount) == (0), "credential rejection does not issue reconnect rehydration")

            let stale = RustConnectionState(
                revision: 2,
                sessionGeneration: 0,
                sessionConnected: true,
                spircReady: true,
                isActiveDevice: true,
                resumePending: false,
                lastError: nil,
                deviceID: "local",
                credentialsRejected: true
            )
            player.receive(stale, revision: stale.revision, receivedAt: Date(timeIntervalSince1970: 2))
            #expect(
                (engine.clearStreamingCredentialsCount) == (1),
                "an old-generation rejection cannot repeat credential cleanup"
            )

            let initializeBeforeRestore = engine.initializeCount
            await player.restore()
            #expect((account.authorizeCount) == (0), "restore keeps the rejected grant from opening a browser")
            #expect(
                (engine.initializeCount) == (initializeBeforeRestore),
                "restore with a rejection marker does not retry the known-rejected streaming credential"
            )

            let playback = CatalogPlaybackAccess(player: player)
            #expect((playback.connectionActionTitle) == ("Sign In Again"), "the action names reauthorization")
            playback.connect()
            // The worker's counter can advance before MainActor receives the runtime publication.
            // Wait for both independent observations before inspecting the displayed readiness.
            try await requireEventually(description: "The explicit sign-in action initializes a fresh engine") {
                engine.initializeCount > initializeBeforeRestore && player.phase == .connecting
            }
            #expect(player.phase == .connecting, "initialization alone does not establish Connect readiness")
            player.receive(
                RustConnectionState(
                    revision: 3,
                    sessionGeneration: player.engineGeneration,
                    sessionConnected: true,
                    spircReady: true,
                    isActiveDevice: true,
                    resumePending: false,
                    lastError: nil,
                    deviceID: "local"
                ),
                revision: 3,
                receivedAt: Date(timeIntervalSince1970: 3)
            )
            try await requireEventually(description: "The explicit sign-in action publishes fresh readiness") {
                player.phase == .ready
            }
            #expect((account.authorizeCount) == (1), "the reauthorization action opens the interactive flow")
            #expect((player.requiresReauthentication) == false, "a successful fresh grant clears the marker")
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }
}

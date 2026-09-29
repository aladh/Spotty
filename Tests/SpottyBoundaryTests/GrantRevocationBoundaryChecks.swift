@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime
import SpottyRuntimeContracts

@Suite("Grant revocation boundary")
struct GrantRevocationBoundaryChecks {
    @Test @MainActor
    func failedAdoptionDoesNotWithdrawAnUndeliveredRevocation() async throws {
        let store = HarnessGrantStore()
        let credentials = KeymasterSession(
            store: store, refresher: { _ in throw KeymasterAuthError.grantRevoked }, cookieCleanup: {})
        let account = LiveAccountSession(session: credentials, openAuthorizationURL: { _ in false })
        var revocations = account.revocations().makeAsyncIterator()
        try await account.adopt(HarnessFixtures.tokens(expiresAt: .distantPast))
        await #expect(throws: KeymasterSessionError.grantRevoked) { try await account.accessToken() }
        let revocation = try #require(await revocations.next())
        store.failNextSave()

        await #expect(throws: HarnessGrantStore.Failure.saveRejected) {
            try await account.adopt(
                HarnessFixtures.tokens(accessToken: "replacement", refreshToken: "replacement-refresh"))
        }

        #expect(await account.isCurrent(revocation) == true)
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, account: account))
        let epoch = player.accountEpoch
        await player.runtime.handleGrantRevocation(revocation)
        player.withRuntime { _ in }

        #expect(player.accountEpoch == epoch + 1)
        #expect(player.requiresReauthentication == true)
        #expect(engine.clearStreamingCredentialsCount == 1)
        #expect(await account.hasGrant() == false)
        await player.shutdownForTermination()
    }

    @Test @MainActor
    func queuedRevocationCannotRetireADurablyAdoptedReplacementGrant() async throws {
        let credentials = KeymasterSession(
            store: HarnessGrantStore(), refresher: { _ in throw KeymasterAuthError.grantRevoked },
            cookieCleanup: {})
        let account = LiveAccountSession(session: credentials, openAuthorizationURL: { _ in false })
        var revocations = account.revocations().makeAsyncIterator()
        try await account.adopt(HarnessFixtures.tokens(expiresAt: .distantPast))
        await #expect(throws: KeymasterSessionError.grantRevoked) { try await account.accessToken() }
        let replacement = HarnessFixtures.tokens(accessToken: "replacement", refreshToken: "replacement-refresh")
        try await account.adopt(replacement)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(account: account))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        let epoch = player.accountEpoch

        // Deliver the real gateway notification only after the replacement has been accepted.
        // This is the same runtime intake used by its process-lifetime subscription.
        let revocation = try #require(await revocations.next())
        await player.runtime.handleGrantRevocation(revocation)
        player.withRuntime { _ in }

        #expect(player.accountEpoch == epoch)
        #expect(player.phase == .ready)
        #expect(player.requiresReauthentication == false)
        #expect(await account.reauthenticationRequired() == false)
        #expect(try await account.accessToken() == replacement.accessToken)
        await player.shutdownForTermination()
    }

}

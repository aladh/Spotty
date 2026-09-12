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
    func testAcceptedRejectionPreservesGrantAndOffersExplicitReauthorization() async {
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

        #expect((rejection != nil) == true, "accepted rejection owns its teardown effect")
        await rejection?.wait()
        player.withRuntime { _ in }
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
        #expect(
            (await waitUntil { engine.initializeCount > initializeBeforeRestore && player.phase == .connecting })
                == true,
            "the explicit sign-in action initializes a fresh engine"
        )
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
        #expect(
            (await waitUntil { player.phase == .ready }) == true,
            "the explicit sign-in action completes a fresh account workflow"
        )
        #expect((account.authorizeCount) == (1), "the reauthorization action opens the interactive flow")
        #expect((player.requiresReauthentication) == false, "a successful fresh grant clears the marker")
    }
}

@Suite("Account Connection Cancellation")
struct AccountConnectionCancellationTests {
    @Test @MainActor
    func testOAuthAcceptanceCommitsBeforeAdoptAndLogoutDrains() async {
        let cancelledAccount = GatedConnectAccount(parkAuthorization: true)
        let cancelledEnvironment = HarnessEnvironment.make(
            engine: HarnessEngine(),
            account: cancelledAccount,
            clock: HarnessClock(sleep: .immediate)
        )
        let cancelledPlayer = PlaybackStore(
            environment: cancelledEnvironment,
            feedback: TransientFeedbackPresenter(clock: cancelledEnvironment.clock)
        )

        cancelledPlayer.connect()
        #expect(
            (await waitUntil {
                cancelledPlayer.phase == .authorizing && cancelledAccount.authorizationEntered
            }) == true,
            "interactive authorization reaches its cancellable phase"
        )
        cancelledPlayer.cancelConnect()
        #expect((cancelledPlayer.phase) == (.signedOut), "cancellation before OAuth acceptance signs out")

        cancelledAccount.releaseAuthorization()
        #expect(
            (await waitUntil { cancelledAccount.authorizationReturned }) == true,
            "the cancelled authorization task observes its late result"
        )
        #expect(
            (cancelledAccount.adoptCount) == (0),
            "a late OAuth result cannot persist after pre-acceptance cancellation"
        )

        let acceptedAccount = GatedConnectAccount(parkAuthorization: false)
        let acceptedEnvironment = HarnessEnvironment.make(
            engine: HarnessEngine(),
            account: acceptedAccount,
            clock: HarnessClock(sleep: .immediate)
        )
        let acceptedPlayer = PlaybackStore(
            environment: acceptedEnvironment,
            feedback: TransientFeedbackPresenter(clock: acceptedEnvironment.clock)
        )

        acceptedPlayer.connect()
        #expect(
            (await waitUntil {
                acceptedPlayer.phase == .connecting && acceptedAccount.adoptEntered
            }) == true,
            "a valid OAuth result commits the connecting phase before persistence"
        )
        acceptedPlayer.cancelConnect()
        #expect(
            (acceptedPlayer.phase) == (.connecting),
            "cancelConnect does not interrupt an accepted OAuth result"
        )
        #expect((acceptedAccount.adoptCount) == (1), "the accepted result enters persistence")

        let logout = Task { await acceptedPlayer.logout() }
        #expect(
            (await waitUntil { acceptedPlayer.isTearingDown }) == true,
            "logout starts owned session teardown"
        )
        #expect(
            (acceptedAccount.clearCount) == (0),
            "logout waits for the accepted persistence operation before clearing the grant"
        )

        acceptedAccount.releaseAdoption()
        await logout.value
        #expect((acceptedAccount.adoptReturned) == true, "teardown drains the accepted operation")
        #expect((acceptedAccount.clearCount) == (1), "logout clears the grant after draining")
        #expect((acceptedPlayer.phase) == (.signedOut), "logout finishes signed out")
    }
}

/// Gates `authorizeInteractively` and `adopt` independently, each with its own entered/returned
/// flags and a continuation the check releases by hand. `HarnessAccount` only parks `clear()`, so
/// it cannot express the ordering this check asserts between a cancellable OAuth round trip and a
/// separately-gated persistence step.
private final class GatedConnectAccount: AccountSession, @unchecked Sendable {
    private let parkAuthorization: Bool
    private let lock = NSLock()
    private var authorizationContinuation: CheckedContinuation<KeymasterTokens, Never>?
    private var adoptionContinuation: CheckedContinuation<Void, Never>?
    private var authorizationEnteredStorage = false
    private var authorizationReturnedStorage = false
    private var adoptEnteredStorage = false
    private var adoptReturnedStorage = false
    private var adoptStorage = 0
    private var clearStorage = 0

    init(parkAuthorization: Bool) {
        self.parkAuthorization = parkAuthorization
    }

    var authorizationEntered: Bool { lock.withLock { authorizationEnteredStorage } }
    var authorizationReturned: Bool { lock.withLock { authorizationReturnedStorage } }
    var adoptEntered: Bool { lock.withLock { adoptEnteredStorage } }
    var adoptReturned: Bool { lock.withLock { adoptReturnedStorage } }
    var adoptCount: Int { lock.withLock { adoptStorage } }
    var clearCount: Int { lock.withLock { clearStorage } }

    func authorizeInteractively() async throws -> KeymasterTokens {
        if parkAuthorization {
            _ = await withCheckedContinuation { continuation in
                lock.withLock {
                    authorizationEnteredStorage = true
                    authorizationContinuation = continuation
                }
            }
        } else {
            lock.withLock { authorizationEnteredStorage = true }
        }
        lock.withLock { authorizationReturnedStorage = true }
        return Self.tokens
    }

    func hasGrant() async -> Bool { false }
    func grantState() async -> KeymasterGrantState { .absent }
    func accessToken() async throws -> String { Self.tokens.accessToken }

    func adopt(_: KeymasterTokens) async throws {
        lock.withLock {
            adoptStorage += 1
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                adoptEnteredStorage = true
                adoptionContinuation = continuation
            }
        }
        lock.withLock { adoptReturnedStorage = true }
    }

    func clear() async {
        lock.withLock { clearStorage += 1 }
    }

    func revocations() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }

    func releaseAuthorization() {
        let continuation = lock.withLock {
            let continuation = authorizationContinuation
            authorizationContinuation = nil
            return continuation
        }
        continuation?.resume(returning: Self.tokens)
    }

    func releaseAdoption() {
        let continuation = lock.withLock {
            let continuation = adoptionContinuation
            adoptionContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private static let tokens = KeymasterTokens(
        accessToken: "gated-access",
        refreshToken: "gated-refresh",
        expiresAt: .distantFuture,
        username: "gated-user"
    )
}

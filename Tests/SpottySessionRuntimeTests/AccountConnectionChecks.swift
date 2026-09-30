import Foundation
import SpottyDomain
import SpottyGateway
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

#if DEBUG
    @Suite("Account Connection Cancellation")
    @SessionRuntimeActor
    struct AccountConnectionCancellationTests {
        @Test func cancellationBeforeOAuthAcceptanceCannotAdoptALateGrant() async throws {
            try await withAccountConnection { fixture in
                let connection = try fixture.connect()
                try await requireEventually(description: "OAuth enters its cancellable phase") {
                    fixture.runtime.phase == .authorizing && fixture.account.authorization.waiterCount == 1
                }
                fixture.runtime.cancelConnect()
                #expect(fixture.runtime.phase == .signedOut)
                #expect(fixture.runtime.accountStore.connectionSettlement() == nil)
                // A seeded missing post-OAuth guard must also be able to finish an
                // unexpected adoption, so its count fails normally rather than hanging.
                fixture.account.adoption.finish(())
                fixture.account.authorization.finish(GatedConnectAccount.tokens)
                await connection.wait()
                #expect(fixture.account.counters.count("authorizationReturned") == 1)
                #expect(
                    fixture.account.counters.count("adopt") == 0,
                    "A late OAuth result cannot persist after pre-acceptance cancellation")
                #expect(fixture.runtime.phase == .signedOut)
            }
        }

        @Test func testOAuthAcceptanceCommitsBeforeAdoptAndLogoutDrains() async throws {
            try await withAccountConnection { fixture in
                // Early replies are retained, including before the accepted worker starts.
                fixture.account.authorization.finish(GatedConnectAccount.tokens)
                let connection = try fixture.connect()
                try await requireEventually(description: "Accepted OAuth enters persistence") {
                    fixture.runtime.phase == .connecting && fixture.account.adoption.waiterCount == 1
                }
                fixture.runtime.cancelConnect()
                #expect(
                    fixture.runtime.phase == .connecting,
                    "cancelConnect does not interrupt an accepted OAuth result")
                #expect(fixture.account.counters.count("adopt") == 1)
                let logout = fixture.logout()
                try await requireEventually(description: "Logout starts owned account retirement") {
                    fixture.runtime.isTearingDown
                }
                #expect(fixture.runtime.accountStore.connectionSettlement() == nil)
                #expect(
                    fixture.account.counters.count("clear") == 0,
                    "Logout waits for accepted persistence before clearing the grant")
                fixture.runtime.connect()
                let unexpected = fixture.runtime.accountStore.connectionSettlement()
                fixture.own(unexpected)
                try #require(unexpected == nil, "Retirement refuses new connection work")
                fixture.account.adoption.finish(())
                await connection.wait()
                await logout.value
                #expect(fixture.account.counters.count("adoptReturned") == 1)
                #expect(fixture.account.counters.count("clear") == 1)
                #expect(fixture.account.counters.count("clearBeforeAdoptionReturned") == 0)
                #expect(fixture.account.authorization.requestCount == 1)
                #expect(fixture.runtime.phase == .signedOut)
            }
        }

        @Test(arguments: [false, true])
        func cancellationOrClosureBeforeWaiterRegistrationSettlesAcceptedWork(closeFirst: Bool) async throws {
            try await withAccountConnection { fixture in
                let connection = try fixture.connect()
                // This actor turn cannot let the accepted worker register a dependency waiter.
                if closeFirst {
                    fixture.account.close()
                } else {
                    connection.cancel()
                }
                await connection.wait()
                #expect(fixture.account.adoption.requestCount == 0)
                #expect(fixture.account.authorization.waiterCount == 0)
                #expect(fixture.account.adoption.waiterCount == 0)
            }
        }

        @Test func earlyOAuthAndAdoptionRepliesSettleWithoutWaiterRegistration() async throws {
            try await withAccountConnection { fixture in
                fixture.account.authorization.finish(GatedConnectAccount.tokens)
                fixture.account.adoption.finish(())
                let connection = try fixture.connect()
                await connection.wait()
                #expect(fixture.account.authorization.requestCount == 1)
                #expect(fixture.account.adoption.requestCount == 1)
                #expect(fixture.account.counters.count("adoptReturned") == 1)
                #expect(fixture.account.authorization.waiterCount == 0)
                #expect(fixture.account.adoption.waiterCount == 0)
            }
        }

        @Test func terminationRefusesConnectionAdmission() async throws {
            try await withAccountConnection { fixture in
                await fixture.runtime.shutdownForTermination()
                fixture.runtime.connect()
                let unexpected = fixture.runtime.accountStore.connectionSettlement()
                fixture.own(unexpected)
                #expect(unexpected == nil, "Termination cannot admit a connection worker")
                fixture.account.close()
                await unexpected?.wait()
                #expect(fixture.account.authorization.requestCount == 0)
            }
        }
    }

    @Suite("Account Grant Revocation Ordering")
    @SessionRuntimeActor
    struct AccountGrantRevocationOrderingTests {
        @Test func revocationDeliveryJoinsTheAcceptedGrantHandoffBeforeValidation() async throws {
            try await withAccountConnection { fixture in
                fixture.account.authorization.finish(GatedConnectAccount.tokens)
                let connection = try fixture.connect()
                try await requireEventually(description: "Accepted grant handoff enters adoption") {
                    fixture.account.adoption.waiterCount == 1
                }
                let epoch = fixture.runtime.accountEpoch
                let delivery = fixture.deliverRevocation()
                try await requireEventually(description: "Revocation enters the runtime executor") {
                    fixture.account.counters.count("delivery") == 1
                }
                // The delivery task uses this same actor and runs through its first suspension
                // before this actor can resume. Validation itself has no extra actor hop.
                #expect(fixture.account.counters.count("validation") == 0)
                #expect(fixture.runtime.accountEpoch == epoch)
                fixture.account.adoption.finish(())
                await connection.wait()
                await delivery.value
                #expect(fixture.account.counters.count("validation") == 1)
                #expect(fixture.runtime.accountEpoch == epoch)
                #expect(fixture.runtime.requiresReauthentication == false)
                #expect(fixture.account.counters.count("clear") == 0)
            }
        }
    }

    /// Narrow account owner fixture. Shared HarnessAccount cannot gate authorization and durable
    /// adoption independently, or validate revocation on the runtime executor without an actor hop.
    private final class GatedConnectAccount: AccountSession, Sendable {
        let authorization = HarnessResponseGate<KeymasterTokens>(cancellation: .ignored)
        let adoption = HarnessResponseGate<Void>(cancellation: .ignored)
        let counters = HarnessCounters()
        let pendingRevocation = AccountGrantRevocation()
        static let tokens = KeymasterTokens(
            accessToken: "gated-access", refreshToken: "gated-refresh",
            expiresAt: .distantFuture, username: "gated-user")

        func authorizeInteractively() async throws -> KeymasterTokens {
            let tokens = try await authorization.wait()
            counters.record("authorizationReturned")
            return tokens
        }

        func hasGrant() async -> Bool { false }
        func grantState() async -> KeymasterGrantState { .absent }
        func accessToken() async throws -> String { Self.tokens.accessToken }

        func adopt(_: KeymasterTokens) async throws {
            counters.record("adopt")
            try await adoption.wait()
            counters.record("adoptReturned")
        }

        func clear() async -> Bool {
            if counters.count("adopt") > counters.count("adoptReturned") {
                counters.record("clearBeforeAdoptionReturned")
            }
            counters.record("clear")
            return true
        }

        @SessionRuntimeActor
        func isCurrent(_ revocation: AccountGrantRevocation) -> Bool {
            counters.record("validation")
            return revocation == pendingRevocation && counters.count("adoptReturned") == 0
        }

        func revocations() -> AsyncStream<AccountGrantRevocation> {
            AsyncStream { $0.finish() }
        }

        func close() {
            authorization.close()
            adoption.close()
        }
    }

    @SessionRuntimeActor
    private final class AccountConnectionFixture {
        let account = GatedConnectAccount()
        let runtime: PlaybackSessionRuntime
        private var connections: [AccountStore.ConnectionSettlement] = []
        private var operations: [Task<Void, Never>] = []

        init() {
            runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(account: account))
        }

        func connect(sourceLocation: SourceLocation = #_sourceLocation) throws -> AccountStore.ConnectionSettlement {
            runtime.connect()
            // Capture the actual accepted task in the admission turn, never after an await.
            let connection = try #require(runtime.accountStore.connectionSettlement(), sourceLocation: sourceLocation)
            own(connection)
            return connection
        }

        func own(_ connection: AccountStore.ConnectionSettlement?) {
            if let connection { connections.append(connection) }
        }

        func logout() -> Task<Void, Never> {
            let task = Task { await runtime.logout() }
            operations.append(task)
            return task
        }

        func deliverRevocation() -> Task<Void, Never> {
            let task = Task {
                account.counters.record("delivery")
                await runtime.handleGrantRevocation(account.pendingRevocation)
            }
            operations.append(task)
            return task
        }

        func cleanUp() async {
            // Close current AND future calls before cancelling and joining actual accepted work.
            account.close()
            for connection in connections { connection.cancel() }
            for operation in operations { operation.cancel() }
            for connection in connections { await connection.wait() }
            for operation in operations { await operation.value }
            await runtime.shutdownForTermination()
        }
    }

    @SessionRuntimeActor
    private func withAccountConnection(_ body: (AccountConnectionFixture) async throws -> Void) async throws {
        let fixture = AccountConnectionFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }
#endif

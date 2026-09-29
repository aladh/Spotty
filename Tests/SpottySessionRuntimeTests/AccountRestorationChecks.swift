import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyTestSupport
import Synchronization
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@Suite("Account restoration")
@SessionRuntimeActor
struct AccountRestorationTests {
    @Test func transientStartupFailuresRecoverWithoutBrowserAuthorization() async {
        let account = HarnessAccount(hasGrant: true)
        let engine = HarnessEngine()
        let results = InitializationScript([.error, .error, .ok])
        engine.onInitialize = { results.next() }
        let remote = HarnessRemote()
        let environment = HarnessEnvironment.make(
            engine: engine, remote: remote, account: account, clock: HarnessClock(sleep: .immediate))
        let store = AccountStore(
            environment: environment, coordinator: PlaybackCoordinator(local: engine, remote: remote),
            lifecycle: SessionLifecycle())

        await store.restore()

        #expect(store.phase == .ready)
        #expect(engine.initializeCount == 3)
        #expect(account.authorizeCount == 0)
        #expect(await account.reauthenticationRequired() == false)
        #expect(account.clearCount == 0)
    }

    @Test func retryBudgetExhaustsWithoutDiscardingTheSavedGrant() async {
        let account = HarnessAccount(hasGrant: true)
        let engine = HarnessEngine(initializeResult: .error)
        let remote = HarnessRemote()
        let clock = HarnessClock(sleep: .immediate)
        let environment = HarnessEnvironment.make(engine: engine, remote: remote, account: account, clock: clock)
        let store = AccountStore(
            environment: environment, coordinator: PlaybackCoordinator(local: engine, remote: remote),
            lifecycle: SessionLifecycle())

        await store.restore()

        #expect(store.phase == .failed("Spotty Connect could not start (-1)"))
        #expect(engine.initializeCount == 6)
        #expect(clock.requestedSleeps == [1, 3, 1, 3])
        #expect(account.authorizeCount == 0)
        #expect(await account.reauthenticationRequired() == false)
        #expect(account.clearCount == 0)
        #expect(account.hasStoredGrant)
    }

    @Test func logoutCancelsAPendingRestoreRetry() async throws {
        let account = HarnessAccount(hasGrant: true)
        let engine = HarnessEngine(initializeResult: .error)
        let clock = HarnessClock.parked()
        let environment = HarnessEnvironment.make(engine: engine, account: account, clock: clock)
        try await withRuntime(environment) { runtime in
            let finished = HarnessCounters()
            let restoration = Task {
                defer { finished.record("restore") }
                await runtime.restore()
            }
            defer { restoration.cancel() }
            try await requireEventually { clock.waiterCount == 1 }

            let logout = Task {
                defer { finished.record("logout") }
                await runtime.logout()
            }
            defer { logout.cancel() }
            // A broken cancellation must fail the prerequisite rather than hang at a task join.
            do {
                try await requireEventually { finished.count("logout") == 1 && finished.count("restore") == 1 }
            } catch {
                clock.sleepBehavior = .immediate
                clock.releaseAll()
                throw error
            }
            await logout.value
            await restoration.value

            #expect(runtime.accountStore.phase == .signedOut)
            #expect(engine.initializeCount == 1)
            #expect(clock.waiterCount == 0)
            #expect(account.clearCount == 1)
        }
    }

    @Test func typedRejectionSurvivesRestartUntilExplicitAuthorization() async throws {
        let account = HarnessAccount(hasGrant: true, authorization: .succeed)
        let engine = HarnessEngine()
        let results = InitializationScript([.credentialsRejected, .ok])
        engine.onInitialize = { results.next() }
        let environment = HarnessEnvironment.make(
            engine: engine, account: account, clock: HarnessClock(sleep: .immediate))
        try await withRuntime(environment) { runtime in
            await runtime.restore()
            #expect(runtime.accountStore.phase == .failed(ConnectionSnapshotProjection.credentialsRejectedMessage))
            #expect(runtime.accountStore.requiresReauthentication)
            #expect(await account.reauthenticationRequired())
            #expect(account.markReauthenticationCount == 1)
            #expect(account.authorizeCount == 0)
            #expect(engine.initializeCount == 1)
        }

        // The first owner has completed termination; its persisted account fixture outlives it.
        try await withRuntime(environment) { runtime in
            await runtime.restore()
            #expect(runtime.accountStore.requiresReauthentication)
            #expect(runtime.accountStore.phase == .failed(ConnectionSnapshotProjection.credentialsRejectedMessage))
            #expect(engine.initializeCount == 1)
            #expect(account.authorizeCount == 0)

            runtime.connect()
            try await requireEventually { runtime.accountStore.phase == .ready }
            #expect(account.authorizeCount == 1)
            #expect(await account.reauthenticationRequired() == false)
            #expect(runtime.accountStore.requiresReauthentication == false)
            #expect(engine.initializeCount == 2)

            await runtime.logout()
            #expect(account.clearCount == 1)
            #expect(await account.reauthenticationRequired() == false)
            #expect(account.hasStoredGrant == false)
        }
    }

    private func withRuntime(
        _ environment: PlaybackEnvironment,
        _ body: (PlaybackSessionRuntime) async throws -> Void
    ) async throws {
        let runtime = PlaybackSessionRuntime(environment: environment)
        do {
            try await body(runtime)
        } catch {
            await runtime.shutdownForTermination()
            throw error
        }
        await runtime.shutdownForTermination()
    }
}

/// Only changing initialization outcomes need a script; ordinary fixed failures use HarnessEngine.
private final class InitializationScript: Sendable {
    private let remaining: Mutex<ArraySlice<PlaybackEngineResult>>

    init(_ results: [PlaybackEngineResult]) { remaining = Mutex(results[...]) }

    func next() -> PlaybackEngineResult {
        guard let result = remaining.withLock({ $0.popFirst() }) else {
            Issue.record("Unexpected initialization after the scripted outcomes were exhausted")
            return .error
        }
        return result
    }
}

@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Account Epoch Ownership")
struct AccountEpochOwnershipTests {
    @Test(arguments: [false, true]) @MainActor
    func teardownCommitsEngineIdentityBeforeCancellingAccountEffects(terminating: Bool) async throws {
        let gate = HarnessResponseGate<Void>()
        defer { gate.close() }
        let cancellations = HarnessCounters()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        player.withRuntime { runtime in
            _ = runtime.send(.session(.ready), source: .account, engineEpoch: 4)
            runtime.effects.run(
                .positionRefresh,
                onCancel: { [weak runtime] in
                    guard let runtime else { Issue.record("The retiring runtime must own cancellation"); return }
                    let generation = runtime.engineGeneration
                    let committedGeneration = runtime.state.engineEpoch
                    #expect(generation == 5)
                    #expect(committedGeneration == generation, "Cancellation sees one committed engine identity")
                    cancellations.record("cancelled")
                }
            ) { try? await gate.wait() }
        }
        try await requireEventually { gate.waiterCount == 1 }

        if terminating { await player.shutdownForTermination() } else { await player.logout() }

        #expect(cancellations.count("cancelled") == 1)
        await player.shutdownForTermination()
    }

    @Test @MainActor
    func currentGrantRevocationStillRetiresTheRunningSession() async throws {
        let account = HarnessAccount(hasGrant: true, revocations: .live)
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, account: account))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
            $0.startLifetimeEffectsIfNeeded()
        }
        let epoch = player.accountEpoch
        try #require(account.subscriptionCount == 1)

        account.revoke()

        try await requireEventually {
            player.withRuntime { $0.accountEpoch > epoch && !$0.isTearingDown && $0.requiresReauthentication }
        }
        #expect(player.phase == .failed(ConnectionSnapshotProjection.credentialsRejectedMessage))
        #expect(engine.clearStreamingCredentialsCount == 1)
        await player.shutdownForTermination()
    }

    @Test @MainActor
    func adoptionDuringRevocationValidationFencesItsLateAnswer() async throws {
        let account = HarnessAccount(authorization: .succeed)
        let revocation = account.revoke()
        let validation = HarnessResponseGate<Void>()
        defer { validation.close() }
        account.onRevocationValidation = { try? await validation.wait() }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(account: account))
        let epoch = player.accountEpoch
        let delivery = Task { await player.runtime.handleGrantRevocation(revocation) }
        defer { delivery.cancel() }
        try await requireEventually { validation.waiterCount == 1 }

        player.connect()
        try await requireEventually { account.hasStoredGrant }
        account.onRevocationValidation = nil
        validation.finish(())
        await delivery.value
        player.withRuntime { _ in }

        #expect(player.accountEpoch == epoch)
        #expect(player.requiresReauthentication == false)
        #expect(account.markReauthenticationCount == 0)
        await player.shutdownForTermination()
    }

    @Test @MainActor
    func logoutRetiresCatalogBeforeWaitingForAnOldConnection() async throws {
        let retired = HarnessCounters()
        let cache = HarnessCatalogCacheLifecycle { epoch, purge in
            #expect(epoch == 1)
            #expect(purge)
            retired.record("catalog")
            return true
        }
        let account = HarnessAccount(hasGrant: true)
        account.parkGrantRead = true
        defer { account.completeGrantRead() }
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(account: account, catalogCacheLifecycle: cache))
        let restore = Task { await player.restore() }
        defer { restore.cancel() }
        try await requireEventually { account.isGrantReadParked }
        let logout = Task { await player.logout() }
        defer { logout.cancel() }
        try await requireEventually(description: "catalog retired during connection drain") {
            retired.count("catalog") == 1
        }
        #expect(account.isGrantReadParked)
        #expect(account.clearCount == 0, "credential cleanup still joins the older connection")
        account.completeGrantRead()
        await restore.value
        await logout.value
        #expect(account.clearCount == 1)
        #expect(player.accountEpoch == 2)
    }

    @Test @MainActor
    func terminationDrainsPlaybackBeforeWaitingForCatalogStorage() async {
        let retirement = HarnessClock.parked()
        defer { retirement.releaseAll() }
        let cache = HarnessCatalogCacheLifecycle { epoch, purge in
            #expect(epoch == 1)
            #expect(!purge, "quitting retains the catalog and saved account")
            try? await retirement.sleep(seconds: 1)
            return true
        }
        let engine = HarnessEngine()
        let account = HarnessAccount(hasGrant: true)
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, account: account, catalogCacheLifecycle: cache))
        await player.restore()

        let quit = Task { await player.shutdownForTermination() }
        await expectEventually { retirement.waiterCount == 1 }

        #expect(engine.count(.shutdown) == 1, "the final playback publication cannot wait behind storage")
        #expect(engine.count(.cleanup) == 1, "the engine must drain its final publication before other cleanup")
        #expect(account.clearCount == 0)
        await expectEventually { player.isTearingDown }
        retirement.releaseAll()
        await quit.value
        #expect(engine.count(.shutdown) == 1)
    }

    @Test @MainActor
    func failedGrantRemovalStillRetiresTheSessionAndReportsTheRetainedLogin() async {
        let account = HarnessAccount(hasGrant: true, clearSucceeds: false)
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, account: account))
        await player.restore()
        let epoch = player.accountEpoch

        await player.logout()

        #expect(player.accountEpoch == epoch + 1)
        #expect(player.accountStore.phase == .signedOut)
        #expect(!player.catalogSession.isAvailable)
        #expect(engine.count(.shutdown) == 1)
        #expect(account.clearCount == 1)
        #expect(player.feedback.message?.kind == .failure)
        let failureMessage = await SpottySessionRuntime.AccountStore.grantRemovalFailureMessage
        #expect(player.feedback.message?.text == failureMessage)
        #expect(await account.hasGrant() == false)
        #expect(await account.grantState() == .removalFailed)
        #expect(account.hasStoredGrant, "failure retains the file without making it usable")
        await #expect(throws: HarnessFailure.unavailable) { try await account.accessToken() }

        await player.restore()
        #expect(player.accountStore.phase == .failed(failureMessage))
        #expect(engine.initializeCount == 1, "restoration must not admit the retained login")

        try? await account.adopt(HarnessFixtures.tokens())
        #expect(await account.grantState() == .available)
        #expect(await account.hasGrant())
    }

    @Test
    @MainActor
    func testAccountEpochOwnership() async {
        do {
            let engine = HarnessEngine()
            let account = HarnessAccount(hasGrant: true, authorization: .succeed)
            let player = PlaybackStore(
                environment: HarnessEnvironment.make(
                    engine: engine, account: account, clock: HarnessClock(sleep: .immediate)),
                feedback: TransientFeedbackPresenter(clock: HarnessClock(sleep: .immediate))
            )
            await player.restore()
            let start = player.accountStore.epoch
            #expect((start) == (1), "restore keeps the initial account identity")
            #expect((player.accountEpoch) == (start), "the store projection matches AccountStore")
            #expect((player.state.accountEpoch) == (start), "reducer state starts on the same epoch")

            await player.logout()
            let afterLogout = player.accountStore.epoch
            #expect((afterLogout) == (start + 1), "ordinary teardown advances AccountStore once")
            #expect((player.accountEpoch) == (afterLogout), "PlaybackStore projects that exact epoch")
            #expect((player.state.accountEpoch) == (afterLogout), "reducer state adopts that exact epoch")
            #expect((player.catalogSession.accountEpoch) == (afterLogout), "catalog session observes that exact epoch")
            #expect(
                (await player.queueService.accountEpoch) == (afterLogout), "QueueService reset uses that exact epoch")
            #expect((engine.count(.shutdown)) == (1), "logout still shuts the engine down once")
            #expect((account.clearCount) == (1), "logout still clears the grant once")
            #expect(await account.grantState() == .absent)
            #expect(!account.hasStoredGrant)
        }

        do {
            let engine = HarnessEngine()
            let account = HarnessAccount(hasGrant: true, authorization: .succeed)
            account.parkClear = true
            let player = PlaybackStore(
                environment: HarnessEnvironment.make(
                    engine: engine, account: account, clock: HarnessClock(sleep: .immediate)),
                feedback: TransientFeedbackPresenter(clock: HarnessClock(sleep: .immediate))
            )
            await player.restore()
            let start = player.accountStore.epoch

            let pendingRevocation = account.revoke()
            let logout = Task { await player.logout() }
            #expect((await waitUntil { account.isClearParked }) == true, "logout reaches grant clear")
            let duringTeardown = player.accountStore.epoch
            #expect((duringTeardown) == (start + 1), "the in-flight teardown already advanced AccountStore once")
            #expect((player.accountEpoch) == (duringTeardown), "projection matches during the parked teardown")
            #expect((player.state.accountEpoch) == (duringTeardown), "reducer already adopted the teardown epoch")
            #expect(
                (player.catalogSession.accountEpoch) == (duringTeardown), "catalog already observes the teardown epoch")
            #expect(
                (await waitUntil { await player.queueService.accountEpoch == duringTeardown }) == true,
                "QueueService already reset to the teardown epoch")

            let upgrade = Task { await player.runtime.handleGrantRevocation(pendingRevocation) }
            for _ in 0..<20 { await Task.yield() }
            #expect(
                (player.accountStore.epoch) == (duringTeardown),
                "an overlapping revocation does not advance the epoch again")
            #expect((player.accountEpoch) == (duringTeardown), "projection is unchanged after the stale revocation")
            #expect(
                (player.state.accountEpoch) == (duringTeardown), "reducer epoch is unchanged after the stale revocation"
            )

            account.completeClear()
            await logout.value
            await upgrade.value
            #expect((player.accountStore.epoch) == (start + 1), "the completed coalesced teardown still advanced once")
            #expect((account.clearCount) == (1), "grant clear still happens once")
            #expect((engine.count(.shutdown)) == (1), "engine shutdown still happens once")
        }

        do {
            let engine = HarnessEngine()
            let account = HarnessAccount(hasGrant: true, authorization: .succeed)
            let player = PlaybackStore(
                environment: HarnessEnvironment.make(
                    engine: engine, account: account, clock: HarnessClock(sleep: .immediate)),
                feedback: TransientFeedbackPresenter(clock: HarnessClock(sleep: .immediate))
            )
            await player.restore()
            let start = player.accountStore.epoch

            await player.shutdownForTermination()
            let afterStop = player.accountStore.epoch
            #expect((afterStop) == (start + 1), "termination advances AccountStore once")
            #expect((player.accountEpoch) == (afterStop), "PlaybackStore projects the termination epoch")
            #expect((player.state.accountEpoch) == (afterStop), "reducer adopts the termination epoch")
            #expect((player.catalogSession.accountEpoch) == (afterStop), "catalog observes the termination epoch")
            #expect((engine.count(.shutdown)) == (1), "termination shuts the engine down once")
            #expect((account.clearCount) == (0), "termination does not clear the reusable grant")

            await player.shutdownForTermination()
            #expect(
                (player.accountStore.epoch) == (afterStop), "a second termination is idempotent and does not bump again"
            )
            #expect((engine.count(.shutdown)) == (1), "a second termination does not shut down again")
        }

        do {
            let engine = HarnessEngine()
            let account = HarnessAccount(hasGrant: true, authorization: .succeed)
            let player = PlaybackStore(
                environment: HarnessEnvironment.make(
                    engine: engine, account: account, clock: HarnessClock(sleep: .immediate)),
                feedback: TransientFeedbackPresenter(clock: HarnessClock(sleep: .immediate))
            )
            await player.restore()
            _ = player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(uri: "spotify:track:prior", title: "Prior"),
                        transport: .paused,
                        timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                    )),
                source: .user
            )
            let prior = player.accountEpoch

            await player.logout()
            let current = player.accountStore.epoch
            #expect((current) != (prior), "logout replaced the prior identity")

            let staleSession = player.send(.session(.ready), source: .account, accountEpoch: prior)
            let staleQueue = await player.queueService.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 1,
                    trackURI: "spotify:track:stale",
                    next: HarnessFixtures.queueTracks([
                        QueueEntry(uri: "spotify:track:stale", provider: "connect", occurrence: 0)
                    ])),
                accountEpoch: prior, fallbackTrackURI: nil)
            #expect((!staleSession) == true, "a reducer send stamped with the prior epoch is rejected")
            #expect((staleQueue) == nil, "QueueService rejects the prior epoch after reset")
            #expect((player.state.currentTrack) == nil, "prior-epoch work cannot revive signed-out presentation")
            #expect((player.state.session) == (PlaybackSessionPhase.signedOut), "signed-out session is unchanged")
            #expect((player.accountEpoch) == (current), "inert work did not roll the epoch back")
            #expect(
                (player.accountEpoch) == (player.accountStore.epoch),
                "inert work did not drift the projection from AccountStore")
            #expect(
                (player.state.accountEpoch) == (current), "inert work did not drift reducer state from AccountStore")
        }

    }
}

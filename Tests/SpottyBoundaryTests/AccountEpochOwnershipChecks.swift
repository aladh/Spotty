import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

@Suite("Account Epoch Ownership")
struct AccountEpochOwnershipTests {
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

            let upgrade = Task { await player.handleGrantRevocation() }
            for _ in 0..<20 { await Task.yield() }
            #expect(
                (player.accountStore.epoch) == (duringTeardown),
                "an overlapping revocation does not advance the epoch again")
            #expect((player.accountEpoch) == (duringTeardown), "projection is unchanged after the upgrade")
            #expect((player.state.accountEpoch) == (duringTeardown), "reducer epoch is unchanged after the upgrade")

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
                [QueueEntry(uri: "spotify:track:stale", provider: "connect", occurrence: 0)],
                accountEpoch: prior,
                sourceRevision: 1,
                contextURI: "spotify:track:stale"
            )
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

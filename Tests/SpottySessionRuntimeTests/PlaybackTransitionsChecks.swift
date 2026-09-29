import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@Suite("Playback transitions")
@SessionRuntimeActor
struct PlaybackTransitionsTests {
    private let lifetime = PlaybackLifetime(accountEpoch: 1, engineGeneration: 0)

    enum RefusedTimeout: CaseIterable { case pastAccount, futureAccount, futureEngine, oldRevision }

    @Test(arguments: RefusedTimeout.allCases)
    func refusedTimeoutCannotWithdrawDispatchAuthority(reason: RefusedTimeout) throws {
        let (owner, id, permit) = try admittedQueue(clock: HarnessClock.sticky())
        let checkpoint = owner.apply(
            PlaybackEventEnvelope(accountEpoch: 1, engineEpoch: 0, source: .command, revision: 2, event: .notice(nil)),
            currentLifetime: lifetime)
        try #require(checkpoint.reduction.accepted)
        let account: UInt64 = reason == .pastAccount ? 0 : (reason == .futureAccount ? 2 : 1)
        let timeout = PlaybackEventEnvelope(
            accountEpoch: account, engineEpoch: reason == .futureEngine ? 1 : 0, source: .command,
            revision: reason == .oldRevision ? 1 : nil, event: .commandTimedOut(id: id))

        let refused = owner.apply(timeout, currentLifetime: lifetime)

        #expect(refused.reduction.accepted == false)
        #expect(refused.needsPublication == false)
        #expect(permit.claim() == true)
    }

    @Test
    func concurrentDispatchClaimsCommitOneReceiptEvenWhenTheIncomingEventIsRejected() async throws {
        let clock = HarnessClock.sticky()
        let (owner, id, permit) = try admittedQueue(clock: clock)
        let claims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { permit.claim() } }
            var count = 0
            for await claimed in group { if claimed { count += 1 } }
            return count
        }
        #expect(claims == 1)

        let stale = PlaybackEventEnvelope(accountEpoch: 0, engineEpoch: 0, source: .user, event: .notice(nil))
        let commit = owner.apply(stale, currentLifetime: lifetime)
        #expect(commit.reduction.accepted == false)
        #expect(commit.needsPublication == true)
        #expect(owner.state.intents.first { $0.command.id == id }?.dispatchedAt == clock.now())

        let repeated = owner.apply(stale, currentLifetime: lifetime)
        #expect(repeated.reduction.accepted == false)
        #expect(repeated.needsPublication == false, "The separately accepted receipt commits exactly once")
    }

    @Test(arguments: [false, true])
    func invalidationOnlyRevokesUnclaimedDispatch(claimFirst: Bool) throws {
        let clock = HarnessClock.sticky()
        let (owner, id, permit) = try admittedQueue(clock: clock)
        if claimFirst { #expect(permit.claim() == true) }
        owner.invalidateDispatches()
        #expect(permit.claim() == false)

        let stale = PlaybackEventEnvelope(accountEpoch: 0, engineEpoch: 0, source: .user, event: .notice(nil))
        let commit = owner.apply(stale, currentLifetime: lifetime)
        #expect(commit.needsPublication == claimFirst)
        #expect(owner.state.intents.first { $0.command.id == id }?.dispatchedAt == (claimFirst ? clock.now() : nil))
    }

    private func admittedQueue(clock: HarnessClock) throws -> (PlaybackTransitions, UUID, PlaybackDispatchPermit) {
        let owner = PlaybackTransitions(initialState: PlaybackState(accountEpoch: 1, session: .ready), clock: clock)
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .queue, expectedTransport: nil, startedAt: clock.now())
        let admission = owner.apply(
            PlaybackEventEnvelope(
                accountEpoch: 1, engineEpoch: 0, source: .command,
                event: .queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil))),
            currentLifetime: lifetime)
        try #require(admission.reduction.accepted)
        let candidate = owner.dispatchPermit(for: command.id, ifStillWanted: { true })
        let permit = try #require(candidate)
        return (owner, command.id, permit)
    }
}

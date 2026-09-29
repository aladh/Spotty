import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let engineCommandOutcomes: [(PlaybackEngineResult, PlaybackCommandFailure?)] = [
    (.ok, nil),
    (.error, .rejected),
    (PlaybackEngineResult(rawValue: -2), .reconnectRequired),
    (PlaybackEngineResult(rawValue: -3), .reconnectRequired),
    (.credentialsRejected, .unavailable),
    (.resumeMismatch, .resumeMismatch),
    (.resumeBusy, .rejected),
    (PlaybackEngineResult(rawValue: -99), .unavailable),
]

@Suite("Playback coordinator outcomes")
@SessionRuntimeActor
struct PlaybackCoordinatorOutcomeTests {
    @Test(arguments: engineCommandOutcomes)
    func engineResultsMapToTypedCommandOutcomes(
        engineResult: PlaybackEngineResult, expectedFailure: PlaybackCommandFailure?
    ) {
        expectOutcome(PlaybackCommandFailure.from(engineResult: engineResult), failure: expectedFailure)
        if engineResult == .credentialsRejected {
            #expect(engineResult.isCredentialsRejected)
            #expect(engineResult.requiresReconnect == false)
        }
    }

    @Test(arguments: engineCommandOutcomes)
    func localCommandReportsItsOutcome(
        engineResult: PlaybackEngineResult, expectedFailure: PlaybackCommandFailure?
    ) async throws {
        let engine = HarnessEngine(executeResult: engineResult)
        let remote = HarnessRemote()
        let coordinator = PlaybackCoordinator(local: engine, remote: remote)
        let (owner, permit) = try admittedPermit()
        defer { owner.invalidateDispatches() }

        let result = try await coordinator.performLocalCommand(.pause, permit: permit)

        expectOutcome(try #require(result), failure: expectedFailure)
        #expect(engine.operations.count == 1)
        guard case .pause? = engine.operations.first else {
            Issue.record("The coordinator must execute the admitted pause")
            return
        }
        #expect(remote.sendCount == 0)
    }

    @Test(arguments: [false, true])
    func remoteCommandReportsItsOutcome(shouldSucceed: Bool) async throws {
        let engine = HarnessEngine()
        let remote = HarnessRemote(send: shouldSucceed ? .succeed : .fail)
        let coordinator = PlaybackCoordinator(local: engine, remote: remote)
        let (owner, permit) = try admittedPermit()
        defer { owner.invalidateDispatches() }

        let result = try await coordinator.performRemoteCommand(
            { try await $0.send(.pause, from: "from", to: "to") }, permit: permit)

        expectOutcome(try #require(result), failure: shouldSucceed ? nil : .remoteRejected)
        #expect(remote.endpoints == [.pause])
        #expect(engine.operations.isEmpty)
    }

    @Test
    func cancellingAnEnteredRemoteCommandThrowsInsteadOfRejecting() async throws {
        let engine = HarnessEngine()
        let remote = HarnessRemote(send: .park)
        let coordinator = PlaybackCoordinator(local: engine, remote: remote)
        let (owner, permit) = try admittedPermit()
        defer { owner.invalidateDispatches() }
        let command = Task { @SessionRuntimeActor in
            try await coordinator.performRemoteCommand(
                { try await $0.send(.pause, from: "from", to: "to") }, permit: permit)
        }
        do {
            try await requireEventually(description: "Remote command entered its cancellation barrier") {
                remote.parkedSendCount == 1
            }
        } catch {
            command.cancel()
            _ = await command.result
            throw error
        }

        command.cancel()
        await #expect(throws: CancellationError.self) { try await command.value }
        #expect(remote.parkedSendCount == 0)
        #expect(remote.sendCount == 1)
        #expect(engine.operations.isEmpty)
    }

    @Test(arguments: [false, true])
    func revokedPermitCannotEnterEitherDependency(useRemote: Bool) async throws {
        let engine = HarnessEngine()
        let remote = HarnessRemote()
        let coordinator = PlaybackCoordinator(local: engine, remote: remote)
        let (owner, permit) = try admittedPermit()
        owner.invalidateDispatches()

        let result: Result<Void, PlaybackCommandFailure>?
        if useRemote {
            result = try await coordinator.performRemoteCommand(
                { try await $0.send(.pause, from: "from", to: "to") }, permit: permit)
        } else {
            result = try await coordinator.performLocalCommand(.pause, permit: permit)
        }

        #expect(result == nil)
        #expect(engine.operations.isEmpty)
        #expect(remote.sendCount == 0)
    }

    @Test(arguments: [false, true])
    func cancelledCallerCannotClaimOrEnterEitherDependency(useRemote: Bool) async throws {
        let engine = HarnessEngine()
        let remote = HarnessRemote()
        let coordinator = PlaybackCoordinator(local: engine, remote: remote)
        let (owner, permit) = try admittedPermit()
        defer { owner.invalidateDispatches() }
        // Inherit this actor so cancellation is established before the coordinator hop.
        let command = Task { @SessionRuntimeActor in
            if useRemote {
                return try await coordinator.performRemoteCommand(
                    { try await $0.send(.pause, from: "from", to: "to") }, permit: permit)
            }
            return try await coordinator.performLocalCommand(.pause, permit: permit)
        }
        command.cancel()

        await #expect(throws: CancellationError.self) { try await command.value }
        #expect(engine.operations.isEmpty)
        #expect(remote.sendCount == 0)
        #expect(permit.claim(), "Cancellation before dispatch must leave the permit unclaimed")
    }

    /// The real transition owner admits this capability; these coordinator checks need no
    /// account, queue service, presentation subscriber, or whole session lifetime.
    private func admittedPermit() throws -> (PlaybackTransitions, PlaybackDispatchPermit) {
        let clock = HarnessClock.sticky()
        let owner = PlaybackTransitions(initialState: PlaybackState(accountEpoch: 1, session: .ready), clock: clock)
        let command = PendingPlaybackCommand(
            id: UUID(), kind: .queue, expectedTransport: nil, startedAt: clock.now())
        let admission = owner.apply(
            PlaybackEventEnvelope(
                accountEpoch: 1, engineEpoch: 0, source: .command,
                event: .queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil))),
            currentLifetime: PlaybackLifetime(accountEpoch: 1, engineGeneration: 0))
        try #require(admission.reduction.accepted)
        let candidate = owner.dispatchPermit(for: command.id, ifStillWanted: { true })
        let permit = try #require(candidate)
        return (owner, permit)
    }

    private func expectOutcome(_ outcome: Result<Void, PlaybackCommandFailure>, failure: PlaybackCommandFailure?) {
        switch outcome {
        case .success: #expect(failure == nil)
        case let .failure(actual): #expect(actual == failure)
        }
    }
}

import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@SessionRuntimeActor
private final class DispatchRoutingFixture {
    let engine = HarnessEngine()
    let remote = HarnessRemote()
    let gate = HarnessEngineGate(result: .ok)
    let runtime: PlaybackSessionRuntime
    private var settlements: [PlaybackEffectSettlement] = []
    private var remotePermitRegistered = false

    init(blockEngine: Bool) {
        if blockEngine { engine.onExecute = { [gate] _ in gate.enter() } }
        runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(engine: engine, remote: remote))
    }

    func seedLocal(isIdle: Bool) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: !isIdle)],
                        localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: isIdle ? "spotify:track:idle" : "spotify:track:dispatch",
                            title: isIdle ? "Idle" : "Dispatch", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: .paused,
                        timing: PlaybackTiming(position: isIdle ? 0 : 10, duration: 200, anchoredAt: HarnessDates.fixed)
                    )),
                source: .user))
    }

    func publishRemoteOwner(id: String, revision: UInt64) throws {
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "This Mac", type: "computer"),
                            PlaybackDevice(id: id, name: id, type: "speaker", isActive: true),
                        ], localDeviceID: "mac", revision: revision)), source: .engineDevices, revision: revision))
    }

    func occupyCoordinator() async throws {
        runtime.toggleShuffle()
        try captureCommand(.options)
        try await requireEventually(description: "Local command occupies the coordinator") { gate.enteredCount == 1 }
    }

    func queueRemotePause() async throws {
        try publishRemoteOwner(id: "speaker-a", revision: 2)
        runtime.submitCommand(
            .pause, failureMessage: "Could not pause",
            dispatchGuard: { [weak self] in
                self?.remotePermitRegistered = true
                return true
            })
        try captureCommand(.transport)
        try await requireEventually(description: "Remote pause registers its permit behind the blocked coordinator") {
            remotePermitRegistered
        }
    }

    func playSelectedTrack() throws {
        runtime.submitCommand(
            .playTracks([HarnessFixtures.track(uri: "spotify:track:idle")]), failureMessage: "Could not play")
        try captureCommand(.transport)
    }

    private func captureCommand(_ kind: PlaybackCommandKind) throws {
        let command = try #require(runtime.state.pendingCommands[kind])
        let settlement = try #require(runtime.effects.settlement(of: .command(command.id)))
        settlements.append(settlement)
    }

    func settleCommands() async {
        for settlement in settlements { await settlement.wait() }
    }

    func cleanUp() async {
        let cancelled = runtime.effects.cancelAccountScoped()
        gate.close()
        await settleCommands()
        for settlement in cancelled.values { await settlement.wait() }
        await runtime.shutdownForTermination()
    }
}

@SessionRuntimeActor
private func withDispatchRouting(
    blockEngine: Bool = false, isIdle: Bool = false,
    _ body: (DispatchRoutingFixture) async throws -> Void
) async throws {
    let fixture = DispatchRoutingFixture(blockEngine: blockEngine)
    do {
        try fixture.seedLocal(isIdle: isIdle)
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

private enum RoutingChange { case timing, owner, engine, account }
private enum RoutingFixtureExit: Error { case prerequisiteFailed }

@Suite("Playback dispatch routing")
@SessionRuntimeActor
struct PlaybackDispatchRoutingTests {
    @Test func aSameRouteRemoteCommandSurvivesATimingPublication() async throws {
        try await exerciseQueuedRemote(after: .timing)
    }

    @Test func aRemoteCommandIsDroppedWhenOwnershipHandsOff() async throws {
        try await exerciseQueuedRemote(after: .owner)
    }

    @Test func aRemoteCommandIsDroppedOnEngineGenerationCancellation() async throws {
        try await exerciseQueuedRemote(after: .engine)
    }

    @Test func aRemoteCommandIsDroppedOnAccountCancellation() async throws {
        try await exerciseQueuedRemote(after: .account)
    }

    private func exerciseQueuedRemote(after change: RoutingChange) async throws {
        try await withDispatchRouting(blockEngine: true) { fixture in
            try await fixture.occupyCoordinator()
            try await fixture.queueRemotePause()
            let runtime = fixture.runtime
            switch change {
            case .timing:
                try #require(runtime.setTiming(position: 11))
            case .owner:
                try fixture.publishRemoteOwner(id: "speaker-b", revision: 3)
            case .engine:
                try #require(
                    runtime.send(
                        .reset(session: .recovering), source: .engineConnection,
                        engineEpoch: runtime.engineGeneration &+ 1))
            case .account:
                try #require(
                    runtime.send(
                        .reset(session: .signedOut), source: .account, accountEpoch: runtime.accountEpoch &+ 1))
            }
            fixture.gate.finish(with: .ok)
            await fixture.settleCommands()
            #expect(runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.remote.sendCount == (change == .timing ? 1 : 0))
            #expect(fixture.engine.operations.count == 1)
            if change == .timing { #expect(fixture.remote.endpoints == [.pause]) }
            if change == .owner {
                #expect(runtime.semantic.notice == nil, "Refusing an undispatched stale route has no transport notice")
            }
        }
    }

    @Test func firstIdleLocalPlayKeepsItsChosenTrackTarget() async throws {
        try await withDispatchRouting(isIdle: true) { fixture in
            try fixture.playSelectedTrack()
            await fixture.settleCommands()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.remote.sendCount == 0)
            #expect(fixture.engine.operations.count == 1)
            guard case let .playTracks(uris)? = fixture.engine.operations.first else {
                Issue.record("Idle play must use the local play operation")
                return
            }
            #expect(uris == ["spotify:track:idle"])
        }
    }

    @Test func idleLocalOwnershipConfirmationKeepsQueuedLocalPermit() async throws {
        try await withDispatchRouting(isIdle: true) { fixture in
            let runtime = fixture.runtime
            let command = PendingPlaybackCommand(
                id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
            try #require(
                runtime.send(
                    .queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command))
            let candidate = runtime.makePlaybackDispatchPermit(intentID: command.id, ifStillWanted: { true })
            let permit = try #require(candidate)
            try #require(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true)],
                            localDeviceID: "mac", revision: 2)), source: .engineDevices, revision: 2))
            #expect(permit.claim(), "Confirming the same idle local destination keeps the queued permit valid")
        }
    }

    @Test(arguments: [false, true])
    func thrownPrerequisiteJoinsBlockedAndQueuedCommands(queueRemote: Bool) async throws {
        var captured: DispatchRoutingFixture?
        do {
            try await withDispatchRouting(blockEngine: true) { fixture in
                captured = fixture
                try await fixture.occupyCoordinator()
                if queueRemote { try await fixture.queueRemotePause() }
                throw RoutingFixtureExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch RoutingFixtureExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(fixture.remote.sendCount == 0)
        #expect(fixture.gate.enter() == .error, "Cleanup also releases any future gate caller")
    }
}

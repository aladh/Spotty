@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottySessionRuntime
import SpottyRuntimeContracts
@testable import SpottyEngineAdapter

private enum LifecycleKind: String, CaseIterable {
    case transport
    case options
    case transfer

    var commandKind: PlaybackCommandKind {
        switch self {
        case .transport: .transport
        case .options: .options
        case .transfer: .transfer
        }
    }

    var action: String {
        switch self {
        case .transport: "Could not play that Spotify URI"
        case .options: "Could not update repeat"
        case .transfer: "Could not move playback to Speaker B"
        }
    }
}

private enum InitialOwner: String, CaseIterable {
    case local
    case remote
}

private let lifecycleTrackA = CurrentTrack(
    uri: "spotify:track:a",
    title: "A",
    artist: "Artist",
    duration: 200,
    metadataSource: .catalog
)
private let lifecycleSelectionB = HarnessFixtures.track(uri: "spotify:track:b", title: "B", duration: 180)
private let lifecycleTrackB = CurrentTrack(
    uri: lifecycleSelectionB.uri,
    title: lifecycleSelectionB.title,
    artist: lifecycleSelectionB.artist,
    duration: lifecycleSelectionB.duration,
    metadataSource: .catalog
)
private let lifecycleTrackC = CurrentTrack(
    uri: "spotify:track:c",
    title: "C",
    artist: "Artist",
    duration: 160,
    metadataSource: .catalog
)
private let lifecycleTiming = PlaybackTiming(
    position: 40,
    duration: 200,
    anchoredAt: Date(timeIntervalSince1970: 1_799_999_990)
)
private let lifecycleOwnerA = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true)
)
private let lifecycleRemoteB = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true)
)
private let lifecycleOwnerC = PlaybackOwner.remote(
    PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
)
@SessionRuntimeActor
private func seedOwner(_ player: PlaybackSessionRuntime, _ owner: InitialOwner) {
    _ = player.send(.session(.ready), source: .account)
    switch owner {
    case .local:
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [
                        PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true),
                        PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                    ],
                    localDeviceID: "mac",
                    revision: 1
                )),
            source: .engineDevices,
            revision: 1
        )
    case .remote:
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [
                        PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                        PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                        PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                        PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"),
                    ],
                    localDeviceID: "mac",
                    revision: 1
                )),
            source: .engineDevices,
            revision: 1
        )
        _ = player.send(.owner(lifecycleOwnerA), source: .command)
    }
    _ = player.send(
        .presentation(
            PlaybackPresentationSnapshot(
                currentTrack: lifecycleTrackA,
                transport: .playing,
                timing: lifecycleTiming
            )),
        source: .user
    )
    _ = player.send(.options(PlaybackOptions(shuffle: false, repeatMode: .off)), source: .user)
}

@SessionRuntimeActor
private func startLifecycleCommand(
    _ player: PlaybackSessionRuntime,
    kind: LifecycleKind,
    completion: @escaping @SessionRuntimeActor (Bool) -> Void
) {
    let request: PlaybackSessionRuntime.CommandRequest
    switch kind {
    case .transport:
        request = .playTrack(lifecycleSelectionB)
    case .options:
        request = .repeatMode(.context)
    case .transfer:
        request = .transfer(ConnectDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: false))
    }
    player.submitCommand(request, failureMessage: kind.action, completion: completion)
}

/// Prove each lifecycle matrix entry executes its real operation, including transfer from
/// remote ownership, which still belongs to the engine rather than the Connect HTTP client.
@SessionRuntimeActor
private func expectLifecycleOperation(
    kind: LifecycleKind, owner: InitialOwner, local: HarnessEngine, remote: HarnessRemote
) {
    if kind == .transfer || owner == .local {
        #expect(local.operations.count == 1)
        #expect(remote.sendCount == 0)
        switch (kind, local.operations.first) {
        case let (.transport, .playURI(uri)):
            #expect(uri == lifecycleTrackB.uri)
        case let (.options, .repeatOptions(plan)):
            #expect(plan.mutations == [RepeatFlagMutation(flag: .context, enabled: true)])
        case let (.transfer, .transferToDevice(id)):
            #expect(id == "speaker-b")
        default:
            Issue.record("The admitted request must execute its matching engine operation")
        }
    } else {
        #expect(local.operations.isEmpty)
        #expect(remote.sendCount == 1)
        switch kind {
        case .transport:
            #expect(remote.commands.first?.endpoint == .play)
            #expect(remote.commands.first?.context?.uri == lifecycleTrackB.uri)
        case .options:
            #expect(remote.commands.first?.endpoint == .repeatContext)
            if case let .boolean(enabled)? = remote.commands.first?.value {
                #expect(enabled)
            } else {
                Issue.record("Repeat must send the admitted flag value")
            }
        case .transfer:
            Issue.record("Transfer must execute through the engine")
        }
    }
}

@SessionRuntimeActor
private func observeRequestedState(_ player: PlaybackSessionRuntime, kind: LifecycleKind, revision: UInt64) {
    switch kind {
    case .transport:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackB.uri,
                    timing: PlaybackTiming(
                        position: 0, duration: 180, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .options:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackA.uri,
                    timing: lifecycleTiming,
                    repeatMode: .context,
                    repeatFlags: RepeatMode.context.flags
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .transfer:
        _ = player.send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: .ready,
                    owner: lifecycleRemoteB,
                    localDeviceID: "mac"
                )),
            source: .engineConnection,
            revision: revision
        )
    }
}

@SessionRuntimeActor
private func supersede(_ player: PlaybackSessionRuntime, kind: LifecycleKind, revision: UInt64) {
    switch kind {
    case .transport:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackC.uri,
                    timing: PlaybackTiming(
                        position: 0, duration: 160, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .options:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackA.uri,
                    timing: lifecycleTiming,
                    repeatMode: .track,
                    repeatFlags: RepeatMode.track.flags
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .transfer:
        _ = player.send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: .ready,
                    owner: lifecycleOwnerC,
                    localDeviceID: "mac"
                )),
            source: .engineConnection,
            revision: revision
        )
    }
}

// Ownership and dispatch differ: transfer always uses the engine, even from remote ownership.
private struct LifecycleCase: Sendable, CustomTestStringConvertible {
    let kind: LifecycleKind
    let owner: InitialOwner

    static var all: [Self] {
        InitialOwner.allCases.flatMap { owner in LifecycleKind.allCases.map { Self(kind: $0, owner: owner) } }
    }
    var usesEngine: Bool { kind == .transfer || owner == .local }
    var testDescription: String { "\(kind.rawValue) from \(owner.rawValue)" }
}

@SessionRuntimeActor
private final class LifecycleFixture {
    let scenario: LifecycleCase
    let local = HarnessEngine()
    let remote = HarnessRemote()
    let account = HarnessAccount()
    let clock = HarnessClock.parked()
    let engineGate = HarnessEngineGate()
    let remoteGate = HarnessResponseGate<Void>(cancellation: .ignored)
    let completions = RuntimeCallbackRecorder<Bool>()
    let runtime: PlaybackSessionRuntime
    private var settlements: [PlaybackEffectSettlement] = []

    init(_ scenario: LifecycleCase) {
        self.scenario = scenario
        local.onExecute = { [engineGate] _ in engineGate.enter() }
        remote.onSend = { [remoteGate] _, _, _ in try await remoteGate.wait() }
        runtime = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(engine: local, remote: remote, account: account, clock: clock))
        seedOwner(runtime, scenario.owner)
    }

    // Admission and exact worker capture share one actor turn, before dispatch can start.
    func admit(sourceLocation: SourceLocation = #_sourceLocation) throws -> (
        id: UUID, settlement: PlaybackEffectSettlement
    ) {
        startLifecycleCommand(runtime, kind: scenario.kind) { [completions] in completions.append($0) }
        let command = try #require(
            runtime.state.pendingCommands[scenario.kind.commandKind], sourceLocation: sourceLocation)
        let settlement = try #require(
            runtime.effects.settlement(of: .command(command.id)), sourceLocation: sourceLocation)
        settlements.append(settlement)
        return (command.id, settlement)
    }

    func requireDispatch(count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await requireEventually(
            description: "\(scenario.testDescription) dispatch \(count)", sourceLocation: sourceLocation
        ) {
            if self.scenario.usesEngine { return self.engineGate.enteredCount == count }
            return self.remoteGate.requestCount == count && self.remoteGate.waiterCount == 1
        }
    }

    func reply(_ result: PlaybackEngineResult) {
        if scenario.usesEngine {
            engineGate.finish(with: result)
        } else if result.isOK {
            remoteGate.finish(())
        } else {
            remoteGate.resolve(.failure(HarnessFailure.unavailable))
        }
    }

    func replaceGeneration() {
        _ = runtime.send(
            .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
            source: .engineConnection, revision: 1, engineEpoch: runtime.engineGeneration + 1)
    }

    func closeGates() {
        engineGate.close()
        remoteGate.close()
    }

    func cleanUp() async {
        let cancelled = runtime.effects.cancelAccountScoped()
        closeGates()
        clock.releaseAll()
        await runtime.shutdownForTermination()
        // Cancelled entries may no longer be in the registry. Join every captured worker too.
        for settlement in settlements { await settlement.wait() }
        for settlement in cancelled.values { await settlement.wait() }
    }
}

@SessionRuntimeActor
private func withLifecycleFixture(
    _ scenario: LifecycleCase,
    body: (LifecycleFixture) async throws -> Void
) async throws {
    let fixture = LifecycleFixture(scenario)
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

private enum LifecycleFixtureExit: Error {
    case prerequisiteFailed
}

@Suite("Playback command lifecycle", .serialized)
@SessionRuntimeActor
struct PlaybackCommandLifecycleTests {
    @Test(arguments: LifecycleCase.all)
    private func failedPrerequisiteStillJoinsBlockedWork(_ scenario: LifecycleCase) async throws {
        var captured: LifecycleFixture?
        do {
            try await withLifecycleFixture(scenario) { fixture in
                captured = fixture
                _ = try fixture.admit()
                try await fixture.requireDispatch()
                throw LifecycleFixtureExit.prerequisiteFailed
            }
            Issue.record("The fixture must propagate the prerequisite failure after cleanup")
        } catch LifecycleFixtureExit.prerequisiteFailed {
            // Exercise the same thrown exit used by a failed #require without recording an issue.
        }
        let fixture = try #require(captured)
        #expect(fixture.runtime.isTearingDown)
        #expect(fixture.runtime.state.pendingCommands.isEmpty)
        #expect(fixture.completions.snapshot == [false])
        #expect(fixture.remoteGate.waiterCount == 0)
        #expect(fixture.clock.waiterCount == 0)
    }

    @Test(arguments: [LifecycleKind.transport, .options])
    private func unavailableRouteRefusesWithoutAdmission(_ kind: LifecycleKind) async {
        let local = HarnessEngine()
        let remote = HarnessRemote()
        let runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(engine: local, remote: remote))
        _ = runtime.send(.session(.ready), source: .account)
        _ = runtime.send(.owner(.uncertain(nil)), source: .command)
        let completions = RuntimeCallbackRecorder<Bool>()
        startLifecycleCommand(runtime, kind: kind) { completions.append($0) }
        #expect(completions.snapshot == [false])
        #expect(runtime.state.pendingCommands.isEmpty)
        #expect(local.executeCount == 0 && remote.sendCount == 0)
        await runtime.shutdownForTermination()
    }

    @Test(arguments: LifecycleCase.all)
    private func successExecutesTheRequestedOperation(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [true])
            #expect(fixture.runtime.state.notice == nil)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.account.authorizeCount == 0)
            expectLifecycleOperation(
                kind: scenario.kind, owner: scenario.owner, local: fixture.local, remote: fixture.remote)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func rejectionReportsTheActionNotice(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            fixture.reply(.error)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [false])
            #expect(fixture.runtime.state.notice?.message == scenario.kind.action)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
        }
    }

    @Test(arguments: LifecycleCase.all.filter(\.usesEngine))
    private func reconnectRequiredRebuildsWithoutReauthorizing(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            fixture.reply(PlaybackEngineResult(rawValue: -2))
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [false])
            #expect(fixture.runtime.state.notice?.message == scenario.kind.action)
            try await requireEventually { fixture.local.forceReconnectCount == 1 }
            #expect(fixture.account.authorizeCount == 0)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func duplicatePreservesTheOriginalAdmission(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            let duplicateCompletions = RuntimeCallbackRecorder<Bool>()
            startLifecycleCommand(fixture.runtime, kind: scenario.kind) { duplicateCompletions.append($0) }
            #expect(duplicateCompletions.snapshot == [false])
            #expect(fixture.runtime.state.pendingCommands[scenario.kind.commandKind]?.id == running.id)
            try await fixture.requireDispatch()
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [true])
            #expect(fixture.local.executeCount + fixture.remote.sendCount == 1)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func matchingObservationSurvivesTransportFailure(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            observeRequestedState(fixture.runtime, kind: scenario.kind, revision: 1)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            // Ownership alone reconciles a transfer's presentation, but does not prove full
            // intent confirmation of its retained track and position.
            #expect(fixture.runtime.state.transportCommandResolutions[running.id] == .confirmed)
            fixture.reply(.error)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [true])
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func supersessionSuppressesLateFailure(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            supersede(fixture.runtime, kind: scenario.kind, revision: 1)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            fixture.reply(.error)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot.isEmpty)
            #expect(fixture.runtime.state.notice == nil)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func generationReplacementBeforeDispatchRevokesTheRequest(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            fixture.replaceGeneration()
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            // A regression dispatching after invalidation must fail instead of blocking cleanup.
            fixture.closeGates()
            await running.settlement.wait()
            #expect(fixture.engineGate.enteredCount == 0 && fixture.remote.sendCount == 0)
            #expect(fixture.completions.snapshot.isEmpty)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func generationReplacementAfterDispatchIgnoresTheReturn(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            fixture.replaceGeneration()
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot.isEmpty)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func cancellationRollsBackOnceAndAllowsReadmission(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let prior = fixture.runtime.state
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            _ = try #require(fixture.runtime.effects.cancel(.command(running.id)))
            #expect(fixture.completions.snapshot == [false])
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.runtime.state.notice == nil)
            #expect(fixture.runtime.state.transport == prior.transport)
            #expect(fixture.runtime.state.timing == prior.timing)
            #expect(fixture.runtime.state.currentTrack == prior.currentTrack)
            #expect(fixture.runtime.state.options == prior.options)
            #expect(fixture.runtime.state.owner == prior.owner)
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot == [false])

            let next = try fixture.admit()
            #expect(next.id != running.id)
            try await fixture.requireDispatch(count: 2)
            fixture.reply(.ok)
            await next.settlement.wait()
            #expect(fixture.completions.snapshot == [false, true])
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func cancellationAfterMatchingObservationPreservesTruth(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            observeRequestedState(fixture.runtime, kind: scenario.kind, revision: 1)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            _ = try #require(fixture.runtime.effects.cancel(.command(running.id)))
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot.isEmpty)
            #expect(fixture.runtime.state.notice == nil)
            switch scenario.kind {
            case .transport: #expect(fixture.runtime.state.currentTrack?.uri == lifecycleTrackB.uri)
            case .options: #expect(fixture.runtime.state.options.repeatMode == .context)
            case .transfer: #expect(fixture.runtime.state.owner == lifecycleRemoteB)
            }
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func cancellationAfterSupersessionPreservesNewerTruth(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            supersede(fixture.runtime, kind: scenario.kind, revision: 1)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            _ = try #require(fixture.runtime.effects.cancel(.command(running.id)))
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.completions.snapshot.isEmpty)
            #expect(fixture.runtime.state.notice == nil)
            switch scenario.kind {
            case .transport: #expect(fixture.runtime.state.currentTrack?.uri == lifecycleTrackC.uri)
            case .options: #expect(fixture.runtime.state.options.repeatMode == .track)
            case .transfer: #expect(fixture.runtime.state.owner == lifecycleOwnerC)
            }
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func cancellationAfterGenerationReplacementNeverDispatches(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            fixture.replaceGeneration()
            _ = try #require(fixture.runtime.effects.cancel(.command(running.id)))
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            fixture.closeGates()
            await running.settlement.wait()
            #expect(fixture.engineGate.enteredCount == 0 && fixture.remote.sendCount == 0)
            #expect(fixture.completions.snapshot.isEmpty)
        }
    }

    @Test(arguments: LifecycleCase.all)
    private func terminationFencesTheEnteredCommand(_ scenario: LifecycleCase) async throws {
        try await withLifecycleFixture(scenario) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            let shutdown = Task { await fixture.runtime.shutdownForTermination() }
            try await requireEventually { fixture.runtime.isTearingDown }
            fixture.reply(.ok)
            await shutdown.value
            await running.settlement.wait()
            #expect(fixture.completions.snapshot.isEmpty)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
        }
    }

    @Test
    func observationDeadlineMakesLateTransportReturnInert() async throws {
        try await withLifecycleFixture(LifecycleCase(kind: .transport, owner: .remote)) { fixture in
            let running = try fixture.admit()
            try await fixture.requireDispatch()
            try await requireEventually { fixture.clock.requestedSleeps.contains(8) }
            #expect(!fixture.runtime.send(.commandFinished(id: UUID(), accepted: true, notice: nil), source: .command))
            #expect(fixture.runtime.state.intents.last?.outcome == .dispatched)
            fixture.clock.releaseAll()
            try await requireEventually { fixture.runtime.state.intents.last?.outcome == .timedOut }
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            fixture.reply(.ok)
            await running.settlement.wait()
            #expect(fixture.runtime.state.intents.last?.outcome == .timedOut)
            #expect(fixture.completions.snapshot == [false])
        }
    }
}

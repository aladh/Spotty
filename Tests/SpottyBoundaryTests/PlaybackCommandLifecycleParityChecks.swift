import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

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

private enum LifecycleRoute: String, CaseIterable {
    case local
    case remote
}

/// A remote client whose `send` blocks until the check releases it, mirroring the boundary
/// suite's original gated fixture exactly: unlike `HarnessRemote`'s `.park`, cancelling the
/// command's task does not unblock this on its own, so a check must call `finish(success:)`
/// explicitly even after cancelling the command it is waiting on.
private final class GatedRemoteClient: RemotePlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var pendingResult: Result<Void, any Error>?
    private var storedSendCount = 0
    private var storedCompletedCount = 0

    var sendCount: Int {
        lock.withLock { storedSendCount }
    }

    var completedCount: Int {
        lock.withLock { storedCompletedCount }
    }

    func finish(success: Bool) {
        let result: Result<Void, any Error> = success ? .success(()) : .failure(HarnessFailure.unavailable)
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            let waiting = continuation
            continuation = nil
            if waiting == nil { pendingResult = result }
            return waiting
        }
        waiting?.resume(with: result)
    }

    private func markCompleted() {
        lock.withLock { storedCompletedCount += 1 }
    }

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        defer { markCompleted() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let pending: Result<Void, any Error>? = lock.withLock {
                storedSendCount += 1
                if let pendingResult {
                    self.pendingResult = nil
                    return pendingResult
                }
                self.continuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(with: pending)
            }
        }
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        HarnessFixtures.metadata(uri: uri)
    }
}

/// The URI of the last `.playURI` operation an engine executed, for checks that used to read the
/// old fixture's dedicated `playedURI` property.
private func playedURI(_ engine: HarnessEngine) -> String? {
    engine.operations.compactMap { operation -> String? in
        if case let .playURI(uri) = operation { return uri }
        return nil
    }.last
}

private let lifecycleTrackA = CurrentTrack(
    uri: "spotify:track:a",
    title: "A",
    artist: "Artist",
    duration: 200,
    metadataSource: .catalog
)
private let lifecycleTrackB = CurrentTrack(
    uri: "spotify:track:b",
    title: "B",
    artist: "Artist",
    duration: 180,
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
private let lifecycleExpectedB = PlaybackOwner.uncertain(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker")
)
private let lifecycleRemoteB = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true)
)
private let lifecycleOwnerC = PlaybackOwner.remote(
    PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
)
private let lifecycleRepeatPlan = RepeatTransitionPlan.planning(
    from: RepeatMode.off.flags,
    to: RepeatMode.context.flags
)

@MainActor
private func seedRoute(_ player: PlaybackStore, _ route: LifecycleRoute) {
    _ = player.send(.session(.ready), source: .account)
    switch route {
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

@MainActor
private func startLifecycleCommand(
    _ player: PlaybackStore,
    kind: LifecycleKind,
    completion: @escaping @MainActor (Bool) -> Void
) {
    switch kind {
    case .transport:
        player.performRoutedCommand(
            kind.action,
            expecting: true,
            expectedTiming: PlaybackTiming(
                position: 0, duration: 180, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)),
            expectedTrack: lifecycleTrackB,
            local: .playURI(lifecycleTrackB.uri),
            remote: .play(uri: lifecycleTrackB.uri),
            completion: completion
        )
    case .options:
        player.performRoutedOperation(
            kind.action,
            kind: .options,
            expectedRepeatFlags: RepeatMode.context.flags,
            local: .repeatOptions(lifecycleRepeatPlan),
            remote: { api, from, to in
                try await RepeatTransitionApplication.applyRemote(lifecycleRepeatPlan) { mutation in
                    try await api.send(.repeatMutation(mutation), from: from, to: to)
                }
            },
            completion: completion
        )
    case .transfer:
        player.performRoutedOperation(
            kind.action,
            kind: .transfer,
            expectedOwner: lifecycleExpectedB,
            local: .transferToDevice("speaker-b"),
            remote: { api, from, to in try await api.send(.pause, from: from, to: to) },
            completion: completion
        )
    }
}

@MainActor
private func waitForLifecycleDispatch(
    route: LifecycleRoute,
    local: HarnessEngineGate,
    remote: GatedRemoteClient
) async -> Bool {
    await waitUntil {
        if route == .local { return local.enteredCount == 1 }
        return remote.sendCount >= 1
    }
}

@MainActor
private func confirm(_ player: PlaybackStore, kind: LifecycleKind, revision: UInt64) {
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

@MainActor
private func supersede(_ player: PlaybackStore, kind: LifecycleKind, revision: UInt64) {
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

@Suite("Playback Command Lifecycle Parity")
struct PlaybackCommandLifecycleParityTests {
    @Test @MainActor
    func lostObservationDeadlineDoesNotLetLateReturnSettleAgain() async {
        let clock = CooperativeParkedClock()
        let remote = GatedRemoteClient()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(
                engine: HarnessEngine(executeResult: .ok), remote: remote, clock: clock))
        seedRoute(player, .remote)
        var completions: [Bool] = []
        startLifecycleCommand(player, kind: .transport) { completions.append($0) }
        #expect(await waitUntil { remote.sendCount == 1 })
        #expect(await waitUntil { clock.requestedSleeps.contains(8) })
        #expect(!player.send(.commandFinished(id: UUID(), accepted: true, notice: nil), source: .command))
        #expect(player.state.intents.last?.outcome == .dispatched)
        let id = player.state.intents.last!.command.id
        let settlement = player.effects.settlement(of: .command(id))
        clock.releaseAll()
        #expect(await waitUntil { player.state.intents.last?.outcome == .timedOut })
        #expect(player.state.pendingCommands.isEmpty)
        remote.finish(success: true)
        await settlement?.wait()
        #expect(player.state.intents.last?.outcome == .timedOut)
        #expect(completions == [false])
        player.effects.cancelAccountScoped()
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor
    func idleStartupPlayUsesLocalEngineWithoutSelection(resume: Bool, hasResumeContext: Bool) async {
        let local = HarnessEngine(resumeContextURI: hasResumeContext ? "spotify:playlist:retained" : nil)
        local.onExecute = { operation in
            if case let .resume(plan) = operation, plan.targets().isEmpty { return .error }
            return .ok
        }
        let remote = HarnessRemote()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: local, remote: remote))
        _ = player.send(.session(.ready), source: .account)
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer")],
                    localDeviceID: "mac", revision: 1)),
            source: .engineDevices, revision: 1)
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .paused, trackURI: lifecycleTrackA.uri, timing: lifecycleTiming)),
            source: .enginePlayback, revision: 1)
        _ = player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: lifecycleTrackA, transport: .paused, timing: lifecycleTiming)),
            source: .user)
        #expect(player.state.owner == .uncertain(nil))
        #expect(player.defaultLocalPlaybackDevice?.id == "mac")
        #expect(!player.isActiveDevice)
        #expect(local.executeCount == 0, "joining and projecting Connect must stay silent")
        #expect(player.commandRoute == .needsDeviceSelection, "non-play controls retain ownership routing")
        let optionsID = UUID()
        _ = player.send(
            .commandStarted(
                PendingPlaybackCommand(
                    id: optionsID, kind: .options, expectedTransport: nil, startedAt: lifecycleTiming.anchoredAt)),
            source: .command)
        #expect(player.defaultLocalPlaybackDevice == nil, "unavailable commands must not advertise readiness")
        _ = player.send(.commandFinished(id: optionsID, accepted: false, notice: nil), source: .command)
        #expect(player.defaultLocalPlaybackDevice?.id == "mac")

        if resume {
            player.togglePlayback()
        } else {
            player.play(uri: "spotify:track:new")
        }
        let finished = await waitUntil {
            local.executeCount == 1 && player.state.pendingCommands[.transport] == nil
        }
        #expect(finished)
        #expect(player.transientCommandError == nil)
        let expectedURI: String? =
            resume && hasResumeContext ? nil : (resume ? lifecycleTrackA.uri : "spotify:track:new")
        #expect(playedURI(local) == expectedURI)
        #expect(remote.sendCount == 0)
        await player.shutdownForTermination()
        #expect(player.defaultLocalPlaybackDevice == nil)
    }

    @Test
    @MainActor
    func testPlaybackCommandLifecycleParity() async {
        do {
            for kind in LifecycleKind.allCases {
                let player = HarnessEnvironment.makePlaybackStore(
                    HarnessEnvironment.make(
                        engine: HarnessEngine(executeResult: .ok),
                        remote: HarnessRemote()
                    )
                )
                _ = player.send(.session(.ready), source: .account)
                _ = player.send(.owner(.uncertain(nil)), source: .command)
                var completions: [Bool] = []
                startLifecycleCommand(player, kind: kind) { completions.append($0) }
                #expect((completions) == ([false]), "\(kind.rawValue) waiting route completes immediately as failure")
                #expect(
                    (player.state.pendingCommands.isEmpty) == true,
                    "\(kind.rawValue) waiting route does not create a pending command")
                await player.shutdownForTermination()
            }
        }

        do {
            for route in LifecycleRoute.allCases {
                for kind in LifecycleKind.allCases {
                    let label = "\(route.rawValue) \(kind.rawValue)"

                    let successAccount = HarnessAccount()
                    let success = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(
                            engine: HarnessEngine(executeResult: .ok),
                            remote: HarnessRemote(),
                            account: successAccount
                        )
                    )
                    seedRoute(success, route)
                    var successCompletions: [Bool] = []
                    startLifecycleCommand(success, kind: kind) { successCompletions.append($0) }
                    let successFinished = await waitUntil { !successCompletions.isEmpty }
                    #expect((successFinished) == true, "\(label) success finishes")
                    #expect((successCompletions) == ([true]), "\(label) confirmation-free success completion")
                    #expect((success.transientCommandError) == nil, "\(label) success has no command notice")
                    #expect((successAccount.authorizeCount) == (0), "\(label) success does not reconnect")
                    #expect(
                        (success.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) success leaves no pending command")
                    await success.shutdownForTermination()

                    let rejected = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(
                            engine: HarnessEngine(executeResult: .error),
                            remote: HarnessRemote(send: .fail)
                        )
                    )
                    seedRoute(rejected, route)
                    var rejectedCompletions: [Bool] = []
                    startLifecycleCommand(rejected, kind: kind) { rejectedCompletions.append($0) }
                    let rejectedFinished = await waitUntil { !rejectedCompletions.isEmpty }
                    #expect((rejectedFinished) == true, "\(label) rejection finishes")
                    #expect((rejectedCompletions) == ([false]), "\(label) rejection completion")
                    #expect(
                        (rejected.transientCommandError) == (kind.action), "\(label) rejection uses the action notice")
                    #expect(
                        (rejected.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) rejection leaves no pending command")
                    await rejected.shutdownForTermination()

                    if route == .local {
                        let reconnectAccount = HarnessAccount()
                        let reconnectEngine = HarnessEngine(executeResult: PlaybackEngineResult(rawValue: -2))
                        let reconnect = HarnessEnvironment.makePlaybackStore(
                            HarnessEnvironment.make(
                                engine: reconnectEngine,
                                remote: HarnessRemote(),
                                account: reconnectAccount
                            )
                        )
                        seedRoute(reconnect, route)
                        var reconnectCompletions: [Bool] = []
                        startLifecycleCommand(reconnect, kind: kind) { reconnectCompletions.append($0) }
                        let reconnectFinished = await waitUntil { !reconnectCompletions.isEmpty }
                        #expect((reconnectFinished) == true, "\(label) reconnect-required finishes")
                        #expect((reconnectCompletions) == ([false]), "\(label) reconnect-required completion")
                        #expect(
                            (reconnect.transientCommandError) == (kind.action),
                            "\(label) reconnect-required uses the action notice")
                        let reconnectStarted = await waitUntil { reconnectEngine.forceReconnectCount == 1 }
                        #expect((reconnectStarted) == true, "\(label) reconnect-required rebuilds the ready engine")
                        #expect(
                            (reconnectEngine.forceReconnectCount) == (1),
                            "\(label) reconnect-required force-reconnect count")
                        #expect(
                            (reconnectAccount.authorizeCount) == (0),
                            "\(label) reconnect-required does not reauthorize a ready session")
                        await reconnect.shutdownForTermination()
                    }

                    let duplicateGate = HarnessEngineGate(result: .ok)
                    let duplicateEngine = HarnessEngine()
                    duplicateEngine.onExecute = { [duplicateGate] _ in duplicateGate.enter() }
                    let duplicateRemote = GatedRemoteClient()
                    let duplicate = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: duplicateEngine, remote: duplicateRemote)
                    )
                    seedRoute(duplicate, route)
                    var firstCompletions: [Bool] = []
                    var duplicateCompletions: [Bool] = []
                    startLifecycleCommand(duplicate, kind: kind) { firstCompletions.append($0) }
                    let pendingReady = await waitUntil { duplicate.state.pendingCommands[kind.commandKind] != nil }
                    #expect((pendingReady) == true, "\(label) first command is pending before a duplicate")
                    let firstID = duplicate.state.pendingCommands[kind.commandKind]?.id
                    startLifecycleCommand(duplicate, kind: kind) { duplicateCompletions.append($0) }
                    #expect((duplicateCompletions) == ([false]), "\(label) duplicate completes immediately as failure")
                    #expect(
                        (duplicate.state.pendingCommands[kind.commandKind]?.id) == (firstID),
                        "\(label) duplicate keeps the original command")
                    if route == .local {
                        duplicateGate.finish(with: .ok)
                    } else {
                        duplicateRemote.finish(success: true)
                    }
                    let duplicateFinished = await waitUntil { !firstCompletions.isEmpty }
                    #expect((duplicateFinished) == true, "\(label) first command finishes after the duplicate refusal")
                    await duplicate.shutdownForTermination()

                    let confirmGate = HarnessEngineGate(result: .error)
                    let confirmLocal = HarnessEngine()
                    confirmLocal.onExecute = { [confirmGate] _ in confirmGate.enter() }
                    let confirmRemote = GatedRemoteClient()
                    let confirmed = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: confirmLocal, remote: confirmRemote)
                    )
                    seedRoute(confirmed, route)
                    var confirmedCompletions: [Bool] = []
                    startLifecycleCommand(confirmed, kind: kind) { confirmedCompletions.append($0) }
                    let confirmPending = await waitUntil { confirmed.state.pendingCommands[kind.commandKind] != nil }
                    #expect((confirmPending) == true, "\(label) command is pending before confirmation")
                    let confirmReached = await waitForLifecycleDispatch(
                        route: route, local: confirmGate, remote: confirmRemote)
                    #expect((confirmReached) == true, "\(label) command reaches the fixture before confirmation")
                    let confirmedID = confirmed.state.pendingCommands[kind.commandKind]?.id
                    confirm(confirmed, kind: kind, revision: 1)
                    #expect(
                        (confirmed.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) authoritative snapshot confirms the command")
                    #expect(
                        (confirmedID.flatMap { confirmed.state.transportCommandResolutions[$0] })
                            == (Optional(PlaybackTransportCommandResolution.confirmed)),
                        "\(label) authoritative snapshot records confirmation")
                    if route == .local {
                        confirmGate.finish(with: .error)
                    } else {
                        confirmRemote.finish(success: false)
                    }
                    let confirmFinished = await waitUntil { !confirmedCompletions.isEmpty }
                    #expect((confirmFinished) == true, "\(label) confirmed command still finishes")
                    #expect(
                        (confirmedCompletions) == ([true]),
                        "\(label) confirmed then coordinator failure reports success")
                    await confirmed.shutdownForTermination()

                    let supersedeGate = HarnessEngineGate(result: .error)
                    let supersedeLocal = HarnessEngine()
                    supersedeLocal.onExecute = { [supersedeGate] _ in supersedeGate.enter() }
                    let supersedeRemote = GatedRemoteClient()
                    let superseded = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: supersedeLocal, remote: supersedeRemote)
                    )
                    seedRoute(superseded, route)
                    var supersededCompletions: [Bool] = []
                    startLifecycleCommand(superseded, kind: kind) { supersededCompletions.append($0) }
                    let supersedePending = await waitUntil { superseded.state.pendingCommands[kind.commandKind] != nil }
                    #expect((supersedePending) == true, "\(label) command is pending before supersession")
                    let supersedeReached = await waitForLifecycleDispatch(
                        route: route, local: supersedeGate, remote: supersedeRemote)
                    #expect((supersedeReached) == true, "\(label) command reaches the fixture before supersession")
                    supersede(superseded, kind: kind, revision: 1)
                    #expect(
                        (superseded.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) unrelated snapshot clears the pending command")
                    if route == .local {
                        supersedeGate.finish(with: .error)
                        let supersedeFinished = await waitUntil { supersedeLocal.executeCount == 1 }
                        #expect(
                            (supersedeFinished) == true, "\(label) superseded command finishes at the local fixture")
                    } else {
                        supersedeRemote.finish(success: false)
                        let supersedeFinished = await waitUntil { supersedeRemote.completedCount == 1 }
                        #expect(
                            (supersedeFinished) == true, "\(label) superseded command finishes at the remote fixture")
                    }
                    #expect(
                        (supersededCompletions.isEmpty) == true,
                        "\(label) superseded then coordinator failure reports no completion")
                    #expect(
                        (superseded.transientCommandError) == nil,
                        "\(label) superseded then coordinator failure has no notice")
                    await superseded.shutdownForTermination()

                    let staleGate = HarnessEngineGate(result: .ok)
                    let staleLocal = HarnessEngine()
                    staleLocal.onExecute = { [staleGate] _ in staleGate.enter() }
                    let staleRemote = GatedRemoteClient()
                    let stale = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: staleLocal, remote: staleRemote)
                    )
                    seedRoute(stale, route)
                    var staleCompletions: [Bool] = []
                    startLifecycleCommand(stale, kind: kind) { staleCompletions.append($0) }
                    // `commandStarted` is a synchronous MainActor publication. Bump the engine
                    // epoch in this same turn, before the effect task can create a dispatch
                    // permit, to exercise the pre-dispatch lifetime fence deterministically.
                    let stalePending = stale.state.pendingCommands[kind.commandKind] != nil
                    #expect((stalePending) == true, "\(label) command is pending before an engine-epoch bump")
                    let staleID = stale.state.pendingCommands[kind.commandKind]?.id
                    let staleSettlement = staleID.flatMap { stale.effects.settlement(of: .command($0)) }
                    _ = stale.send(
                        .engineConnection(
                            EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                        source: .engineConnection,
                        revision: 1,
                        engineEpoch: stale.engineGeneration + 1
                    )
                    #expect(
                        (stale.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) engine-epoch bump drops the pending command")
                    if route == .local {
                        #expect((staleGate.enteredCount) == 0, "\(label) stale command never enters the local fixture")
                    } else {
                        #expect(
                            (staleRemote.sendCount) == 0,
                            "\(label) stale command never reaches the remote fixture")
                    }
                    await staleSettlement?.wait()
                    #expect((staleCompletions.isEmpty) == true, "\(label) stale finish reports no completion")
                    await stale.shutdownForTermination()

                    let lateGate = HarnessEngineGate(result: .ok)
                    let lateLocal = HarnessEngine()
                    lateLocal.onExecute = { [lateGate] _ in lateGate.enter() }
                    let lateRemote = GatedRemoteClient()
                    let lateStale = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: lateLocal, remote: lateRemote)
                    )
                    seedRoute(lateStale, route)
                    var lateCompletions: [Bool] = []
                    startLifecycleCommand(lateStale, kind: kind) { lateCompletions.append($0) }
                    let latePending = await waitUntil {
                        lateStale.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect((latePending) == true, "\(label) late stale command is pending before dispatch")
                    let lateReached = await waitForLifecycleDispatch(
                        route: route, local: lateGate, remote: lateRemote)
                    #expect((lateReached) == true, "\(label) late stale command reaches the fixture")
                    let lateID = lateStale.state.pendingCommands[kind.commandKind]?.id
                    let lateSettlement = lateID.flatMap { lateStale.effects.settlement(of: .command($0)) }
                    _ = lateStale.send(
                        .engineConnection(
                            EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                        source: .engineConnection,
                        revision: 1,
                        engineEpoch: lateStale.engineGeneration + 1
                    )
                    #expect(
                        (lateStale.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) late stale epoch bump drops the pending command")
                    if route == .local {
                        lateGate.finish(with: .ok)
                        let lateFinished = await waitUntil { lateLocal.executeCount == 1 }
                        #expect((lateFinished) == true, "\(label) late stale local fixture finishes")
                    } else {
                        lateRemote.finish(success: true)
                        let lateFinished = await waitUntil { lateRemote.completedCount == 1 }
                        #expect((lateFinished) == true, "\(label) late stale remote fixture finishes")
                    }
                    await lateSettlement?.wait()
                    #expect((lateCompletions.isEmpty) == true, "\(label) late stale finish reports no completion")
                    await lateStale.shutdownForTermination()

                    let cancelGate = HarnessEngineGate(result: .ok)
                    let cancelLocal = HarnessEngine()
                    cancelLocal.onExecute = { [cancelGate] _ in cancelGate.enter() }
                    let cancelRemote = GatedRemoteClient()
                    let cancelled = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: cancelLocal, remote: cancelRemote)
                    )
                    seedRoute(cancelled, route)
                    let prior = cancelled.state
                    var cancelCompletions: [Bool] = []
                    startLifecycleCommand(cancelled, kind: kind) { cancelCompletions.append($0) }
                    let cancelPending = await waitUntil { cancelled.state.pendingCommands[kind.commandKind] != nil }
                    #expect((cancelPending) == true, "\(label) command is pending before cancellation")
                    let cancelReached = await waitUntil {
                        if route == .local { return cancelGate.enteredCount == 1 }
                        return cancelRemote.sendCount >= 1
                    }
                    #expect((cancelReached) == true, "\(label) cancelled command still reaches the fixture")
                    let cancelledID = cancelled.state.pendingCommands[kind.commandKind]?.id
                    #expect((cancelledID) != nil, "\(label) cancelled command has an id")
                    if let commandID = cancelledID {
                        cancelled.effects.cancel(.command(commandID))
                    }
                    let cancelSettled = await waitUntil {
                        cancelled.state.pendingCommands[kind.commandKind] == nil && !cancelCompletions.isEmpty
                    }
                    #expect((cancelSettled) == true, "\(label) ordinary cancellation settles")
                    #expect((cancelCompletions) == ([false]), "\(label) ordinary cancellation reports failure once")
                    #expect(
                        (cancelled.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) ordinary cancellation clears the pending command")
                    #expect(
                        (cancelled.transientCommandError) == nil, "\(label) ordinary cancellation has no command notice"
                    )
                    #expect(
                        (cancelled.state.transport) == (prior.transport),
                        "\(label) ordinary cancellation restores captured transport")
                    #expect(
                        (cancelled.state.timing) == (prior.timing),
                        "\(label) ordinary cancellation restores captured timing")
                    #expect(
                        (cancelled.state.currentTrack) == (prior.currentTrack),
                        "\(label) ordinary cancellation restores captured track")
                    #expect(
                        (cancelled.state.options) == (prior.options),
                        "\(label) ordinary cancellation restores captured options")
                    #expect(
                        (cancelled.state.owner) == (prior.owner),
                        "\(label) ordinary cancellation restores captured owner")
                    if route == .local {
                        cancelGate.finish(with: .ok)
                    } else {
                        cancelRemote.finish(success: true)
                    }
                    let cancelledFixtureReleased = await waitUntil {
                        if route == .local { return cancelLocal.executeCount == 1 }
                        return cancelRemote.completedCount == 1
                    }
                    #expect((cancelledFixtureReleased) == true, "\(label) cancelled fixture releases before reuse")

                    var nextCompletions: [Bool] = []
                    startLifecycleCommand(cancelled, kind: kind) { nextCompletions.append($0) }
                    let nextPending = await waitUntil { cancelled.state.pendingCommands[kind.commandKind] != nil }
                    #expect((nextPending) == true, "\(label) same-kind command is admitted after cancellation")
                    #expect(
                        (cancelled.state.pendingCommands[kind.commandKind]?.id != cancelledID) == true,
                        "\(label) the later command is a new id")
                    let nextReached = await waitUntil {
                        if route == .local { return cancelGate.enteredCount == 2 }
                        return cancelRemote.sendCount >= 2
                    }
                    #expect((nextReached) == true, "\(label) later command reaches the fixture before completion")
                    if route == .local {
                        cancelGate.finish(with: .ok)
                    } else {
                        cancelRemote.finish(success: true)
                    }
                    let nextFinished = await waitUntil { !nextCompletions.isEmpty }
                    #expect((nextFinished) == true, "\(label) later command after cancellation finishes")
                    #expect((nextCompletions) == ([true]), "\(label) later command after cancellation succeeds")
                    await cancelled.shutdownForTermination()

                    let confirmCancelGate = HarnessEngineGate(result: .ok)
                    let confirmCancelLocal = HarnessEngine()
                    confirmCancelLocal.onExecute = { [confirmCancelGate] _ in confirmCancelGate.enter() }
                    let confirmCancelRemote = GatedRemoteClient()
                    let confirmCancelled = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: confirmCancelLocal, remote: confirmCancelRemote)
                    )
                    seedRoute(confirmCancelled, route)
                    var confirmCancelCompletions: [Bool] = []
                    startLifecycleCommand(confirmCancelled, kind: kind) { confirmCancelCompletions.append($0) }
                    let confirmCancelPending = await waitUntil {
                        confirmCancelled.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect((confirmCancelPending) == true, "\(label) command is pending before confirmed cancellation")
                    let confirmCancelReached = await waitForLifecycleDispatch(
                        route: route, local: confirmCancelGate, remote: confirmCancelRemote)
                    #expect(
                        (confirmCancelReached) == true,
                        "\(label) command reaches the fixture before confirmed cancellation")
                    let confirmCancelID = confirmCancelled.state.pendingCommands[kind.commandKind]?.id
                    confirm(confirmCancelled, kind: kind, revision: 1)
                    #expect(
                        (confirmCancelled.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) confirmation clears the pending command before cancel")
                    if let commandID = confirmCancelID {
                        confirmCancelled.effects.cancel(.command(commandID))
                    }
                    #expect(
                        (confirmCancelCompletions.isEmpty) == true,
                        "\(label) confirmed cancellation reports no completion")
                    #expect(
                        (confirmCancelled.transientCommandError) == nil, "\(label) confirmed cancellation has no notice"
                    )
                    if kind == .transport {
                        #expect(
                            (confirmCancelled.state.currentTrack?.uri) == (lifecycleTrackB.uri),
                            "\(label) confirmed cancellation keeps the target track")
                    }
                    if kind == .options {
                        #expect(
                            (confirmCancelled.state.options.repeatMode) == (RepeatMode.context),
                            "\(label) confirmed cancellation keeps context repeat")
                    }
                    if kind == .transfer {
                        #expect(
                            (confirmCancelled.state.owner) == (lifecycleRemoteB),
                            "\(label) confirmed cancellation keeps the target owner")
                    }
                    if route == .local {
                        confirmCancelGate.finish(with: .ok)
                    } else {
                        confirmCancelRemote.finish(success: true)
                    }
                    await confirmCancelled.shutdownForTermination()

                    let supersedeCancelGate = HarnessEngineGate(result: .ok)
                    let supersedeCancelLocal = HarnessEngine()
                    supersedeCancelLocal.onExecute = { [supersedeCancelGate] _ in supersedeCancelGate.enter() }
                    let supersedeCancelRemote = GatedRemoteClient()
                    let supersedeCancelled = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: supersedeCancelLocal, remote: supersedeCancelRemote)
                    )
                    seedRoute(supersedeCancelled, route)
                    var supersedeCancelCompletions: [Bool] = []
                    startLifecycleCommand(supersedeCancelled, kind: kind) { supersedeCancelCompletions.append($0) }
                    let supersedeCancelPending = await waitUntil {
                        supersedeCancelled.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect(
                        (supersedeCancelPending) == true, "\(label) command is pending before superseded cancellation")
                    let supersedeCancelReached = await waitForLifecycleDispatch(
                        route: route, local: supersedeCancelGate, remote: supersedeCancelRemote)
                    #expect(
                        (supersedeCancelReached) == true,
                        "\(label) command reaches the fixture before superseded cancellation")
                    let supersedeCancelID = supersedeCancelled.state.pendingCommands[kind.commandKind]?.id
                    supersede(supersedeCancelled, kind: kind, revision: 1)
                    #expect(
                        (supersedeCancelled.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) supersession clears the pending command before cancel")
                    if let commandID = supersedeCancelID {
                        supersedeCancelled.effects.cancel(.command(commandID))
                    }
                    #expect(
                        (supersedeCancelCompletions.isEmpty) == true,
                        "\(label) superseded cancellation reports no completion")
                    #expect(
                        (supersedeCancelled.transientCommandError) == nil,
                        "\(label) superseded cancellation has no notice")
                    if kind == .transport {
                        #expect(
                            (supersedeCancelled.state.currentTrack?.uri) == (lifecycleTrackC.uri),
                            "\(label) superseded cancellation keeps the unrelated track")
                    }
                    if kind == .options {
                        #expect(
                            (supersedeCancelled.state.options.repeatMode) == (RepeatMode.track),
                            "\(label) superseded cancellation keeps track repeat")
                    }
                    if kind == .transfer {
                        #expect(
                            (supersedeCancelled.state.owner) == (lifecycleOwnerC),
                            "\(label) superseded cancellation keeps the unrelated owner")
                    }
                    if route == .local {
                        supersedeCancelGate.finish(with: .ok)
                    } else {
                        supersedeCancelRemote.finish(success: true)
                    }
                    await supersedeCancelled.shutdownForTermination()

                    let staleCancelGate = HarnessEngineGate(result: .ok)
                    let staleCancelLocal = HarnessEngine()
                    staleCancelLocal.onExecute = { [staleCancelGate] _ in staleCancelGate.enter() }
                    let staleCancelRemote = GatedRemoteClient()
                    let staleCancelled = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: staleCancelLocal, remote: staleCancelRemote)
                    )
                    seedRoute(staleCancelled, route)
                    var staleCancelCompletions: [Bool] = []
                    startLifecycleCommand(staleCancelled, kind: kind) { staleCancelCompletions.append($0) }
                    let staleCancelPending = staleCancelled.state.pendingCommands[kind.commandKind] != nil
                    #expect((staleCancelPending) == true, "\(label) command is pending before stale cancellation")
                    let staleCancelID = staleCancelled.state.pendingCommands[kind.commandKind]?.id
                    let staleCancelSettlement = staleCancelID.flatMap {
                        staleCancelled.effects.settlement(of: .command($0))
                    }
                    _ = staleCancelled.send(
                        .engineConnection(
                            EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                        source: .engineConnection,
                        revision: 1,
                        engineEpoch: staleCancelled.engineGeneration + 1
                    )
                    #expect(
                        (staleCancelled.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) engine-epoch bump drops the pending command before cancel")
                    if route == .local {
                        #expect(
                            (staleCancelGate.enteredCount) == 0,
                            "\(label) stale cancellation never enters the local fixture")
                    } else {
                        #expect(
                            (staleCancelRemote.sendCount) == 0,
                            "\(label) stale cancellation never reaches the remote fixture")
                    }
                    if let commandID = staleCancelID {
                        staleCancelled.effects.cancel(.command(commandID))
                    }
                    #expect(
                        (staleCancelCompletions.isEmpty) == true, "\(label) stale cancellation reports no completion")
                    if route == .local {
                        staleCancelGate.finish(with: .ok)
                    } else {
                        staleCancelRemote.finish(success: true)
                    }
                    await staleCancelSettlement?.wait()
                    await staleCancelled.shutdownForTermination()

                    let teardownGate = HarnessEngineGate(result: .ok)
                    let teardownLocal = HarnessEngine()
                    teardownLocal.onExecute = { [teardownGate] _ in teardownGate.enter() }
                    let teardownRemote = GatedRemoteClient()
                    let teardown = HarnessEnvironment.makePlaybackStore(
                        HarnessEnvironment.make(engine: teardownLocal, remote: teardownRemote)
                    )
                    seedRoute(teardown, route)
                    var teardownCompletions: [Bool] = []
                    startLifecycleCommand(teardown, kind: kind) { teardownCompletions.append($0) }
                    let teardownPending = await waitUntil { teardown.state.pendingCommands[kind.commandKind] != nil }
                    #expect((teardownPending) == true, "\(label) command is pending before teardown")
                    let teardownReached = await waitUntil {
                        if route == .local { return teardownGate.enteredCount == 1 }
                        return teardownRemote.sendCount >= 1
                    }
                    #expect((teardownReached) == true, "\(label) teardown command still reaches the fixture")
                    // Local execute is a blocking coordinator call. Shutdown awaits
                    // shutdownEngine on that same actor, so the fixture must be released first.
                    if route == .local {
                        teardownGate.finish(with: .ok)
                    } else {
                        teardownRemote.finish(success: true)
                    }
                    await teardown.shutdownForTermination()
                    for _ in 0..<50 { await Task.yield() }
                    #expect((teardownCompletions.isEmpty) == true, "\(label) teardown reports no completion")
                    #expect(
                        (teardown.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) teardown leaves no pending command")
                }
            }
        }
    }
}

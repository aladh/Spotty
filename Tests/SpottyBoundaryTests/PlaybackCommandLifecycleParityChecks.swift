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

private enum LifecycleRemoteFailure: Error {
    case boom
}

private final class LifecycleLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let condition = NSCondition()
    private var allowed = false
    private var result: PlaybackEngineResult
    private var storedEnteredCount = 0
    private var storedExecuteCount = 0
    private var storedForceReconnectCount = 0

    init(result: PlaybackEngineResult, gated: Bool) {
        self.result = result
        allowed = !gated
    }

    var enteredCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedEnteredCount
    }

    var executeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedExecuteCount
    }

    var forceReconnectCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedForceReconnectCount
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult {
        condition.lock()
        storedEnteredCount += 1
        while !allowed {
            condition.wait()
        }
        storedExecuteCount += 1
        let result = self.result
        allowed = false
        condition.unlock()
        return result
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 {
        condition.lock()
        storedForceReconnectCount += 1
        condition.unlock()
        return 0
    }

    func finish(with result: PlaybackEngineResult) {
        condition.lock()
        self.result = result
        allowed = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor LifecycleRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case gated
    }

    private let behavior: Behavior
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private(set) var sendCount = 0
    private(set) var completedCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        defer { completedCount += 1 }
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw LifecycleRemoteFailure.boom
        case .gated:
            if let pendingResult {
                self.pendingResult = nil
                try pendingResult.get()
                return
            }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func finish(success: Bool) {
        let result: Result<Void, Error> =
            success
            ? .success(())
            : .failure(LifecycleRemoteFailure.boom)
        if let waiting = continuation {
            continuation = nil
            waiting.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Metadata",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        )
    }
}

private actor IdleWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private actor IdlePreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct StickyClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
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

private func lifecycleEnvironment(
    local: any LocalPlaybackEngine,
    remote: any RemotePlaybackClient,
    account: BoundaryIdleAccount = BoundaryIdleAccount()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleWebQueue(),
        account: account,
        audioOutput: BoundaryIdleAudio(),
        preferences: IdlePreferences(),
        lifecycle: BoundaryIdleLifecycle(),
        clock: StickyClock(),
        catalog: BoundaryIdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: BoundaryIdleAttributes()
    )
}

@MainActor
private func lifecycleStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

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
    @Test
    @MainActor
    func testPlaybackCommandLifecycleParity() async {
        do {
            for kind in LifecycleKind.allCases {
                let player = lifecycleStore(
                    lifecycleEnvironment(
                        local: LifecycleLocalEngine(result: .ok, gated: false),
                        remote: LifecycleRemoteClient(.succeed)
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

                    let successAccount = BoundaryIdleAccount()
                    let success = lifecycleStore(
                        lifecycleEnvironment(
                            local: LifecycleLocalEngine(result: .ok, gated: false),
                            remote: LifecycleRemoteClient(.succeed),
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

                    let rejected = lifecycleStore(
                        lifecycleEnvironment(
                            local: LifecycleLocalEngine(result: .error, gated: false),
                            remote: LifecycleRemoteClient(.fail)
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
                        let reconnectAccount = BoundaryIdleAccount()
                        let reconnectEngine = LifecycleLocalEngine(
                            result: PlaybackEngineResult(rawValue: -2),
                            gated: false
                        )
                        let reconnect = lifecycleStore(
                            lifecycleEnvironment(
                                local: reconnectEngine,
                                remote: LifecycleRemoteClient(.succeed),
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

                    let duplicateLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let duplicateRemote = LifecycleRemoteClient(.gated)
                    let duplicate = lifecycleStore(
                        lifecycleEnvironment(local: duplicateLocal, remote: duplicateRemote)
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
                        duplicateLocal.finish(with: .ok)
                    } else {
                        await duplicateRemote.finish(success: true)
                    }
                    let duplicateFinished = await waitUntil { !firstCompletions.isEmpty }
                    #expect((duplicateFinished) == true, "\(label) first command finishes after the duplicate refusal")
                    await duplicate.shutdownForTermination()

                    let confirmLocal = LifecycleLocalEngine(result: .error, gated: true)
                    let confirmRemote = LifecycleRemoteClient(.gated)
                    let confirmed = lifecycleStore(
                        lifecycleEnvironment(local: confirmLocal, remote: confirmRemote)
                    )
                    seedRoute(confirmed, route)
                    var confirmedCompletions: [Bool] = []
                    startLifecycleCommand(confirmed, kind: kind) { confirmedCompletions.append($0) }
                    let confirmPending = await waitUntil { confirmed.state.pendingCommands[kind.commandKind] != nil }
                    #expect((confirmPending) == true, "\(label) command is pending before confirmation")
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
                        confirmLocal.finish(with: .error)
                    } else {
                        await confirmRemote.finish(success: false)
                    }
                    let confirmFinished = await waitUntil { !confirmedCompletions.isEmpty }
                    #expect((confirmFinished) == true, "\(label) confirmed command still finishes")
                    #expect(
                        (confirmedCompletions) == ([true]),
                        "\(label) confirmed then coordinator failure reports success")
                    await confirmed.shutdownForTermination()

                    let supersedeLocal = LifecycleLocalEngine(result: .error, gated: true)
                    let supersedeRemote = LifecycleRemoteClient(.gated)
                    let superseded = lifecycleStore(
                        lifecycleEnvironment(local: supersedeLocal, remote: supersedeRemote)
                    )
                    seedRoute(superseded, route)
                    var supersededCompletions: [Bool] = []
                    startLifecycleCommand(superseded, kind: kind) { supersededCompletions.append($0) }
                    let supersedePending = await waitUntil { superseded.state.pendingCommands[kind.commandKind] != nil }
                    #expect((supersedePending) == true, "\(label) command is pending before supersession")
                    supersede(superseded, kind: kind, revision: 1)
                    #expect(
                        (superseded.state.pendingCommands[kind.commandKind]) == nil,
                        "\(label) unrelated snapshot clears the pending command")
                    if route == .local {
                        supersedeLocal.finish(with: .error)
                        let supersedeReached = await waitUntil { supersedeLocal.executeCount == 1 }
                        #expect(
                            (supersedeReached) == true, "\(label) superseded command still reaches the local fixture")
                    } else {
                        await supersedeRemote.finish(success: false)
                        let supersedeReached = await waitUntil { await supersedeRemote.sendCount >= 1 }
                        #expect(
                            (supersedeReached) == true, "\(label) superseded command still reaches the remote fixture")
                    }
                    #expect(
                        (supersededCompletions.isEmpty) == true,
                        "\(label) superseded then coordinator failure reports no completion")
                    #expect(
                        (superseded.transientCommandError) == nil,
                        "\(label) superseded then coordinator failure has no notice")
                    await superseded.shutdownForTermination()

                    let staleLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let staleRemote = LifecycleRemoteClient(.gated)
                    let stale = lifecycleStore(
                        lifecycleEnvironment(local: staleLocal, remote: staleRemote)
                    )
                    seedRoute(stale, route)
                    var staleCompletions: [Bool] = []
                    startLifecycleCommand(stale, kind: kind) { staleCompletions.append($0) }
                    let stalePending = await waitUntil { stale.state.pendingCommands[kind.commandKind] != nil }
                    #expect((stalePending) == true, "\(label) command is pending before an engine-epoch bump")
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
                        staleLocal.finish(with: .ok)
                        let staleReached = await waitUntil { staleLocal.executeCount == 1 }
                        #expect((staleReached) == true, "\(label) stale command still reaches the local fixture")
                    } else {
                        await staleRemote.finish(success: true)
                        let staleReached = await waitUntil { await staleRemote.sendCount >= 1 }
                        #expect((staleReached) == true, "\(label) stale command still reaches the remote fixture")
                    }
                    #expect((staleCompletions.isEmpty) == true, "\(label) stale finish reports no completion")
                    await stale.shutdownForTermination()

                    let cancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let cancelRemote = LifecycleRemoteClient(.gated)
                    let cancelled = lifecycleStore(
                        lifecycleEnvironment(local: cancelLocal, remote: cancelRemote)
                    )
                    seedRoute(cancelled, route)
                    let prior = cancelled.state
                    var cancelCompletions: [Bool] = []
                    startLifecycleCommand(cancelled, kind: kind) { cancelCompletions.append($0) }
                    let cancelPending = await waitUntil { cancelled.state.pendingCommands[kind.commandKind] != nil }
                    #expect((cancelPending) == true, "\(label) command is pending before cancellation")
                    let cancelReached = await waitUntil {
                        if route == .local { return cancelLocal.enteredCount == 1 }
                        return await cancelRemote.sendCount >= 1
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
                        cancelLocal.finish(with: .ok)
                    } else {
                        await cancelRemote.finish(success: true)
                    }
                    let cancelledFixtureReleased = await waitUntil {
                        if route == .local { return cancelLocal.executeCount == 1 }
                        return await cancelRemote.completedCount == 1
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
                        if route == .local { return cancelLocal.enteredCount == 2 }
                        return await cancelRemote.sendCount >= 2
                    }
                    #expect((nextReached) == true, "\(label) later command reaches the fixture before completion")
                    if route == .local {
                        cancelLocal.finish(with: .ok)
                    } else {
                        await cancelRemote.finish(success: true)
                    }
                    let nextFinished = await waitUntil { !nextCompletions.isEmpty }
                    #expect((nextFinished) == true, "\(label) later command after cancellation finishes")
                    #expect((nextCompletions) == ([true]), "\(label) later command after cancellation succeeds")
                    await cancelled.shutdownForTermination()

                    let confirmCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let confirmCancelRemote = LifecycleRemoteClient(.gated)
                    let confirmCancelled = lifecycleStore(
                        lifecycleEnvironment(local: confirmCancelLocal, remote: confirmCancelRemote)
                    )
                    seedRoute(confirmCancelled, route)
                    var confirmCancelCompletions: [Bool] = []
                    startLifecycleCommand(confirmCancelled, kind: kind) { confirmCancelCompletions.append($0) }
                    let confirmCancelPending = await waitUntil {
                        confirmCancelled.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect((confirmCancelPending) == true, "\(label) command is pending before confirmed cancellation")
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
                        confirmCancelLocal.finish(with: .ok)
                    } else {
                        await confirmCancelRemote.finish(success: true)
                    }
                    await confirmCancelled.shutdownForTermination()

                    let supersedeCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let supersedeCancelRemote = LifecycleRemoteClient(.gated)
                    let supersedeCancelled = lifecycleStore(
                        lifecycleEnvironment(local: supersedeCancelLocal, remote: supersedeCancelRemote)
                    )
                    seedRoute(supersedeCancelled, route)
                    var supersedeCancelCompletions: [Bool] = []
                    startLifecycleCommand(supersedeCancelled, kind: kind) { supersedeCancelCompletions.append($0) }
                    let supersedeCancelPending = await waitUntil {
                        supersedeCancelled.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect(
                        (supersedeCancelPending) == true, "\(label) command is pending before superseded cancellation")
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
                        supersedeCancelLocal.finish(with: .ok)
                    } else {
                        await supersedeCancelRemote.finish(success: true)
                    }
                    await supersedeCancelled.shutdownForTermination()

                    let staleCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let staleCancelRemote = LifecycleRemoteClient(.gated)
                    let staleCancelled = lifecycleStore(
                        lifecycleEnvironment(local: staleCancelLocal, remote: staleCancelRemote)
                    )
                    seedRoute(staleCancelled, route)
                    var staleCancelCompletions: [Bool] = []
                    startLifecycleCommand(staleCancelled, kind: kind) { staleCancelCompletions.append($0) }
                    let staleCancelPending = await waitUntil {
                        staleCancelled.state.pendingCommands[kind.commandKind] != nil
                    }
                    #expect((staleCancelPending) == true, "\(label) command is pending before stale cancellation")
                    let staleCancelID = staleCancelled.state.pendingCommands[kind.commandKind]?.id
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
                    if let commandID = staleCancelID {
                        staleCancelled.effects.cancel(.command(commandID))
                    }
                    #expect(
                        (staleCancelCompletions.isEmpty) == true, "\(label) stale cancellation reports no completion")
                    if route == .local {
                        staleCancelLocal.finish(with: .ok)
                    } else {
                        await staleCancelRemote.finish(success: true)
                    }
                    await staleCancelled.shutdownForTermination()

                    let teardownLocal = LifecycleLocalEngine(result: .ok, gated: true)
                    let teardownRemote = LifecycleRemoteClient(.gated)
                    let teardown = lifecycleStore(
                        lifecycleEnvironment(local: teardownLocal, remote: teardownRemote)
                    )
                    seedRoute(teardown, route)
                    var teardownCompletions: [Bool] = []
                    startLifecycleCommand(teardown, kind: kind) { teardownCompletions.append($0) }
                    let teardownPending = await waitUntil { teardown.state.pendingCommands[kind.commandKind] != nil }
                    #expect((teardownPending) == true, "\(label) command is pending before teardown")
                    let teardownReached = await waitUntil {
                        if route == .local { return teardownLocal.enteredCount == 1 }
                        return await teardownRemote.sendCount >= 1
                    }
                    #expect((teardownReached) == true, "\(label) teardown command still reaches the fixture")
                    // Local execute is a blocking coordinator call. Shutdown awaits
                    // shutdownEngine on that same actor, so the fixture must be released first.
                    if route == .local {
                        teardownLocal.finish(with: .ok)
                    } else {
                        await teardownRemote.finish(success: true)
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

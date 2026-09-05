import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private final class ScriptedLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackEngineResult
    private let storedResumePosition: UInt32
    private let storedResumeContextURI: String?
    private let storedResumeTrackURI: String?
    private var storedOperations: [LocalPlaybackOperation] = []
    private var storedForceReconnectCount = 0

    init(
        result: PlaybackEngineResult,
        resumePosition: UInt32 = 0,
        resumeContextURI: String? = nil,
        resumeTrackURI: String? = nil
    ) {
        self.result = result
        storedResumePosition = resumePosition
        storedResumeContextURI = resumeContextURI
        storedResumeTrackURI = resumeTrackURI
    }

    var operations: [LocalPlaybackOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }

    var forceReconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedForceReconnectCount
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        lock.lock()
        storedOperations.append(operation)
        lock.unlock()
        return result
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func resumePositionMilliseconds() -> UInt32 { storedResumePosition }
    func resumeContextURI() -> String? { storedResumeContextURI }
    func resumeTrackURI() -> String? { storedResumeTrackURI }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 {
        lock.lock()
        storedForceReconnectCount += 1
        lock.unlock()
        return 0
    }
}

private final class GatedLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let condition = NSCondition()
    private var allowed = false
    private var result: PlaybackEngineResult
    private var storedEnteredCount = 0
    private var storedForceReconnectCount = 0

    init(result: PlaybackEngineResult = .error) {
        self.result = result
    }

    var enteredCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedEnteredCount
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

private enum FixtureRemoteFailure: Error {
    case boom
}

private actor GatedFailingRemoteClient: RemotePlaybackClient {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var sendCount = 0

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func fail() {
        continuation?.resume(throwing: FixtureRemoteFailure.boom)
        continuation = nil
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

private actor ScriptedRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case sleepUntilCancelled
    }

    private let behavior: Behavior
    private(set) var sendCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw FixtureRemoteFailure.boom
        case .sleepUntilCancelled:
            try await Task.sleep(nanoseconds: 60_000_000_000)
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

/// An account with a stored grant, so `restore()` reaches `.ready` without interactive auth.
private final class GrantedAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuthorizeCount = 0

    var authorizeCount: Int {
        lock.withLock { storedAuthorizeCount }
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.withLock { storedAuthorizeCount += 1 }
        return KeymasterTokens(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiresAt: .distantFuture,
            username: "fixture-user"
        )
    }
    func hasGrant() async -> Bool { true }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
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

private actor RecordingPreferences: PlaybackPreferences {
    private var shuffle: Bool
    private(set) var shuffleWrites: [Bool] = []

    init(shuffle: Bool = false) {
        self.shuffle = shuffle
    }

    func shuffleEnabled() -> Bool { shuffle }
    func setShuffleEnabled(_ enabled: Bool) {
        shuffle = enabled
        shuffleWrites.append(enabled)
    }
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { ["restored": 1] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct StickyClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

@MainActor
private func localCommandOutcome(
    _ coordinator: PlaybackCoordinator,
    label: String
) async -> Result<Void, PlaybackCommandFailure>? {
    do {
        return try await coordinator.performLocalCommand(.pause)
    } catch {
        #expect((false) == true, "\(label)")
        return nil
    }
}

private func commandEnvironment(
    local: any LocalPlaybackEngine,
    remote: any RemotePlaybackClient,
    account: any AccountSession = BoundaryIdleAccount(),
    preferences: any PlaybackPreferences = IdlePreferences()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleWebQueue(),
        account: account,
        audioOutput: BoundaryIdleAudio(),
        preferences: preferences,
        lifecycle: BoundaryIdleLifecycle(),
        clock: StickyClock(),
        catalog: BoundaryIdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: BoundaryIdleAttributes()
    )
}

@MainActor
private func playbackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

@Suite("Playback Command Failure")
struct PlaybackCommandFailureTests {
    @Test
    @MainActor
    func testPlaybackCommandFailure() async {
        do {
            switch PlaybackCommandFailure.from(engineResult: .ok) {
            case .success:
                #expect((true) == true, "local success is a typed success")
            case .failure:
                #expect((false) == true, "local success is a typed success")
            }
            switch PlaybackCommandFailure.from(engineResult: .error) {
            case .success:
                #expect((false) == true, "engine error is rejected")
            case let .failure(failure):
                #expect((failure) == (.rejected), "engine error is rejected")
            }
            switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -2)) {
            case .success:
                #expect((false) == true, "session disconnected is reconnect-required")
            case let .failure(failure):
                #expect((failure) == (.reconnectRequired), "session disconnected is reconnect-required")
            }
            switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -3)) {
            case .success:
                #expect((false) == true, "session not connected is reconnect-required")
            case let .failure(failure):
                #expect((failure) == (.reconnectRequired), "session not connected is reconnect-required")
            }
            let credentialsRejected = PlaybackEngineResult(rawValue: -4)
            #expect(credentialsRejected.isCredentialsRejected, "credential rejection is typed")
            #expect(!credentialsRejected.requiresReconnect, "credential rejection does not reconnect")
            switch PlaybackCommandFailure.from(engineResult: credentialsRejected) {
            case .success:
                #expect((false) == true, "credential rejection is not command success")
            case let .failure(failure):
                #expect((failure) == (.unavailable), "credential rejection is init-only")
            }
            switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -99)) {
            case .success:
                #expect((false) == true, "an unrecognized engine code is unavailable")
            case let .failure(failure):
                #expect((failure) == (.unavailable), "an unrecognized engine code is unavailable")
            }
        }

        do {
            let successCoordinator = PlaybackCoordinator(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed)
            )
            if let success = await localCommandOutcome(successCoordinator, label: "local success") {
                if case .success = success {
                    #expect((true) == true, "local success")
                } else {
                    #expect((false) == true, "local success")
                }
            }

            let rejectedCoordinator = PlaybackCoordinator(
                local: ScriptedLocalEngine(result: .error),
                remote: ScriptedRemoteClient(.succeed)
            )
            if let rejected = await localCommandOutcome(rejectedCoordinator, label: "local rejection") {
                if case let .failure(failure) = rejected {
                    #expect((failure) == (.rejected), "local rejection")
                } else {
                    #expect((false) == true, "local rejection")
                }
            }

            let reconnectCoordinator = PlaybackCoordinator(
                local: ScriptedLocalEngine(result: PlaybackEngineResult(rawValue: -2)),
                remote: ScriptedRemoteClient(.succeed)
            )
            if let reconnect = await localCommandOutcome(
                reconnectCoordinator,
                label: "local reconnect-required"
            ) {
                if case let .failure(failure) = reconnect {
                    #expect((failure) == (.reconnectRequired), "local reconnect-required")
                } else {
                    #expect((false) == true, "local reconnect-required")
                }
            }
        }

        do {
            let success = try? await PlaybackCoordinator(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed)
            ).performRemoteCommand { remote in
                try await remote.send(.pause, from: "from", to: "to")
            }
            if case .success? = success {
                #expect((true) == true, "remote success")
            } else {
                #expect((false) == true, "remote success")
            }

            let rejected = try? await PlaybackCoordinator(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.fail)
            ).performRemoteCommand { remote in
                try await remote.send(.pause, from: "from", to: "to")
            }
            if case let .failure(failure)? = rejected {
                #expect((failure) == (.remoteRejected), "remote rejection")
            } else {
                #expect((false) == true, "remote rejection")
            }

            let sleepingRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let coordinator = PlaybackCoordinator(
                local: ScriptedLocalEngine(result: .ok),
                remote: sleepingRemote
            )
            let cancelled = Task {
                try await coordinator.performRemoteCommand { client in
                    try await client.send(.pause, from: "from", to: "to")
                }
            }
            let sendStarted = await waitUntil { await sleepingRemote.sendCount == 1 }
            #expect((sendStarted) == true, "remote send has started before cancellation")
            cancelled.cancel()
            var sawCancellation = false
            var operationalResult: Result<Void, PlaybackCommandFailure>?
            do {
                operationalResult = try await cancelled.value
            } catch is CancellationError {
                sawCancellation = true
            } catch {
                sawCancellation = false
            }
            #expect((sawCancellation) == true, "remote cancellation throws CancellationError")
            #expect((operationalResult) == nil, "remote cancellation is not an operational failure")
        }

        do {
            let action = "Pause was rejected"

            @MainActor
            func runLocal(
                _ result: PlaybackEngineResult,
                account: BoundaryIdleAccount = BoundaryIdleAccount()
            ) async -> (
                completions: [Bool],
                notice: String?,
                authorizeCount: Int,
                player: PlaybackStore
            ) {
                let player = playbackStore(
                    commandEnvironment(
                        local: ScriptedLocalEngine(result: result),
                        remote: ScriptedRemoteClient(.succeed),
                        account: account
                    )
                )
                var completions: [Bool] = []
                player.performCommand(action, expecting: false, operation: .pause) { completions.append($0) }
                _ = await waitUntil { !completions.isEmpty || player.state.pendingCommands[.transport] == nil }
                _ = await waitUntil { !completions.isEmpty }
                return (completions, player.transientCommandError, account.authorizeCount, player)
            }

            let success = await runLocal(.ok)
            #expect((success.completions) == ([true]), "local success completion")
            #expect((success.notice) == nil, "local success has no command notice")
            #expect((success.authorizeCount) == (0), "local success does not reconnect")
            await success.player.shutdownForTermination()

            let rejected = await runLocal(.error)
            #expect((rejected.completions) == ([false]), "local rejection completion")
            #expect((rejected.notice) == (action), "local rejection uses the action notice")
            #expect((rejected.authorizeCount) == (0), "local rejection does not reconnect")
            await rejected.player.shutdownForTermination()

            let reconnectAccount = BoundaryIdleAccount()
            let reconnect = await runLocal(PlaybackEngineResult(rawValue: -2), account: reconnectAccount)
            #expect((reconnect.completions) == ([false]), "reconnect-required completion")
            #expect((reconnect.notice) == (action), "reconnect-required uses the action notice")
            _ = await waitUntil { reconnectAccount.authorizeCount == 1 }
            #expect(
                (reconnectAccount.authorizeCount) == (1), "reconnect-required starts connect after an accepted finish")
            await reconnect.player.shutdownForTermination()

            // While the account is `.ready`, `connect()` is a no-op, so recovery must go through the
            // engine's own rebuild rather than an interactive account connection.
            let readyAccount = GrantedAccount()
            let readyEngine = ScriptedLocalEngine(result: PlaybackEngineResult(rawValue: -2))
            let ready = playbackStore(
                commandEnvironment(
                    local: readyEngine,
                    remote: ScriptedRemoteClient(.succeed),
                    account: readyAccount
                )
            )
            await ready.restore()
            #expect((ready.phase) == (.ready), "a granted account restores to ready")
            var readyCompletions: [Bool] = []
            ready.performCommand(action, expecting: false, operation: .pause) { readyCompletions.append($0) }
            _ = await waitUntil { !readyCompletions.isEmpty }
            #expect((readyCompletions) == ([false]), "reconnect-required on a ready session completes as failure")
            #expect(
                (ready.transientCommandError) == (action),
                "reconnect-required on a ready session shows the action notice")
            _ = await waitUntil { readyEngine.forceReconnectCount == 1 }
            #expect(
                (readyEngine.forceReconnectCount) == (1), "reconnect-required on a ready session rebuilds the engine")
            #expect((readyAccount.authorizeCount) == (0), "reconnect-required on a ready session does not re-authorize")
            await ready.shutdownForTermination()

            // Recovery is a registry effect: cancelling it before it runs (replacement, logout,
            // account epoch change) must keep the stale rebuild away from the engine.
            let cancelledAccount = GrantedAccount()
            let cancelledEngine = ScriptedLocalEngine(result: .ok)
            let cancelled = playbackStore(
                commandEnvironment(
                    local: cancelledEngine,
                    remote: ScriptedRemoteClient(.succeed),
                    account: cancelledAccount
                )
            )
            await cancelled.restore()
            #expect((cancelled.phase) == (.ready), "a granted account restores to ready before cancelled recovery")
            cancelled.recoverEngineAfterCommandFailure()
            cancelled.effects.cancel(.engineRecovery)
            try? await Task.sleep(for: .milliseconds(50))
            #expect((cancelledEngine.forceReconnectCount) == (0), "cancelled engine recovery never reaches the engine")
            await cancelled.shutdownForTermination()

            // A snapshot can reconcile the pending transport before the engine call returns. That
            // settles the presentation, but a reconnect-required result on that same call is a
            // lifecycle fact and must still rebuild the engine, on a ready session too.
            let reconciledAccount = GrantedAccount()
            let reconciledEngine = GatedLocalEngine()
            let reconciled = playbackStore(
                commandEnvironment(
                    local: reconciledEngine,
                    remote: ScriptedRemoteClient(.succeed),
                    account: reconciledAccount
                )
            )
            await reconciled.restore()
            #expect((reconciled.phase) == (.ready), "the reconciled fixture starts from a ready session")
            var reconciledCompletions: [Bool] = []
            reconciled.performCommand(action, expecting: false, operation: .pause) { reconciledCompletions.append($0) }
            #expect(
                (await waitUntil { reconciledEngine.enteredCount == 1 }) == true, "the gated engine call is in flight")
            _ = reconciled.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture",
                            title: "Now",
                            artist: "Artist",
                            duration: 200,
                            metadataSource: .catalog
                        ),
                        transport: .paused,
                        timing: PlaybackTiming(position: 10, duration: 200, anchoredAt: Date())
                    )),
                source: .user
            )
            #expect(
                (reconciled.state.pendingCommands[.transport]) == nil,
                "a matching snapshot reconciles the pending pause before the finish")
            reconciledEngine.finish(with: PlaybackEngineResult(rawValue: -2))
            _ = await waitUntil { !reconciledCompletions.isEmpty }
            #expect(
                (reconciledCompletions) == ([true]), "already-reconciled reconnect-required finish completes as success"
            )
            #expect(
                (reconciled.transientCommandError) == nil,
                "already-reconciled reconnect-required finish shows no command notice")
            #expect(
                (reconciled.state.transport) == (.paused), "already-reconciled transport keeps the reconciled state")
            _ = await waitUntil { reconciledEngine.forceReconnectCount == 1 }
            #expect(
                (reconciledEngine.forceReconnectCount) == (1),
                "already-reconciled reconnect-required finish still rebuilds the engine")
            #expect((reconciledAccount.authorizeCount) == (0), "already-reconciled recovery does not re-authorize")
            await reconciled.shutdownForTermination()
        }

        do {
            let action = "Pause was rejected"

            @MainActor
            func prepareRemoteStore(remote: ScriptedRemoteClient) -> PlaybackStore {
                let player = playbackStore(
                    commandEnvironment(
                        local: ScriptedLocalEngine(result: .ok),
                        remote: remote
                    )
                )
                _ = player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                            ],
                            localDeviceID: "mac",
                            revision: 1
                        )),
                    source: .engineDevices,
                    revision: 1
                )
                return player
            }

            let rejecting = ScriptedRemoteClient(.fail)
            let rejectionStore = prepareRemoteStore(remote: rejecting)
            var rejectionCompletions: [Bool] = []
            rejectionStore.performRoutedCommand(
                action,
                expecting: false,
                local: .pause,
                remote: .pause
            ) { rejectionCompletions.append($0) }
            _ = await waitUntil { !rejectionCompletions.isEmpty }
            #expect((rejectionCompletions) == ([false]), "remote rejection completion")
            #expect((rejectionStore.transientCommandError) == (action), "remote rejection uses the action notice")
            await rejectionStore.shutdownForTermination()

            let sleeping = ScriptedRemoteClient(.sleepUntilCancelled)
            let cancelStore = prepareRemoteStore(remote: sleeping)
            var cancelCompletions: [Bool] = []
            cancelStore.performRoutedCommand(
                action,
                expecting: false,
                local: .pause,
                remote: .pause
            ) { cancelCompletions.append($0) }
            let pendingReady = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
            #expect((pendingReady) == true, "remote command is pending before cancellation")
            let cancelReached = await waitUntil { await sleeping.sendCount == 1 }
            #expect((cancelReached) == true, "cancelled remote command still reaches the fixture")
            if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancelSettled = await waitUntil {
                cancelStore.state.pendingCommands[.transport] == nil && !cancelCompletions.isEmpty
            }
            #expect((cancelSettled) == true, "cancelled remote command settles")
            #expect((cancelCompletions) == ([false]), "cancelled remote command reports failure once")
            #expect((cancelStore.transientCommandError) == nil, "cancelled remote command has no notice")
            await cancelStore.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let playingAnchor = clockNow.addingTimeInterval(-10)
            let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
            let frozenPauseTiming = PlaybackTiming(
                position: SpottyDomain.interpolatedPlaybackPosition(
                    anchor: 40,
                    anchoredAt: playingAnchor,
                    now: clockNow,
                    isPlaying: true,
                    duration: 200
                ),
                duration: 200,
                anchoredAt: clockNow
            )
            let pausedTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: playingAnchor)
            let resumeTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: clockNow)

            @MainActor
            func seedRemotePlayback(
                _ player: PlaybackStore,
                transport: PlaybackTransportState,
                timing: PlaybackTiming
            ) {
                _ = player.send(.session(.ready), source: .account)
                _ = player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                            ],
                            localDeviceID: "mac",
                            revision: 1
                        )),
                    source: .engineDevices,
                    revision: 1
                )
                _ = player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: "spotify:track:fixture",
                                title: "Now",
                                artist: "Artist",
                                duration: 200,
                                metadataSource: .catalog
                            ),
                            transport: transport,
                            timing: timing
                        )),
                    source: .user
                )
            }

            let pauseFailStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
            )
            seedRemotePlayback(pauseFailStore, transport: .playing, timing: priorPlayingTiming)
            #expect((pauseFailStore.canTogglePlayback) == true, "remote pause can toggle before the command")
            pauseFailStore.togglePlayback()
            #expect(
                (pauseFailStore.state.transport) == (.paused), "remote pause applies paused transport before completion"
            )
            #expect(
                (pauseFailStore.state.timing) == (frozenPauseTiming),
                "remote pause freezes displayed timing before completion")
            _ = await waitUntil { pauseFailStore.state.pendingCommands[.transport] == nil }
            #expect((pauseFailStore.state.transport) == (.playing), "remote pause rejection restores playing")
            #expect(
                (pauseFailStore.state.timing) == (priorPlayingTiming),
                "remote pause rejection restores exact prior timing")
            #expect(
                (pauseFailStore.transientCommandError) == ("Pause was rejected"),
                "remote pause rejection uses the action notice")
            await pauseFailStore.shutdownForTermination()

            let resumeFailStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
            )
            seedRemotePlayback(resumeFailStore, transport: .paused, timing: pausedTiming)
            resumeFailStore.togglePlayback()
            #expect((resumeFailStore.state.transport) == (.playing), "remote resume applies playing before completion")
            #expect(
                (resumeFailStore.state.timing) == (resumeTiming), "remote resume re-anchors from the injected clock")
            _ = await waitUntil { resumeFailStore.state.pendingCommands[.transport] == nil }
            #expect((resumeFailStore.state.transport) == (.paused), "remote resume rejection restores paused")
            #expect(
                (resumeFailStore.state.timing) == (pausedTiming), "remote resume rejection restores exact prior timing")
            await resumeFailStore.shutdownForTermination()

            let pauseOkStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedRemotePlayback(pauseOkStore, transport: .playing, timing: priorPlayingTiming)
            pauseOkStore.togglePlayback()
            _ = await waitUntil { pauseOkStore.state.pendingCommands[.transport] == nil }
            #expect((pauseOkStore.state.transport) == (.paused), "accepted remote pause keeps paused transport")
            #expect((pauseOkStore.state.timing) == (frozenPauseTiming), "accepted remote pause keeps frozen timing")
            #expect((pauseOkStore.transientCommandError) == nil, "accepted remote pause has no command notice")
            await pauseOkStore.shutdownForTermination()

            let seekFailStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
            )
            seedRemotePlayback(seekFailStore, transport: .playing, timing: priorPlayingTiming)
            seekFailStore.seek(to: 0.4)
            #expect((seekFailStore.state.timing.position) == (80), "seek applies optimistic timing before completion")
            #expect((seekFailStore.state.transport) == (.playing), "seek leaves transport playing")
            _ = await waitUntil { seekFailStore.state.pendingCommands[.seek] == nil }
            #expect((seekFailStore.state.timing) == (priorPlayingTiming), "rejected seek restores exact prior timing")
            #expect(
                (seekFailStore.transientCommandError) == ("Seek was rejected"), "rejected seek uses the action notice")
            await seekFailStore.shutdownForTermination()

            let seekOkStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedRemotePlayback(seekOkStore, transport: .paused, timing: pausedTiming)
            seekOkStore.seek(to: 0.4)
            _ = await waitUntil { seekOkStore.state.pendingCommands[.seek] == nil }
            #expect((seekOkStore.state.timing.position) == (80), "accepted seek keeps optimistic timing")
            #expect((seekOkStore.state.transport) == (.paused), "accepted seek does not change transport")
            await seekOkStore.shutdownForTermination()

            let localSeekFail = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
            )
            _ = localSeekFail.send(.session(.ready), source: .account)
            _ = localSeekFail.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                        localDeviceID: "mac",
                        revision: 1
                    )),
                source: .engineDevices,
                revision: 1
            )
            _ = localSeekFail.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture",
                            title: "Now",
                            artist: "Artist",
                            duration: 200,
                            metadataSource: .catalog
                        ),
                        transport: .playing,
                        timing: priorPlayingTiming
                    )),
                source: .user
            )
            localSeekFail.seek(to: 0.4)
            #expect((localSeekFail.state.timing.position) == (80), "local seek applies optimistic timing")
            _ = await waitUntil { localSeekFail.state.pendingCommands[.seek] == nil }
            #expect(
                (localSeekFail.state.timing) == (priorPlayingTiming), "local seek rejection restores exact prior timing"
            )
            await localSeekFail.shutdownForTermination()

            let joining = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            _ = joining.send(.session(.ready), source: .account)
            _ = joining.send(.owner(.uncertain(nil)), source: .command)
            _ = joining.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture",
                            title: "Now",
                            artist: "Artist",
                            duration: 200,
                            metadataSource: .catalog
                        ),
                        transport: .playing,
                        timing: priorPlayingTiming
                    )),
                source: .user
            )
            let joiningBefore = joining.state
            joining.togglePlayback()
            joining.seek(to: 0.5)
            #expect(
                (joining.state.transport) == (joiningBefore.transport), "route refusal leaves presentation unchanged")
            #expect((joining.state.timing) == (joiningBefore.timing), "route refusal leaves timing unchanged")
            #expect((joining.state.pendingCommands.isEmpty) == true, "route refusal does not start a pending command")
            #expect(
                (joining.transientCommandError) == ("Spotty is still joining Spotify Connect."),
                "route refusal still surfaces the joining notice")
            await joining.shutdownForTermination()

            let duplicateRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let duplicateStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: duplicateRemote)
            )
            seedRemotePlayback(duplicateStore, transport: .playing, timing: priorPlayingTiming)
            duplicateStore.seek(to: 0.4)
            let seekPending = await waitUntil { duplicateStore.state.pendingCommands[.seek] != nil }
            #expect((seekPending) == true, "the first seek is pending before a duplicate toggle")
            let afterSeek = duplicateStore.state
            duplicateStore.togglePlayback()
            #expect(
                (duplicateStore.state.transport) == (afterSeek.transport),
                "a duplicate toggle does not change transport")
            #expect((duplicateStore.state.timing) == (afterSeek.timing), "a duplicate toggle does not change timing")
            #expect(
                (duplicateStore.state.pendingCommands[.transport]) == nil,
                "a duplicate toggle does not start a transport command")
            if let commandID = duplicateStore.state.pendingCommands[.seek]?.id {
                duplicateStore.effects.cancel(.command(commandID))
            }
            await duplicateStore.shutdownForTermination()

            let cancelRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let cancelStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: cancelRemote)
            )
            seedRemotePlayback(cancelStore, transport: .playing, timing: priorPlayingTiming)
            cancelStore.togglePlayback()
            let pausePending = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
            #expect((pausePending) == true, "remote pause is pending before cancellation")
            let pauseReached = await waitUntil { await cancelRemote.sendCount == 1 }
            #expect((pauseReached) == true, "cancelled remote pause still reaches the fixture")
            if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancelSettled = await waitUntil { cancelStore.state.pendingCommands[.transport] == nil }
            #expect((cancelSettled) == true, "cancellation settles the pending pause")
            #expect((cancelStore.state.transport) == (.playing), "cancellation restores playing transport")
            #expect((cancelStore.state.timing) == (priorPlayingTiming), "cancellation restores the captured timing")
            #expect((cancelStore.state.pendingCommands[.transport]) == nil, "cancellation clears the pending command")
            #expect((cancelStore.transientCommandError) == nil, "cancellation does not surface a command notice")
            await cancelStore.shutdownForTermination()

            let staleStore = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.sleepUntilCancelled))
            )
            seedRemotePlayback(staleStore, transport: .playing, timing: priorPlayingTiming)
            staleStore.seek(to: 0.4)
            let stalePending = await waitUntil { staleStore.state.pendingCommands[.seek] != nil }
            #expect((stalePending) == true, "seek is pending before an engine-epoch bump")
            let optimisticSeekTiming = staleStore.state.timing
            _ = staleStore.send(
                .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                revision: 1,
                engineEpoch: staleStore.engineGeneration + 1
            )
            #expect((staleStore.state.pendingCommands[.seek]) == nil, "an engine-epoch bump drops the pending seek")
            #expect(
                (staleStore.state.timing) == (optimisticSeekTiming),
                "an engine-epoch bump does not roll back seek timing")
            await staleStore.shutdownForTermination()

            let trackSwitchRemote = GatedFailingRemoteClient()
            let trackSwitchStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: trackSwitchRemote)
            )
            seedRemotePlayback(trackSwitchStore, transport: .playing, timing: priorPlayingTiming)
            trackSwitchStore.seek(to: 0.4)
            let trackSwitchPending = await waitUntil { trackSwitchStore.state.pendingCommands[.seek] != nil }
            #expect((trackSwitchPending) == true, "seek is pending before a same-engine track switch")
            let sendStarted = await waitUntil { await trackSwitchRemote.sendCount == 1 }
            #expect((sendStarted) == true, "the seek has reached the remote client before the track switch")
            let trackBTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: clockNow)
            _ = trackSwitchStore.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:other",
                        timing: trackBTiming
                    )),
                source: .enginePlayback,
                revision: 1
            )
            #expect(
                (trackSwitchStore.state.currentTrack?.uri) == ("spotify:track:other"),
                "a track switch adopts the new track URI")
            #expect((trackSwitchStore.state.timing) == (trackBTiming), "a track switch adopts the incoming timing")
            #expect(
                (trackSwitchStore.state.pendingCommands[.seek]) == nil, "a track switch clears the old pending seek")
            let afterTrackSwitch = trackSwitchStore.state
            await trackSwitchRemote.fail()
            for _ in 0..<50 { await Task.yield() }
            #expect(
                (trackSwitchStore.state.timing) == (afterTrackSwitch.timing),
                "a rejected finish after a track switch leaves timing unchanged")
            #expect(
                (trackSwitchStore.state.currentTrack?.uri) == ("spotify:track:other"),
                "a rejected finish after a track switch leaves the new track")
            #expect(
                (trackSwitchStore.transientCommandError) == nil,
                "a rejected finish after a track switch does not surface a seek notice")
            await trackSwitchStore.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let playingAnchor = clockNow.addingTimeInterval(-10)
            let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
            let trackA = CatalogTrack(
                id: "a",
                uri: "spotify:track:a",
                title: "A",
                artist: "Artist",
                album: "Album",
                duration: 200,
                artworkURL: nil,
                addedAt: nil
            )
            let trackB = CatalogTrack(
                id: "b",
                uri: "spotify:track:b",
                title: "B",
                artist: "Artist",
                album: "Album",
                duration: 180,
                artworkURL: nil,
                addedAt: nil
            )
            let optimisticTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: clockNow)

            @MainActor
            func seedPlayingA(_ player: PlaybackStore, local: Bool) {
                _ = player.send(.session(.ready), source: .account)
                if local {
                    _ = player.send(
                        .devices(
                            PlaybackDeviceSnapshot(
                                devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                                localDeviceID: "mac",
                                revision: 1
                            )),
                        source: .engineDevices,
                        revision: 1
                    )
                } else {
                    _ = player.send(
                        .devices(
                            PlaybackDeviceSnapshot(
                                devices: [
                                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                                ],
                                localDeviceID: "mac",
                                revision: 1
                            )),
                        source: .engineDevices,
                        revision: 1
                    )
                }
                _ = player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: trackA.uri,
                                title: trackA.title,
                                artist: trackA.artist,
                                duration: trackA.duration,
                                metadataSource: .catalog
                            ),
                            transport: .playing,
                            timing: priorPlayingTiming
                        )),
                    source: .user
                )
            }

            @MainActor
            func sendEnginePlayback(
                _ player: PlaybackStore,
                uri: String?,
                transport: PlaybackTransportState,
                timing: PlaybackTiming,
                revision: UInt64
            ) {
                _ = player.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: transport,
                            trackURI: uri,
                            timing: timing
                        )),
                    source: .enginePlayback,
                    revision: revision
                )
            }

            let localRejected = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(localRejected, local: true)
            localRejected.play(track: trackB)
            #expect((localRejected.state.currentTrack?.uri) == (trackB.uri), "local play presents B before completion")
            #expect((localRejected.state.transport) == (.playing), "local play applies playing before completion")
            #expect(
                (localRejected.state.timing) == (optimisticTiming), "local play applies target timing before completion"
            )
            _ = await waitUntil { localRejected.state.pendingCommands[.transport] == nil }
            #expect((localRejected.state.currentTrack?.uri) == (trackA.uri), "local play rejection restores A")
            #expect(
                (localRejected.state.timing) == (priorPlayingTiming), "local play rejection restores exact prior timing"
            )
            #expect(
                (!localRejected.history.entries.contains { $0.uri == trackB.uri }) == true,
                "local play rejection does not record B")
            #expect(
                (localRejected.transientCommandError) == ("Could not play that Spotify URI"),
                "local play rejection uses the action notice")
            await localRejected.shutdownForTermination()

            let localAccepted = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(localAccepted, local: true)
            localAccepted.play(track: trackB)
            _ = await waitUntil { localAccepted.state.pendingCommands[.transport] == nil }
            #expect((localAccepted.state.currentTrack?.uri) == (trackB.uri), "accepted local play keeps B")
            #expect((localAccepted.state.transport) == (.playing), "accepted local play keeps playing")
            #expect(
                (localAccepted.history.entries.contains { $0.uri == trackB.uri }) == true,
                "accepted local play records B")
            await localAccepted.shutdownForTermination()

            let remoteRejected = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
            )
            seedPlayingA(remoteRejected, local: false)
            remoteRejected.play(track: trackB)
            #expect(
                (remoteRejected.state.currentTrack?.uri) == (trackB.uri), "remote play presents B before completion")
            _ = await waitUntil { remoteRejected.state.pendingCommands[.transport] == nil }
            #expect((remoteRejected.state.currentTrack?.uri) == (trackA.uri), "remote play rejection restores A")
            #expect(
                (remoteRejected.state.timing) == (priorPlayingTiming),
                "remote play rejection restores exact prior timing")
            #expect(
                (!remoteRejected.history.entries.contains { $0.uri == trackB.uri }) == true,
                "remote play rejection does not record B")
            await remoteRejected.shutdownForTermination()

            let remoteAccepted = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(remoteAccepted, local: false)
            remoteAccepted.play(track: trackB)
            _ = await waitUntil { remoteAccepted.state.pendingCommands[.transport] == nil }
            #expect((remoteAccepted.state.currentTrack?.uri) == (trackB.uri), "accepted remote play keeps B")
            #expect(
                (remoteAccepted.history.entries.contains { $0.uri == trackB.uri }) == true,
                "accepted remote play records B"
            )
            await remoteAccepted.shutdownForTermination()

            let laggingRemote = GatedFailingRemoteClient()
            let laggingStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: laggingRemote)
            )
            seedPlayingA(laggingStore, local: false)
            laggingStore.play(track: trackB)
            let laggingPending = await waitUntil { laggingStore.state.pendingCommands[.transport] != nil }
            #expect((laggingPending) == true, "remote play is pending before a lagging A snapshot")
            _ = await waitUntil { await laggingRemote.sendCount == 1 }
            sendEnginePlayback(
                laggingStore,
                uri: trackA.uri,
                transport: .playing,
                timing: PlaybackTiming(position: 44, duration: 200, anchoredAt: clockNow),
                revision: 1
            )
            #expect((laggingStore.state.currentTrack?.uri) == (trackB.uri), "a lagging A snapshot keeps optimistic B")
            #expect((laggingStore.state.timing) == (optimisticTiming), "a lagging A snapshot keeps B timing")
            #expect(
                (laggingStore.state.pendingCommands[.transport]) != nil, "a lagging A snapshot keeps rollback ownership"
            )
            await laggingRemote.fail()
            _ = await waitUntil { laggingStore.state.pendingCommands[.transport] == nil }
            #expect((laggingStore.state.currentTrack?.uri) == (trackA.uri), "lagging A then rejection restores A")
            #expect(
                (laggingStore.state.timing) == (priorPlayingTiming), "lagging A then rejection restores exact timing")
            #expect(
                (!laggingStore.history.entries.contains { $0.uri == trackB.uri }) == true,
                "lagging A then rejection does not record B")
            await laggingStore.shutdownForTermination()

            let confirmRemote = GatedFailingRemoteClient()
            let confirmStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: confirmRemote)
            )
            seedPlayingA(confirmStore, local: false)
            confirmStore.play(track: trackB)
            _ = await waitUntil { confirmStore.state.pendingCommands[.transport] != nil }
            _ = await waitUntil { await confirmRemote.sendCount == 1 }
            let confirmedCommandID = confirmStore.state.pendingCommands[.transport]?.id
            sendEnginePlayback(
                confirmStore,
                uri: trackB.uri,
                transport: .playing,
                timing: PlaybackTiming(position: 1, duration: 180, anchoredAt: clockNow),
                revision: 1
            )
            #expect(
                (confirmStore.state.pendingCommands[.transport]) == nil, "an authoritative B snapshot confirms the play"
            )
            #expect(
                (confirmedCommandID.flatMap { confirmStore.state.transportCommandResolutions[$0] })
                    == (Optional(PlaybackTransportCommandResolution.confirmed)),
                "an authoritative B snapshot records confirmation")
            await confirmRemote.fail()
            _ = await waitUntil { confirmStore.history.entries.contains { $0.uri == trackB.uri } }
            #expect((confirmStore.state.currentTrack?.uri) == (trackB.uri), "confirmed B then failure keeps B")
            #expect((confirmStore.transientCommandError) == nil, "confirmed B then failure has no command notice")
            #expect(
                (confirmStore.history.entries.contains { $0.uri == trackB.uri }) == true,
                "confirmed B then failure still records B")
            #expect(
                (confirmStore.state.transportCommandResolutions.isEmpty) == true,
                "confirmed B then failure consumes the resolution entry")
            await confirmStore.shutdownForTermination()

            let supersedeRemote = GatedFailingRemoteClient()
            let supersedeStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: supersedeRemote)
            )
            seedPlayingA(supersedeStore, local: false)
            supersedeStore.play(track: trackB)
            _ = await waitUntil { supersedeStore.state.pendingCommands[.transport] != nil }
            _ = await waitUntil { await supersedeRemote.sendCount == 1 }
            let trackCTiming = PlaybackTiming(position: 8, duration: 240, anchoredAt: clockNow)
            sendEnginePlayback(
                supersedeStore,
                uri: "spotify:track:c",
                transport: .playing,
                timing: trackCTiming,
                revision: 1
            )
            #expect((supersedeStore.state.currentTrack?.uri) == ("spotify:track:c"), "an unrelated C snapshot adopts C")
            #expect(
                (supersedeStore.state.pendingCommands[.transport]) == nil, "an unrelated C snapshot clears B rollback")
            await supersedeRemote.fail()
            for _ in 0..<50 { await Task.yield() }
            #expect(
                (supersedeStore.state.currentTrack?.uri) == ("spotify:track:c"), "C supersession then failure leaves C")
            #expect((supersedeStore.state.timing) == (trackCTiming), "C supersession then failure keeps C timing")
            #expect(
                (!supersedeStore.history.entries.contains { $0.uri == trackB.uri }) == true,
                "C supersession then failure does not record B")
            #expect((supersedeStore.transientCommandError) == nil, "C supersession then failure has no play notice")
            #expect(
                (supersedeStore.state.transportCommandResolutions.isEmpty) == true,
                "C supersession then failure consumes the resolution entry")
            await supersedeStore.shutdownForTermination()

            let nilRemote = GatedFailingRemoteClient()
            let nilStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: nilRemote)
            )
            seedPlayingA(nilStore, local: false)
            nilStore.play(track: trackB)
            _ = await waitUntil { nilStore.state.pendingCommands[.transport] != nil }
            _ = await waitUntil { await nilRemote.sendCount == 1 }
            sendEnginePlayback(
                nilStore,
                uri: nil,
                transport: .stopped,
                timing: PlaybackTiming(anchoredAt: clockNow),
                revision: 1
            )
            #expect((nilStore.state.currentTrack) == nil, "a nil snapshot clears the optimistic track")
            await nilRemote.fail()
            for _ in 0..<50 { await Task.yield() }
            #expect((nilStore.state.currentTrack) == nil, "nil supersession then failure stays cleared")
            #expect(
                (!nilStore.history.entries.contains { $0.uri == trackB.uri }) == true,
                "nil supersession then failure does not record B")
            await nilStore.shutdownForTermination()

            let joining = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            _ = joining.send(.session(.ready), source: .account)
            _ = joining.send(.owner(.uncertain(nil)), source: .command)
            _ = joining.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: trackA.uri,
                            title: trackA.title,
                            artist: trackA.artist,
                            duration: trackA.duration,
                            metadataSource: .catalog
                        ),
                        transport: .playing,
                        timing: priorPlayingTiming
                    )),
                source: .user
            )
            let joiningBefore = joining.state
            joining.play(track: trackB)
            #expect(
                (joining.state.currentTrack) == (joiningBefore.currentTrack),
                "route refusal leaves the current track unchanged")
            #expect((joining.state.timing) == (joiningBefore.timing), "route refusal leaves timing unchanged")
            #expect((joining.state.pendingCommands.isEmpty) == true, "route refusal does not start a pending play")
            #expect((joining.history.entries.isEmpty) == true, "route refusal does not record B")
            await joining.shutdownForTermination()

            let duplicateRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let duplicateStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: duplicateRemote)
            )
            seedPlayingA(duplicateStore, local: false)
            duplicateStore.play(track: trackB)
            let playPending = await waitUntil { duplicateStore.state.pendingCommands[.transport] != nil }
            #expect((playPending) == true, "the first play is pending before a duplicate")
            let afterFirstPlay = duplicateStore.state
            duplicateStore.play(track: trackB)
            #expect(
                (duplicateStore.state.currentTrack) == (afterFirstPlay.currentTrack),
                "a duplicate play does not change presentation")
            #expect(
                (duplicateStore.state.pendingCommands[.transport]?.id)
                    == (afterFirstPlay.pendingCommands[.transport]?.id),
                "a duplicate play keeps the original command")
            if let commandID = duplicateStore.state.pendingCommands[.transport]?.id {
                duplicateStore.effects.cancel(.command(commandID))
            }
            await duplicateStore.shutdownForTermination()

            let cancelRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let cancelStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: cancelRemote)
            )
            seedPlayingA(cancelStore, local: false)
            cancelStore.play(track: trackB)
            let cancelPending = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
            #expect((cancelPending) == true, "remote play is pending before cancellation")
            let playReached = await waitUntil { await cancelRemote.sendCount == 1 }
            #expect((playReached) == true, "cancelled remote play still reaches the fixture")
            if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancelSettled = await waitUntil { cancelStore.state.pendingCommands[.transport] == nil }
            #expect((cancelSettled) == true, "cancellation settles the pending play")
            #expect(
                (cancelStore.state.currentTrack?.uri) == ("spotify:track:a"), "cancellation restores the captured track"
            )
            #expect((cancelStore.state.pendingCommands[.transport]) == nil, "cancellation clears the pending play")
            #expect((cancelStore.history.entries.isEmpty) == true, "cancellation does not record B")
            await cancelStore.shutdownForTermination()

            let staleStore = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.sleepUntilCancelled))
            )
            seedPlayingA(staleStore, local: false)
            staleStore.play(track: trackB)
            let stalePending = await waitUntil { staleStore.state.pendingCommands[.transport] != nil }
            #expect((stalePending) == true, "play is pending before an engine-epoch bump")
            let optimisticPlay = staleStore.state
            _ = staleStore.send(
                .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                revision: 1,
                engineEpoch: staleStore.engineGeneration + 1
            )
            #expect(
                (staleStore.state.pendingCommands[.transport]) == nil, "an engine-epoch bump drops the pending play")
            #expect(
                (staleStore.state.currentTrack?.uri) == (optimisticPlay.currentTrack?.uri),
                "an engine-epoch bump does not roll back B")
            #expect(
                (staleStore.state.transportCommandResolutions.isEmpty) == true,
                "an engine-epoch bump clears play confirmation state")
            await staleStore.shutdownForTermination()

            let playlistStore = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(playlistStore, local: true)
            let playlist = CatalogItem(
                id: "pl",
                uri: "spotify:playlist:loaded",
                title: "Mix",
                subtitle: "Me",
                artworkURL: nil,
                kind: .playlist
            )
            playlistStore.catalog.playlistStore.replaceLoadedPlaylist(uri: playlist.uri, tracks: [trackB])
            playlistStore.playPlaylist(playlist)
            #expect(
                (playlistStore.state.currentTrack?.uri) == (trackB.uri),
                "a loaded playlist presents the known first track")
            _ = await waitUntil { playlistStore.state.pendingCommands[.transport] == nil }
            #expect((playlistStore.state.currentTrack?.uri) == (trackA.uri), "a rejected loaded playlist restores A")
            #expect(
                (!playlistStore.history.entries.contains { $0.uri == trackB.uri }) == true,
                "a rejected loaded playlist does not record B")
            await playlistStore.shutdownForTermination()

            let unknownPlaylist = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(unknownPlaylist, local: true)
            let unknown = CatalogItem(
                id: "other",
                uri: "spotify:playlist:unknown",
                title: "Other",
                subtitle: "Me",
                artworkURL: nil,
                kind: .playlist
            )
            unknownPlaylist.playPlaylist(unknown)
            #expect(
                (unknownPlaylist.state.currentTrack?.uri) == (trackA.uri),
                "an unknown playlist does not invent a first track")
            _ = await waitUntil { unknownPlaylist.state.pendingCommands[.transport] == nil }
            #expect(
                (unknownPlaylist.state.currentTrack?.uri) == (trackA.uri),
                "an accepted unknown playlist keeps A until the engine speaks")
            #expect(
                (unknownPlaylist.history.entries.isEmpty) == true, "an unknown playlist does not record a first track")
            await unknownPlaylist.shutdownForTermination()

            let rawURI = playbackStore(
                commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(rawURI, local: true)
            rawURI.play(uri: trackB.uri)
            #expect((rawURI.state.currentTrack?.uri) == (trackA.uri), "raw play(uri:) does not invent track metadata")
            _ = await waitUntil { rawURI.state.pendingCommands[.transport] == nil }
            #expect(
                (rawURI.state.currentTrack?.uri) == (trackA.uri),
                "accepted raw play(uri:) still keeps A until the engine speaks")
            #expect(
                (rawURI.history.entries.contains { $0.uri == trackB.uri }) == true,
                "accepted raw play(uri:) records the URI")
            await rawURI.shutdownForTermination()

            let localGate = GatedLocalEngine()
            let localRace = playbackStore(
                commandEnvironment(local: localGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedPlayingA(localRace, local: true)
            localRace.play(track: trackB)
            let localRacePending = await waitUntil { localRace.state.pendingCommands[.transport] != nil }
            #expect((localRacePending) == true, "local play is pending before a lagging A snapshot")
            sendEnginePlayback(
                localRace,
                uri: trackA.uri,
                transport: .playing,
                timing: PlaybackTiming(position: 44, duration: 200, anchoredAt: clockNow),
                revision: 1
            )
            #expect((localRace.state.currentTrack?.uri) == (trackB.uri), "local lagging A keeps optimistic B")
            localGate.finish(with: .error)
            _ = await waitUntil { localRace.state.pendingCommands[.transport] == nil }
            #expect((localRace.state.currentTrack?.uri) == (trackA.uri), "local lagging A then rejection restores A")
            #expect(
                (!localRace.history.entries.contains { $0.uri == trackB.uri }) == true,
                "local lagging A then rejection does not record B")
            await localRace.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let priorPlayingTiming = PlaybackTiming(
                position: 40, duration: 200, anchoredAt: clockNow.addingTimeInterval(-10))
            let current = CurrentTrack(
                uri: "spotify:track:a",
                title: "A",
                artist: "Artist",
                duration: 200,
                metadataSource: .catalog
            )

            @MainActor
            func seedLiveShuffle(_ player: PlaybackStore, local: Bool, shuffle: Bool) {
                _ = player.send(.session(.ready), source: .account)
                if local {
                    _ = player.send(
                        .devices(
                            PlaybackDeviceSnapshot(
                                devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                                localDeviceID: "mac",
                                revision: 1
                            )),
                        source: .engineDevices,
                        revision: 1
                    )
                } else {
                    _ = player.send(
                        .devices(
                            PlaybackDeviceSnapshot(
                                devices: [
                                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                                ],
                                localDeviceID: "mac",
                                revision: 1
                            )),
                        source: .engineDevices,
                        revision: 1
                    )
                }
                _ = player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: current,
                            transport: .playing,
                            timing: priorPlayingTiming
                        )),
                    source: .user
                )
                _ = player.send(.options(PlaybackOptions(shuffle: shuffle)), source: .user)
            }

            @MainActor
            func sendEngineShuffle(_ player: PlaybackStore, shuffle: Bool, revision: UInt64) {
                _ = player.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing,
                            trackURI: current.uri,
                            timing: priorPlayingTiming,
                            shuffle: shuffle
                        )),
                    source: .enginePlayback,
                    revision: revision
                )
            }

            @MainActor
            func restoredStore(
                local: any LocalPlaybackEngine,
                remote: any RemotePlaybackClient,
                preferences: RecordingPreferences
            ) async -> PlaybackStore {
                let player = playbackStore(
                    commandEnvironment(local: local, remote: remote, preferences: preferences)
                )
                _ = await waitUntil { player.shuffleHistoryCache["restored"] == 1 }
                return player
            }

            let localRejectedPrefs = RecordingPreferences(shuffle: true)
            let localRejected = await restoredStore(
                local: ScriptedLocalEngine(result: .error),
                remote: ScriptedRemoteClient(.succeed),
                preferences: localRejectedPrefs
            )
            seedLiveShuffle(localRejected, local: true, shuffle: true)
            localRejected.toggleShuffle()
            #expect((localRejected.state.options.shuffle) == (false), "local shuffle presents off before completion")
            #expect(
                (localRejected.state.pendingCommands[.options]) != nil, "local shuffle is pending before completion")
            _ = await waitUntil { localRejected.state.pendingCommands[.options] == nil }
            #expect((localRejected.state.options.shuffle) == (true), "local shuffle rejection restores on")
            #expect(
                (localRejected.transientCommandError) == ("Could not update shuffle"),
                "local shuffle rejection uses the action notice")
            #expect(
                (await localRejectedPrefs.shuffleWrites.isEmpty) == true, "local shuffle rejection does not persist off"
            )
            await localRejected.shutdownForTermination()

            let localAcceptedPrefs = RecordingPreferences(shuffle: true)
            let localAccepted = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed),
                preferences: localAcceptedPrefs
            )
            seedLiveShuffle(localAccepted, local: true, shuffle: true)
            localAccepted.toggleShuffle()
            _ = await waitUntil { localAccepted.state.pendingCommands[.options] == nil }
            #expect((localAccepted.state.options.shuffle) == (false), "accepted local shuffle keeps off")
            _ = await waitUntil { await localAcceptedPrefs.shuffleWrites == [false] }
            #expect((await localAcceptedPrefs.shuffleWrites) == ([false]), "accepted local shuffle persists off")
            localAccepted.toggleShuffle()
            #expect(
                (localAccepted.state.options.shuffle) == (true), "a later local shuffle presents on before completion")
            _ = await waitUntil { localAccepted.state.pendingCommands[.options] == nil }
            #expect((localAccepted.state.options.shuffle) == (true), "an accepted later local shuffle keeps on")
            _ = await waitUntil { await localAcceptedPrefs.shuffleWrites == [false, true] }
            #expect(
                (await localAcceptedPrefs.shuffleWrites) == ([false, true]),
                "an accepted later local shuffle persists on")
            await localAccepted.shutdownForTermination()

            let remoteRejectedPrefs = RecordingPreferences(shuffle: true)
            let remoteRejected = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.fail),
                preferences: remoteRejectedPrefs
            )
            seedLiveShuffle(remoteRejected, local: false, shuffle: true)
            remoteRejected.toggleShuffle()
            #expect((remoteRejected.state.options.shuffle) == (false), "remote shuffle presents off before completion")
            _ = await waitUntil { remoteRejected.state.pendingCommands[.options] == nil }
            #expect((remoteRejected.state.options.shuffle) == (true), "remote shuffle rejection restores on")
            #expect(
                (await remoteRejectedPrefs.shuffleWrites.isEmpty) == true,
                "remote shuffle rejection does not persist off")
            await remoteRejected.shutdownForTermination()

            let remoteAcceptedPrefs = RecordingPreferences(shuffle: true)
            let remoteAccepted = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed),
                preferences: remoteAcceptedPrefs
            )
            seedLiveShuffle(remoteAccepted, local: false, shuffle: true)
            remoteAccepted.toggleShuffle()
            _ = await waitUntil { remoteAccepted.state.pendingCommands[.options] == nil }
            #expect((remoteAccepted.state.options.shuffle) == (false), "accepted remote shuffle keeps off")
            _ = await waitUntil { await remoteAcceptedPrefs.shuffleWrites == [false] }
            #expect((await remoteAcceptedPrefs.shuffleWrites) == ([false]), "accepted remote shuffle persists off")
            await remoteAccepted.shutdownForTermination()

            let laggingRemote = GatedFailingRemoteClient()
            let laggingPrefs = RecordingPreferences(shuffle: true)
            let laggingStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: laggingRemote,
                preferences: laggingPrefs
            )
            seedLiveShuffle(laggingStore, local: false, shuffle: true)
            laggingStore.toggleShuffle()
            let laggingPending = await waitUntil { laggingStore.state.pendingCommands[.options] != nil }
            #expect((laggingPending) == true, "remote shuffle is pending before a lagging on snapshot")
            _ = await waitUntil { await laggingRemote.sendCount == 1 }
            sendEngineShuffle(laggingStore, shuffle: true, revision: 1)
            #expect((laggingStore.state.options.shuffle) == (false), "a lagging on snapshot keeps optimistic off")
            #expect(
                (laggingStore.state.pendingCommands[.options]) != nil, "a lagging on snapshot keeps rollback ownership")
            await laggingRemote.fail()
            _ = await waitUntil { laggingStore.state.pendingCommands[.options] == nil }
            #expect((laggingStore.state.options.shuffle) == (true), "lagging on then rejection restores on")
            #expect(
                (await laggingPrefs.shuffleWrites.isEmpty) == true, "lagging on then rejection does not persist off")
            await laggingStore.shutdownForTermination()

            let confirmRemote = GatedFailingRemoteClient()
            let confirmPrefs = RecordingPreferences(shuffle: true)
            let confirmStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: confirmRemote,
                preferences: confirmPrefs
            )
            seedLiveShuffle(confirmStore, local: false, shuffle: true)
            confirmStore.toggleShuffle()
            _ = await waitUntil { confirmStore.state.pendingCommands[.options] != nil }
            _ = await waitUntil { await confirmRemote.sendCount == 1 }
            let confirmedCommandID = confirmStore.state.pendingCommands[.options]?.id
            sendEngineShuffle(confirmStore, shuffle: false, revision: 1)
            #expect(
                (confirmStore.state.pendingCommands[.options]) == nil, "an authoritative off snapshot confirms shuffle")
            #expect(
                (confirmedCommandID.flatMap { confirmStore.state.transportCommandResolutions[$0] })
                    == (Optional(PlaybackTransportCommandResolution.confirmed)),
                "an authoritative off snapshot records shuffle confirmation")
            await confirmRemote.fail()
            _ = await waitUntil { await confirmPrefs.shuffleWrites == [false] }
            #expect((confirmStore.state.options.shuffle) == (false), "confirmed off then failure keeps off")
            #expect((confirmStore.transientCommandError) == nil, "confirmed off then failure has no command notice")
            #expect((await confirmPrefs.shuffleWrites) == ([false]), "confirmed off then failure persists off")
            #expect(
                (confirmStore.state.transportCommandResolutions.isEmpty) == true,
                "confirmed off then failure consumes the resolution entry")
            await confirmStore.shutdownForTermination()

            let localGate = GatedLocalEngine()
            let localRacePrefs = RecordingPreferences(shuffle: true)
            let localRace = await restoredStore(
                local: localGate,
                remote: ScriptedRemoteClient(.succeed),
                preferences: localRacePrefs
            )
            seedLiveShuffle(localRace, local: true, shuffle: true)
            localRace.toggleShuffle()
            let localRacePending = await waitUntil { localRace.state.pendingCommands[.options] != nil }
            #expect((localRacePending) == true, "local shuffle is pending before a lagging on snapshot")
            sendEngineShuffle(localRace, shuffle: true, revision: 1)
            #expect((localRace.state.options.shuffle) == (false), "local lagging on keeps optimistic off")
            localGate.finish(with: .error)
            _ = await waitUntil { localRace.state.pendingCommands[.options] == nil }
            #expect((localRace.state.options.shuffle) == (true), "local lagging on then rejection restores on")
            #expect(
                (await localRacePrefs.shuffleWrites.isEmpty) == true,
                "local lagging on then rejection does not persist off"
            )
            await localRace.shutdownForTermination()

            let joiningPrefs = RecordingPreferences(shuffle: true)
            let joining = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed),
                preferences: joiningPrefs
            )
            _ = joining.send(.session(.ready), source: .account)
            _ = joining.send(
                .owner(.uncertain(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
                source: .command
            )
            _ = joining.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: current,
                        transport: .playing,
                        timing: priorPlayingTiming
                    )),
                source: .user
            )
            _ = joining.send(.options(PlaybackOptions(shuffle: true)), source: .user)
            let joiningBefore = joining.state
            joining.toggleShuffle()
            #expect(
                (joining.state.options.shuffle) == (joiningBefore.options.shuffle),
                "route refusal leaves shuffle unchanged"
            )
            #expect((joining.state.pendingCommands.isEmpty) == true, "route refusal does not start a pending shuffle")
            #expect((await joiningPrefs.shuffleWrites.isEmpty) == true, "route refusal does not persist shuffle")
            await joining.shutdownForTermination()

            let duplicateRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let duplicatePrefs = RecordingPreferences(shuffle: true)
            let duplicateStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: duplicateRemote,
                preferences: duplicatePrefs
            )
            seedLiveShuffle(duplicateStore, local: false, shuffle: true)
            duplicateStore.toggleShuffle()
            let shufflePending = await waitUntil { duplicateStore.state.pendingCommands[.options] != nil }
            #expect((shufflePending) == true, "the first shuffle is pending before a duplicate")
            let afterFirstShuffle = duplicateStore.state
            duplicateStore.toggleShuffle()
            #expect(
                (duplicateStore.state.options) == (afterFirstShuffle.options),
                "a duplicate shuffle does not change options"
            )
            #expect(
                (duplicateStore.state.pendingCommands[.options]?.id)
                    == (afterFirstShuffle.pendingCommands[.options]?.id),
                "a duplicate shuffle keeps the original command")
            #expect((await duplicatePrefs.shuffleWrites.isEmpty) == true, "a duplicate shuffle does not persist")
            if let commandID = duplicateStore.state.pendingCommands[.options]?.id {
                duplicateStore.effects.cancel(.command(commandID))
            }
            await duplicateStore.shutdownForTermination()

            let cancelRemote = ScriptedRemoteClient(.sleepUntilCancelled)
            let cancelPrefs = RecordingPreferences(shuffle: true)
            let cancelStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: cancelRemote,
                preferences: cancelPrefs
            )
            seedLiveShuffle(cancelStore, local: false, shuffle: true)
            cancelStore.toggleShuffle()
            let cancelPending = await waitUntil { cancelStore.state.pendingCommands[.options] != nil }
            #expect((cancelPending) == true, "remote shuffle is pending before cancellation")
            let shuffleReached = await waitUntil { await cancelRemote.sendCount == 1 }
            #expect((shuffleReached) == true, "cancelled remote shuffle still reaches the fixture")
            if let commandID = cancelStore.state.pendingCommands[.options]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancelSettled = await waitUntil { cancelStore.state.pendingCommands[.options] == nil }
            #expect((cancelSettled) == true, "cancellation settles the pending shuffle")
            #expect((cancelStore.state.options.shuffle) == (true), "cancellation restores the captured shuffle")
            #expect((cancelStore.state.pendingCommands[.options]) == nil, "cancellation clears the pending shuffle")
            #expect((await cancelPrefs.shuffleWrites.isEmpty) == true, "cancellation does not persist shuffle")
            await cancelStore.shutdownForTermination()

            let stalePrefs = RecordingPreferences(shuffle: true)
            let staleStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.sleepUntilCancelled),
                preferences: stalePrefs
            )
            seedLiveShuffle(staleStore, local: false, shuffle: true)
            staleStore.toggleShuffle()
            let stalePending = await waitUntil { staleStore.state.pendingCommands[.options] != nil }
            #expect((stalePending) == true, "shuffle is pending before an engine-epoch bump")
            let optimisticShuffle = staleStore.state
            _ = staleStore.send(
                .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                revision: 1,
                engineEpoch: staleStore.engineGeneration + 1
            )
            #expect(
                (staleStore.state.pendingCommands[.options]) == nil, "an engine-epoch bump drops the pending shuffle")
            #expect(
                (staleStore.state.options.shuffle) == (optimisticShuffle.options.shuffle),
                "an engine-epoch bump does not roll back off")
            #expect(
                (staleStore.state.transportCommandResolutions.isEmpty) == true,
                "an engine-epoch bump clears shuffle confirmation state")
            #expect((await stalePrefs.shuffleWrites.isEmpty) == true, "an engine-epoch bump does not persist shuffle")
            await staleStore.shutdownForTermination()

            let restoreRemote = GatedFailingRemoteClient()
            let restorePrefs = RecordingPreferences(shuffle: true)
            let restoreStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: restoreRemote,
                preferences: restorePrefs
            )
            seedLiveShuffle(restoreStore, local: false, shuffle: true)
            restoreStore.toggleShuffle()
            let restorePending = await waitUntil { restoreStore.state.pendingCommands[.options] != nil }
            #expect((restorePending) == true, "remote shuffle is pending before a restoring options event")
            _ = await waitUntil { await restoreRemote.sendCount == 1 }
            _ = restoreStore.send(.options(PlaybackOptions(shuffle: true)), source: .user)
            #expect((restoreStore.state.options.shuffle) == (false), "a restoring options event keeps optimistic off")
            #expect(
                (restoreStore.state.pendingCommands[.options]) != nil,
                "a restoring options event keeps rollback ownership")
            await restoreRemote.fail()
            _ = await waitUntil { restoreStore.state.pendingCommands[.options] == nil }
            #expect((restoreStore.state.options.shuffle) == (true), "restore then rejection restores on")
            #expect((await restorePrefs.shuffleWrites.isEmpty) == true, "restore then rejection does not persist off")
            await restoreStore.shutdownForTermination()

            let matchingRemote = GatedFailingRemoteClient()
            let matchingPrefs = RecordingPreferences(shuffle: true)
            let matchingStore = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: matchingRemote,
                preferences: matchingPrefs
            )
            seedLiveShuffle(matchingStore, local: false, shuffle: true)
            matchingStore.toggleShuffle()
            let matchingPending = await waitUntil { matchingStore.state.pendingCommands[.options] != nil }
            #expect((matchingPending) == true, "remote shuffle is pending before a matching user options event")
            _ = await waitUntil { await matchingRemote.sendCount == 1 }
            _ = matchingStore.send(.options(PlaybackOptions(shuffle: false, repeatMode: .track)), source: .user)
            #expect(
                (matchingStore.state.options.shuffle) == (false), "a matching user options event keeps optimistic off")
            #expect(
                (matchingStore.state.options.repeatMode) == (.track),
                "a matching user options event still adopts repeat")
            #expect(
                (matchingStore.state.pendingCommands[.options]) != nil,
                "a matching user options event keeps the pending shuffle command")
            #expect(
                (matchingStore.state.transportCommandResolutions.isEmpty) == true,
                "a matching user options event does not record confirmation")
            await matchingRemote.fail()
            _ = await waitUntil { matchingStore.state.pendingCommands[.options] == nil }
            #expect(
                (matchingStore.state.options.shuffle) == (true),
                "rejection after only a matching user options event restores on")
            #expect(
                (await matchingPrefs.shuffleWrites.isEmpty) == true,
                "rejection after only a matching user options event does not persist off")
            await matchingStore.shutdownForTermination()

            let persistGate = GatedLocalEngine()
            let persistPrefs = RecordingPreferences(shuffle: true)
            let persistStore = await restoredStore(
                local: persistGate,
                remote: ScriptedRemoteClient(.succeed),
                preferences: persistPrefs
            )
            seedLiveShuffle(persistStore, local: true, shuffle: true)
            persistStore.toggleShuffle()
            let persistPending = await waitUntil { persistStore.state.pendingCommands[.options] != nil }
            #expect((persistPending) == true, "local shuffle is pending before the admitted persist")
            persistGate.finish(with: .ok)
            _ = await waitUntil { persistStore.state.pendingCommands[.options] == nil }
            persistStore.toggleShuffle()
            let secondPending = await waitUntil { persistStore.state.pendingCommands[.options] != nil }
            #expect((secondPending) == true, "a later shuffle is pending before the first persist lands")
            #expect(
                (persistStore.state.options.shuffle) == (true),
                "a later shuffle presents on before the first persist lands"
            )
            _ = await waitUntil { await persistPrefs.shuffleWrites == [false] }
            #expect(
                (await persistPrefs.shuffleWrites) == ([false]),
                "accepted shuffle persists the admitted off, not the later on")
            persistGate.finish(with: .error)
            _ = await waitUntil { persistStore.state.pendingCommands[.options] == nil }
            #expect((persistStore.state.options.shuffle) == (false), "rejected later shuffle restores the admitted off")
            #expect((await persistPrefs.shuffleWrites) == ([false]), "rejected later shuffle does not persist on")
            await persistStore.shutdownForTermination()

            let preferenceOnlyPrefs = RecordingPreferences(shuffle: false)
            let preferenceOnly = await restoredStore(
                local: ScriptedLocalEngine(result: .ok),
                remote: ScriptedRemoteClient(.succeed),
                preferences: preferenceOnlyPrefs
            )
            _ = preferenceOnly.send(.session(.ready), source: .account)
            _ = preferenceOnly.send(.options(PlaybackOptions(shuffle: false)), source: .user)
            preferenceOnly.toggleShuffle()
            #expect((preferenceOnly.state.options.shuffle) == (true), "preference-only shuffle presents on")
            #expect(
                (preferenceOnly.state.pendingCommands.isEmpty) == true,
                "preference-only shuffle does not start a command")
            _ = await waitUntil { await preferenceOnlyPrefs.shuffleWrites == [true] }
            #expect((await preferenceOnlyPrefs.shuffleWrites) == ([true]), "preference-only shuffle persists on")
            await preferenceOnly.shutdownForTermination()
        }

        do {
            let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
            let priorPlayingTiming = PlaybackTiming(
                position: 40, duration: 200, anchoredAt: clockNow.addingTimeInterval(-10))
            let current = CurrentTrack(
                uri: "spotify:track:a",
                title: "A",
                artist: "Artist",
                duration: 200,
                metadataSource: .catalog
            )
            let ownerA = PlaybackOwner.remote(
                PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true)
            )
            let expectedB = PlaybackOwner.uncertain(
                PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker")
            )
            let remoteB = PlaybackOwner.remote(
                PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true)
            )
            let ownerC = PlaybackOwner.remote(
                PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
            )
            let speakerB = ConnectDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: false)
            let speakerD = ConnectDevice(id: "speaker-d", name: "Speaker D", type: "speaker", isActive: false)
            let thisMac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)

            @MainActor
            func seedRemoteOwner(_ player: PlaybackStore, owner: PlaybackOwner = ownerA) {
                _ = player.send(.session(.ready), source: .account)
                _ = player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                                PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                                PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                                PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker"),
                                PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"),
                            ],
                            localDeviceID: "mac",
                            revision: 1
                        )),
                    source: .engineDevices,
                    revision: 1
                )
                _ = player.send(.owner(owner), source: .command)
                _ = player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: current,
                            transport: .playing,
                            timing: priorPlayingTiming
                        )),
                    source: .user
                )
            }

            @MainActor
            func sendConnectionOwner(_ player: PlaybackStore, owner: PlaybackOwner, revision: UInt64) {
                _ = player.send(
                    .engineConnection(
                        EngineConnectionSnapshot(
                            session: .ready,
                            owner: owner,
                            localDeviceID: "mac"
                        )),
                    source: .engineConnection,
                    revision: revision
                )
            }

            let localRejected = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .error),
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            seedRemoteOwner(localRejected)
            localRejected.transferPlayback(to: speakerB)
            #expect((localRejected.state.owner) == (expectedB), "local transfer presents uncertain B before completion")
            #expect(
                (localRejected.state.pendingCommands[.transfer]) != nil, "local transfer is pending before completion")
            #expect(
                (localRejected.state.pendingCommands[.transfer]?.rollbackOwner) == (Optional(ownerA)),
                "local transfer captures owner A")
            _ = await waitUntil { localRejected.state.pendingCommands[.transfer] == nil }
            #expect((localRejected.state.owner) == (ownerA), "local transfer rejection restores A")
            #expect(
                (localRejected.transientCommandError) == ("Could not move playback to Speaker B"),
                "local transfer rejection uses the action notice")
            await localRejected.shutdownForTermination()

            let localAcceptedEngine = ScriptedLocalEngine(result: .ok)
            let localAccepted = playbackStore(
                commandEnvironment(
                    local: localAcceptedEngine,
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            seedRemoteOwner(localAccepted)
            localAccepted.transferPlayback(to: speakerB)
            _ = await waitUntil { localAccepted.state.pendingCommands[.transfer] == nil }
            #expect((localAccepted.state.owner) == (expectedB), "accepted local transfer keeps admitted B")
            #expect(
                (localAccepted.feedback.message)
                    == (TransientFeedbackMessage(id: 1, kind: .success, text: "Playing on Speaker B")),
                "accepted local transfer announces success through mutation feedback")
            #expect(
                (localAccepted.transientCommandError) == nil,
                "accepted local transfer does not use the command-error notice")
            let transferredDevice: String?
            switch localAcceptedEngine.operations.first {
            case let .transferToDevice(id):
                transferredDevice = id
            default:
                transferredDevice = nil
            }
            #expect((transferredDevice) == ("speaker-b"), "accepted local transfer reached the engine")
            #expect((localAcceptedEngine.operations.count) == (1), "accepted local transfer sent one engine operation")
            localAccepted.transferPlayback(to: speakerD)
            #expect(
                (localAccepted.state.owner)
                    == (PlaybackOwner.uncertain(PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker"))),
                "a later local transfer presents D before completion")
            _ = await waitUntil { localAccepted.state.pendingCommands[.transfer] == nil }
            #expect(
                (localAccepted.state.owner)
                    == (PlaybackOwner.uncertain(PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker"))),
                "an accepted later local transfer keeps D")
            await localAccepted.shutdownForTermination()

            let laggingGate = GatedLocalEngine()
            let laggingStore = playbackStore(
                commandEnvironment(local: laggingGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(laggingStore)
            laggingStore.transferPlayback(to: speakerB)
            let laggingPending = await waitUntil { laggingStore.state.pendingCommands[.transfer] != nil }
            #expect((laggingPending) == true, "remote transfer is pending before a lagging A snapshot")
            sendConnectionOwner(laggingStore, owner: ownerA, revision: 1)
            #expect((laggingStore.state.owner) == (expectedB), "a lagging A snapshot keeps optimistic B")
            #expect(
                (laggingStore.state.pendingCommands[.transfer]) != nil, "a lagging A snapshot keeps rollback ownership")
            laggingGate.finish(with: .error)
            _ = await waitUntil { laggingStore.state.pendingCommands[.transfer] == nil }
            #expect((laggingStore.state.owner) == (ownerA), "lagging A then rejection restores A")
            #expect(
                (laggingStore.transientCommandError) == ("Could not move playback to Speaker B"),
                "lagging A then rejection uses the action notice")
            await laggingStore.shutdownForTermination()

            let confirmGate = GatedLocalEngine()
            let confirmStore = playbackStore(
                commandEnvironment(local: confirmGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(confirmStore)
            confirmStore.transferPlayback(to: speakerB)
            _ = await waitUntil { confirmStore.state.pendingCommands[.transfer] != nil }
            let confirmedCommandID = confirmStore.state.pendingCommands[.transfer]?.id
            sendConnectionOwner(confirmStore, owner: remoteB, revision: 1)
            #expect(
                (confirmStore.state.pendingCommands[.transfer]) == nil, "an authoritative B snapshot confirms transfer")
            #expect(
                (confirmedCommandID.flatMap { confirmStore.state.transportCommandResolutions[$0] })
                    == (Optional(PlaybackTransportCommandResolution.confirmed)),
                "an authoritative B snapshot records transfer confirmation")
            confirmGate.finish(with: .error)
            _ = await waitUntil {
                confirmStore.state.transportCommandResolutions.isEmpty
                    && confirmStore.feedback.message?.text == "Playing on Speaker B"
            }
            #expect((confirmStore.state.owner) == (remoteB), "confirmed B then failure keeps B")
            #expect(
                (confirmStore.feedback.message)
                    == (TransientFeedbackMessage(id: 1, kind: .success, text: "Playing on Speaker B")),
                "confirmed B then failure announces success once")
            #expect(
                (confirmStore.transientCommandError) == nil,
                "confirmed transfer success does not use the command-error notice")
            #expect(
                (confirmStore.state.transportCommandResolutions.isEmpty) == true,
                "confirmed B then failure consumes the resolution entry")
            await confirmStore.shutdownForTermination()

            let supersedeGate = GatedLocalEngine()
            let supersedeStore = playbackStore(
                commandEnvironment(local: supersedeGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(supersedeStore)
            supersedeStore.transferPlayback(to: speakerB)
            _ = await waitUntil { supersedeStore.state.pendingCommands[.transfer] != nil }
            sendConnectionOwner(supersedeStore, owner: ownerC, revision: 1)
            #expect((supersedeStore.state.owner) == (ownerC), "an unrelated owner C supersedes B")
            #expect(
                (supersedeStore.state.pendingCommands[.transfer]) == nil,
                "an unrelated owner C clears the pending transfer"
            )
            supersedeGate.finish(with: .error)
            _ = await waitUntil { supersedeStore.state.transportCommandResolutions.isEmpty }
            #expect((supersedeStore.state.owner) == (ownerC), "unrelated C then late failure keeps C")
            #expect(
                (supersedeStore.transientCommandError) == nil, "unrelated C then late failure does not announce success"
            )
            #expect(
                (supersedeStore.feedback.message) == nil, "unrelated C then late failure presents no success feedback")
            await supersedeStore.shutdownForTermination()

            let noneGate = GatedLocalEngine()
            let noneStore = playbackStore(
                commandEnvironment(local: noneGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(noneStore)
            noneStore.transferPlayback(to: speakerB)
            _ = await waitUntil { noneStore.state.pendingCommands[.transfer] != nil }
            sendConnectionOwner(noneStore, owner: .none, revision: 1)
            #expect((noneStore.state.owner) == (.none), "an unrelated empty owner supersedes B")
            noneGate.finish(with: .ok)
            _ = await waitUntil { noneStore.state.transportCommandResolutions.isEmpty }
            #expect((noneStore.state.owner) == (.none), "accepted completion after empty supersession keeps none")
            #expect((noneStore.transientCommandError) == nil, "unrelated empty supersession does not announce success")
            #expect((noneStore.feedback.message) == nil, "unrelated empty supersession presents no success feedback")
            await noneStore.shutdownForTermination()

            let joining = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .ok),
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            _ = joining.send(.owner(ownerA), source: .command)
            let joiningBefore = joining.state
            joining.transferPlayback(to: speakerB)
            #expect((joining.state.owner) == (joiningBefore.owner), "route refusal leaves owner unchanged")
            #expect((joining.state.pendingCommands.isEmpty) == true, "route refusal does not start a pending transfer")
            await joining.shutdownForTermination()

            let duplicateGate = GatedLocalEngine()
            let duplicateStore = playbackStore(
                commandEnvironment(local: duplicateGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(duplicateStore)
            duplicateStore.transferPlayback(to: speakerB)
            let transferPending = await waitUntil { duplicateStore.state.pendingCommands[.transfer] != nil }
            #expect((transferPending) == true, "the first transfer is pending before a duplicate")
            let afterFirstTransfer = duplicateStore.state
            duplicateStore.transferPlayback(to: speakerD)
            #expect(
                (duplicateStore.state.owner) == (afterFirstTransfer.owner), "a duplicate transfer does not change owner"
            )
            #expect(
                (duplicateStore.state.pendingCommands[.transfer]?.id)
                    == (afterFirstTransfer.pendingCommands[.transfer]?.id),
                "a duplicate transfer keeps the original command")
            duplicateGate.finish(with: .error)
            _ = await waitUntil { duplicateStore.state.pendingCommands[.transfer] == nil }
            #expect((duplicateStore.state.owner) == (ownerA), "duplicate then rejection restores A")
            await duplicateStore.shutdownForTermination()

            let cancelGate = GatedLocalEngine()
            let cancelStore = playbackStore(
                commandEnvironment(local: cancelGate, remote: ScriptedRemoteClient(.succeed))
            )
            seedRemoteOwner(cancelStore)
            cancelStore.transferPlayback(to: speakerB)
            let cancelPending = await waitUntil { cancelStore.state.pendingCommands[.transfer] != nil }
            #expect((cancelPending) == true, "remote transfer is pending before cancellation")
            let transferReached = await waitUntil { cancelGate.enteredCount == 1 }
            #expect((transferReached) == true, "cancelled transfer still reaches the local fixture")
            if let commandID = cancelStore.state.pendingCommands[.transfer]?.id {
                cancelStore.effects.cancel(.command(commandID))
            }
            let cancelSettled = await waitUntil { cancelStore.state.pendingCommands[.transfer] == nil }
            #expect((cancelSettled) == true, "cancellation settles the pending transfer")
            #expect((cancelStore.state.owner) == (ownerA), "cancellation restores the captured owner")
            #expect((cancelStore.state.pendingCommands[.transfer]) == nil, "cancellation clears the pending transfer")
            #expect((cancelStore.feedback.message) == nil, "cancelled transfer presents no success feedback")
            cancelGate.finish(with: .error)
            await cancelStore.shutdownForTermination()

            let staleStore = playbackStore(
                commandEnvironment(
                    local: GatedLocalEngine(),
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            seedRemoteOwner(staleStore)
            staleStore.transferPlayback(to: speakerB)
            let stalePending = await waitUntil { staleStore.state.pendingCommands[.transfer] != nil }
            #expect((stalePending) == true, "transfer is pending before an engine-epoch bump")
            _ = staleStore.send(
                .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                revision: 1,
                engineEpoch: staleStore.engineGeneration + 1
            )
            #expect(
                (staleStore.state.pendingCommands[.transfer]) == nil, "an engine-epoch bump drops the pending transfer")
            #expect(
                (staleStore.state.owner != ownerA) == true, "an engine-epoch bump does not restore A through rollback")
            #expect(
                (staleStore.state.transportCommandResolutions.isEmpty) == true,
                "an engine-epoch bump clears transfer confirmation state")
            #expect((staleStore.state.owner) == (.none), "an engine-epoch bump applies the new connection owner")
            #expect((staleStore.feedback.message) == nil, "engine-stale transfer presents no success feedback")
            await staleStore.shutdownForTermination()

            let localMacStore = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .error),
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            seedRemoteOwner(localMacStore)
            localMacStore.transferPlayback(to: thisMac)
            #expect(
                (localMacStore.state.owner) == (ownerA),
                "transfer-to-this-Mac does not present uncertain local ownership")
            #expect((localMacStore.state.pendingCommands[.transfer]) != nil, "transfer-to-this-Mac is still admitted")
            #expect(
                (localMacStore.state.pendingCommands[.transfer]?.rollbackOwner) == nil,
                "transfer-to-this-Mac does not capture owner rollback")
            _ = await waitUntil { localMacStore.state.pendingCommands[.transfer] == nil }
            #expect((localMacStore.state.owner) == (ownerA), "a rejected transfer-to-this-Mac leaves owner A")
            #expect(
                (localMacStore.transientCommandError) == ("Could not move playback to this Mac"),
                "a rejected transfer-to-this-Mac uses the local action notice")
            await localMacStore.shutdownForTermination()

            let acceptedLocalMacEngine = ScriptedLocalEngine(result: .ok)
            let acceptedLocalMacStore = playbackStore(
                commandEnvironment(
                    local: acceptedLocalMacEngine,
                    remote: ScriptedRemoteClient(.succeed)
                )
            )
            seedRemoteOwner(acceptedLocalMacStore)
            acceptedLocalMacStore.transferPlayback(to: thisMac)
            _ = await waitUntil { acceptedLocalMacStore.state.pendingCommands[.transfer] == nil }
            #expect(
                (acceptedLocalMacStore.feedback.message)
                    == (TransientFeedbackMessage(id: 1, kind: .success, text: "Playing on This Mac")),
                "accepted transfer-to-this-Mac announces success through mutation feedback")
            #expect(
                (acceptedLocalMacStore.transientCommandError) == nil,
                "accepted transfer-to-this-Mac does not use the command-error notice")
            let acceptedLocalOperation: Bool
            switch acceptedLocalMacEngine.operations.first {
            case .transferToLocal:
                acceptedLocalOperation = true
            default:
                acceptedLocalOperation = false
            }
            #expect((acceptedLocalOperation) == true, "accepted transfer-to-this-Mac uses the local transfer operation")
            #expect(
                (acceptedLocalMacEngine.operations.count) == (1),
                "accepted transfer-to-this-Mac sends one local operation")
            await acceptedLocalMacStore.shutdownForTermination()
        }

        do {
            let engine = ScriptedLocalEngine(
                result: .ok,
                resumePosition: 93_606,
                resumeContextURI: "spotify:playlist:ctx",
                resumeTrackURI: "spotify:track:sticky"
            )
            let player = playbackStore(
                commandEnvironment(local: engine, remote: ScriptedRemoteClient(.succeed))
            )
            _ = player.send(.session(.ready), source: .account)
            _ = player.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)
                        ],
                        localDeviceID: "mac",
                        revision: 1
                    )),
                source: .engineDevices,
                revision: 1
            )
            _ = player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:presentation",
                            title: "Now",
                            artist: "Artist",
                            duration: 200,
                            metadataSource: .catalog
                        ),
                        transport: .paused,
                        timing: PlaybackTiming(position: 50, duration: 200, anchoredAt: Date(timeIntervalSince1970: 1))
                    )),
                source: .user
            )
            #expect((player.canTogglePlayback) == true, "paused local playback can resume")
            player.togglePlayback()
            _ = await waitUntil { player.state.pendingCommands[.transport] == nil }

            let plan: ResumeLoadPlan?
            switch engine.operations.first {
            case let .resume(captured):
                plan = captured
            default:
                plan = nil
            }
            #expect(
                (plan?.contextURI) == ("spotify:playlist:ctx"),
                "resume loads sticky context not the empty presentation context")
            #expect(
                (plan?.trackURI) == ("spotify:track:sticky"), "resume loads sticky track not the presentation track")
            #expect((plan?.positionMS) == (93_606), "resume uses the deactivation position")
            await player.shutdownForTermination()
        }
    }
}

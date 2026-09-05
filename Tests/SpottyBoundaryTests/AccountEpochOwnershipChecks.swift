import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private final class EpochEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storage[name, default: 0]
    }

    private func record(_ name: String) {
        lock.lock(); storage[name, default: 0] += 1; lock.unlock()
    }

    func authorizeStreaming(with _: String) -> Int32 { record("authorize"); return 0 }
    func initialize() -> PlaybackEngineResult { record("initialize"); return .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { record("execute"); return .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { record("shutdown"); return .ok }
    func cleanup() { record("cleanup") }
    func clearStreamingCredentials() { record("clearCredentials") }
    func disconnect() -> PlaybackEngineResult { record("disconnect"); return .ok }
    func forceReconnect() -> Int32 { record("reconnect"); return 0 }
}

private final class EpochAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var clearStorage = 0
    private var clearPark: CheckedContinuation<Void, Never>?
    var hasStoredGrant = true
    var parkClear = false

    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clearStorage
    }

    var isClearParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return clearPark != nil
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        KeymasterTokens(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiresAt: .distantFuture,
            username: "fixture-user"
        )
    }
    func hasGrant() async -> Bool { hasStoredGrant }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {
        if parkClear {
            await withCheckedContinuation { continuation in
                lock.withLock { clearPark = continuation }
            }
        }
        lock.withLock { clearStorage += 1 }
    }
    func completeClear() {
        lock.lock(); let continuation = clearPark; clearPark = nil; lock.unlock()
        continuation?.resume()
    }
    func revocations() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

private actor EpochPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private actor EpochRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

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

private struct EpochClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}
private actor EpochWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private func epochEnvironment(
    engine: EpochEngine,
    account: EpochAccount
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: EpochRemote(),
        local: engine,
        webQueue: EpochWebQueue(),
        account: account,
        audioOutput: BoundaryIdleAudio(),
        preferences: EpochPreferences(),
        lifecycle: BoundaryIdleLifecycle(),
        clock: EpochClock(),
        catalog: BoundaryIdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: BoundaryIdleAttributes()
    )
}

@Suite("Account Epoch Ownership")
struct AccountEpochOwnershipTests {
    @Test
    @MainActor
    func testAccountEpochOwnership() async {
        do {
            let engine = EpochEngine()
            let account = EpochAccount()
            let player = PlaybackStore(
                environment: epochEnvironment(engine: engine, account: account),
                feedback: TransientFeedbackPresenter(clock: EpochClock())
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
            #expect((engine.count("shutdown")) == (1), "logout still shuts the engine down once")
            #expect((account.clearCount) == (1), "logout still clears the grant once")
        }

        do {
            let engine = EpochEngine()
            let account = EpochAccount()
            account.parkClear = true
            let player = PlaybackStore(
                environment: epochEnvironment(engine: engine, account: account),
                feedback: TransientFeedbackPresenter(clock: EpochClock())
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
            #expect((engine.count("shutdown")) == (1), "engine shutdown still happens once")
        }

        do {
            let engine = EpochEngine()
            let account = EpochAccount()
            let player = PlaybackStore(
                environment: epochEnvironment(engine: engine, account: account),
                feedback: TransientFeedbackPresenter(clock: EpochClock())
            )
            await player.restore()
            let start = player.accountStore.epoch

            await player.shutdownForTermination()
            let afterStop = player.accountStore.epoch
            #expect((afterStop) == (start + 1), "termination advances AccountStore once")
            #expect((player.accountEpoch) == (afterStop), "PlaybackStore projects the termination epoch")
            #expect((player.state.accountEpoch) == (afterStop), "reducer adopts the termination epoch")
            #expect((player.catalogSession.accountEpoch) == (afterStop), "catalog observes the termination epoch")
            #expect((engine.count("shutdown")) == (1), "termination shuts the engine down once")
            #expect((account.clearCount) == (0), "termination does not clear the reusable grant")

            await player.shutdownForTermination()
            #expect(
                (player.accountStore.epoch) == (afterStop), "a second termination is idempotent and does not bump again"
            )
            #expect((engine.count("shutdown")) == (1), "a second termination does not shut down again")
        }

        do {
            let engine = EpochEngine()
            let account = EpochAccount()
            let player = PlaybackStore(
                environment: epochEnvironment(engine: engine, account: account),
                feedback: TransientFeedbackPresenter(clock: EpochClock())
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

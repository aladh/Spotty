@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyRuntimeContracts
import SpottyDomain
import SpottyEngineAdapter
import Testing

@MainActor
private final class QueueSnapshotFixture {
    let uri = "spotify:track:same"
    let engine = HarnessEngine()
    let gate = HarnessEngineGate()
    let remote = HarnessRemote(metadataTitle: "Unexpected metadata")
    let player: PlaybackStore
    private var snapshotEffect: PlaybackEffectSettlement?

    init() {
        // The callback belongs to the engine; retaining it here would keep every fixture's
        // engine alive after shutdown. The callback must not own its engine.
        engine.onQueueSnapshot = { [weak engine, gate] in
            gate.wait()
            return engine?.snapshot
        }
        player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
    }

    func seed(title: String?) {
        _ = player.send(.session(.ready), source: .account)
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                    localDeviceID: "mac", revision: 1)),
            source: .engineDevices, revision: 1)
        _ = player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: uri, title: title, artist: title == nil ? nil : "Artist", duration: 200,
                        metadataSource: title == nil ? .none : .catalog),
                    transport: .playing,
                    timing: PlaybackTiming(position: 5, duration: 200, anchoredAt: HarnessDates.fixed))),
            source: .user)
    }

    func replaceEngine() {
        _ = player.send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: .ready, owner: player.state.owner, localDeviceID: player.localDeviceID)),
            source: .engineConnection,
            revision: (player.state.sourceRevisions[.engineConnection] ?? 0) + 1,
            engineEpoch: player.engineGeneration + 1)
    }

    func start() throws {
        player.refreshQueueSnapshot()
        snapshotEffect = player.effects.settlement(of: .queueSnapshot)
        _ = try #require(snapshotEffect)
    }

    func requireGetter() async throws {
        try await requireEventually(description: "queue snapshot reaches the blocked engine") { self.gate.hasStarted }
    }

    func reply(generation: UInt64, revision: UInt64 = 1) async throws {
        let snapshotEffect = try #require(snapshotEffect)
        engine.snapshot = RustQueueState(
            revision: revision, sessionGeneration: generation,
            track: RustQueueState.Item(uri: uri, provider: "context", uid: "occ-now"),
            protocolNextTracks: [], protocolPrevTracks: [], queueRevision: "",
            disallowSetQueue: false, disallowRemovingFromNextTracks: false)
        gate.release()
        await snapshotEffect.wait()
        // Snapshot delivery can launch acceptance and metadata effects. They are registered
        // before it returns; an absent handle here means that child already finished or never
        // started. Negative assertions must follow any remaining child's settlement as well.
        for id in [PlaybackEffectID.connectQueueAccept, .trackMetadata] {
            await player.effects.settlement(of: id)?.wait()
        }
    }

    func close() async {
        let cancelled = player.effects.cancelAccountScoped()
        gate.close()
        await snapshotEffect?.wait()
        for effect in cancelled.values { await effect.wait() }
        await player.shutdownForTermination()
    }
}

@MainActor
private func withQueueSnapshot(
    title: String? = "Now", restored: Bool = false,
    _ body: @MainActor (QueueSnapshotFixture) async throws -> Void
) async throws {
    let fixture = QueueSnapshotFixture()
    do {
        if restored { await fixture.player.restore() }
        fixture.seed(title: title)
        try await body(fixture)
    } catch {
        await fixture.close()
        throw error
    }
    await fixture.close()
}

private enum QueueSnapshotFixtureFailure: Error { case prerequisite }

@Suite("Queue snapshot publication")
@MainActor
struct QueueSnapshotPublicationTests {
    @Test(arguments: [false, true])
    func staleSnapshotCannotResolveCurrentMetadata(hasMetadata: Bool) async throws {
        try await withQueueSnapshot(title: hasMetadata ? "Now" : nil) { fixture in
            fixture.player.recordPlayed(fixture.uri)
            try fixture.start()
            try await fixture.requireGetter()
            let staleGeneration = fixture.player.engineGeneration
            fixture.replaceEngine()
            try await fixture.reply(generation: staleGeneration)
            #expect(fixture.player.state.currentTrack?.uri == fixture.uri)
            #expect(fixture.player.state.currentTrack?.title == (hasMetadata ? "Now" : nil))
            #expect(fixture.player.state.currentTrack?.artist == (hasMetadata ? "Artist" : nil))
            #expect(fixture.player.history.first?.title == "Unknown track")
            #expect(fixture.remote.requestedURIs.isEmpty)
        }
    }

    @Test func staleSnapshotCannotAdvanceTheCallbackWatermark() async throws {
        try await withQueueSnapshot { fixture in
            let before = fixture.player.connectQueueCallback
            try fixture.start()
            try await fixture.requireGetter()
            let staleGeneration = fixture.player.engineGeneration
            fixture.replaceEngine()
            try await fixture.reply(generation: staleGeneration, revision: 9)
            #expect(fixture.player.connectQueueCallback.generation == before.generation)
            #expect(fixture.player.connectQueueCallback.revision == before.revision)
            #expect(
                fixture.player.acceptsConnectQueueCallback(generation: fixture.player.engineGeneration, revision: 1))
        }
    }

    @Test func newerPayloadGenerationReachesDesktopAndMutationState() async throws {
        try await withQueueSnapshot(restored: true) { fixture in
            let mirroredGeneration = fixture.player.engineGeneration
            let payloadGeneration = mirroredGeneration + 1
            try fixture.start()
            try await fixture.requireGetter()
            try await fixture.reply(generation: payloadGeneration, revision: 3)
            #expect(fixture.player.state.engineEpoch == payloadGeneration)
            #expect(fixture.player.engineGeneration == payloadGeneration)
            #expect(fixture.player.state.currentTrack?.title == "Now")
            #expect(fixture.player.queueMutation?.engineEpoch == payloadGeneration)
            #expect(fixture.player.queueMutation?.engineEpoch != mirroredGeneration)
        }
    }

    @Test func snapshotDecodedAfterEngineReplacementUsesItsPayloadGeneration() async throws {
        try await withQueueSnapshot(restored: true) { fixture in
            let before = fixture.player.engineGeneration
            try fixture.start()
            try await fixture.requireGetter()
            fixture.replaceEngine()
            let liveGeneration = fixture.player.engineGeneration
            _ = try #require(liveGeneration > before)
            try await fixture.reply(generation: liveGeneration, revision: 4)
            #expect(fixture.player.state.engineEpoch == liveGeneration)
            #expect(fixture.player.queueMutation?.engineEpoch == liveGeneration)
        }
    }

    @Test func stalePayloadCannotInstallMutationState() async throws {
        try await withQueueSnapshot { fixture in
            let before = fixture.player.engineGeneration
            try fixture.start()
            try await fixture.requireGetter()
            fixture.replaceEngine()
            try await fixture.reply(generation: before, revision: 5)
            #expect(fixture.player.state.currentTrack?.title == "Now")
            #expect(fixture.player.queueMutation == nil)
        }
    }

    @Test(arguments: [false, true])
    func thrownPrerequisiteSettlesAndReleasesTheFixture(waitForGetter: Bool) async throws {
        weak var retiredEngine: HarnessEngine?
        var captured: QueueSnapshotFixture?
        do {
            try await withQueueSnapshot { fixture in
                captured = fixture
                retiredEngine = fixture.engine
                try fixture.start()
                if waitForGetter { try await fixture.requireGetter() }
                throw QueueSnapshotFixtureFailure.prerequisite
            }
            Issue.record("the failed prerequisite must propagate")
        } catch QueueSnapshotFixtureFailure.prerequisite {
            #expect(captured?.engine.shutdownCount == 1)
            #expect(captured?.player.effects.settlements().isEmpty == true)
        }
        captured = nil
        try await requireEventually(description: "the terminated snapshot fixture releases its engine") {
            retiredEngine == nil
        }
    }

    @Test func successfulSnapshotReleasesTheFixture() async throws {
        weak var retiredEngine: HarnessEngine?
        try await withQueueSnapshot(restored: true) { fixture in
            retiredEngine = fixture.engine
            try fixture.start()
            try await fixture.requireGetter()
            try await fixture.reply(generation: fixture.player.engineGeneration)
        }
        try await requireEventually(description: "the completed snapshot fixture releases its engine") {
            retiredEngine == nil
        }
    }
}

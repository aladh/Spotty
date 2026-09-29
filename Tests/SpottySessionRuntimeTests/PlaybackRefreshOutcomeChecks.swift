@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
@testable import SpottySessionRuntime

@SessionRuntimeActor
private func replaceEngine(_ runtime: PlaybackSessionRuntime) {
    _ = runtime.send(
        .engineConnection(
            EngineConnectionSnapshot(
                session: .ready, owner: runtime.state.owner, localDeviceID: runtime.localDeviceID)),
        source: .engineConnection,
        revision: (runtime.state.sourceRevisions[.engineConnection] ?? 0) + 1,
        engineEpoch: runtime.engineGeneration + 1)
}

@SessionRuntimeActor
private func resetAccount(_ runtime: PlaybackSessionRuntime) {
    runtime.accountStore.advanceEpoch()
    _ = runtime.send(.reset(session: .signedOut), source: .account, accountEpoch: runtime.accountEpoch)
}

@SessionRuntimeActor
private final class MetadataResolutionFixture {
    let uri = "spotify:track:metadata"
    let remote = HarnessRemote(metadata: .park)
    let runtime: PlaybackSessionRuntime
    private var settlement: PlaybackEffectSettlement?

    init() {
        runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(remote: remote))
    }

    func start() throws -> PlaybackEffectSettlement {
        runtime.receive(
            RustPlaybackState(
                revision: 1, sessionGeneration: runtime.engineGeneration, isPlaying: true, isPaused: false,
                trackURI: uri, positionMS: 1_000, durationMS: 180_000, timestampMS: 0,
                shuffle: false, repeatTrack: false, repeatContext: false),
            revision: 1, receivedAt: HarnessDates.fixed)
        // Capture before yielding, including before a failing prerequisite or invalidation.
        settlement = runtime.effects.settlement(of: .trackMetadata)
        return try #require(settlement)
    }

    func requireRequest() async throws {
        try await requireEventually(description: "metadata request reaches the parked remote") {
            self.remote.parkedMetadataURIs.contains(self.uri)
        }
    }

    func close() async {
        runtime.effects.cancel(.trackMetadata)
        remote.failMetadata()
        await settlement?.wait()
        await runtime.shutdownForTermination()
    }
}

@SessionRuntimeActor
private func withMetadataResolution(
    _ body: @SessionRuntimeActor (MetadataResolutionFixture) async throws -> Void
) async throws {
    let fixture = MetadataResolutionFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.close()
        throw error
    }
    await fixture.close()
}

@Suite("Playback metadata outcomes")
@SessionRuntimeActor
struct PlaybackMetadataOutcomeTests {
    @Test func acceptedMetadataEnrichesTheCurrentTrackAndHistory() async throws {
        try await withMetadataResolution { fixture in
            let effect = try fixture.start()
            try await fixture.requireRequest()
            #expect(fixture.remote.requestedURIs == [fixture.uri])
            fixture.runtime.recordPlayed(fixture.uri)
            _ = try #require(fixture.remote.completeMetadata(title: "Resolved"))
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack?.title == "Resolved")
            #expect(fixture.runtime.state.currentTrack?.metadataSource == .connect)
            #expect(fixture.runtime.history.entries.first?.title == "Resolved")
        }
    }

    @Test func metadataFromAReplacedEngineCannotUpdateTheCurrentTrack() async throws {
        try await withMetadataResolution { fixture in
            let effect = try fixture.start()
            try await fixture.requireRequest()
            replaceEngine(fixture.runtime)
            _ = try #require(fixture.remote.completeMetadata(title: "Late engine"))
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack?.title == nil)
            #expect(fixture.runtime.history.entries.isEmpty)
        }
    }

    @Test func metadataFromAReplacedAccountCannotReviveOrEnrichRetiredState() async throws {
        try await withMetadataResolution { fixture in
            let effect = try fixture.start()
            try await fixture.requireRequest()
            fixture.runtime.recordPlayed(fixture.uri)
            // Isolate the epoch fence: reducer reset deliberately retains the history owner.
            resetAccount(fixture.runtime)
            _ = try #require(fixture.remote.completeMetadata(title: "Late account"))
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack == nil)
            #expect(fixture.runtime.history.entries.first?.title == "Unknown track")
        }
    }

    @Test func cancelledMetadataCannotEnrichTheCurrentTrackOrHistory() async throws {
        try await withMetadataResolution { fixture in
            let effect = try fixture.start()
            try await fixture.requireRequest()
            fixture.runtime.recordPlayed(fixture.uri)
            _ = try #require(fixture.runtime.effects.cancel(.trackMetadata))
            // Cancellation can release this cooperative remote before its reply. The assertion
            // concerns the subscriber; TrackMetadataLifetimeTests covers an uncooperative worker.
            fixture.remote.completeMetadata(title: "Cancelled")
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack?.title == nil)
            #expect(fixture.runtime.history.entries.first?.title == "Unknown track")
        }
    }

    @Test func rejectedMetadataCannotEnrichThePreviousTrackInHistory() async throws {
        try await withMetadataResolution { fixture in
            let effect = try fixture.start()
            try await fixture.requireRequest()
            fixture.runtime.recordPlayed(fixture.uri)
            #expect(
                fixture.runtime.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: "spotify:track:other", title: "Other", metadataSource: .catalog),
                            transport: .paused, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed))),
                    source: .user))
            _ = try #require(fixture.remote.completeMetadata(title: "From original"))
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack?.uri == "spotify:track:other")
            #expect(fixture.runtime.history.entries.first?.title == "Unknown track")
        }
    }

    @Test func thrownPrerequisiteSettlesTheMetadataFixture() async throws {
        var captured: MetadataResolutionFixture?
        do {
            try await withMetadataResolution { fixture in
                captured = fixture
                _ = try fixture.start()
                try await fixture.requireRequest()
                throw RefreshFixtureFailure.prerequisite
            }
            Issue.record("the failed prerequisite must propagate")
        } catch RefreshFixtureFailure.prerequisite {
            let fixture = try #require(captured)
            #expect(fixture.remote.parkedMetadataRequestCount == 0)
            #expect(fixture.runtime.effects.settlements().isEmpty)
            #expect(fixture.runtime.isTearingDown)
        }
    }
}

@SessionRuntimeActor
private final class PositionRefreshFixture {
    let engine = HarnessEngine()
    let gate = HarnessEngineGate()
    let runtime: PlaybackSessionRuntime
    private var settlement: PlaybackEffectSettlement?

    init() {
        engine.onPositionMilliseconds = { [gate] in
            gate.wait()
            return 42_000
        }
        runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(engine: engine))
        _ = runtime.send(.session(.ready), source: .account)
        _ = runtime.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                    localDeviceID: "mac", revision: 1)),
            source: .engineDevices, revision: 1)
        _ = runtime.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: "spotify:track:playing", title: "Now", artist: "Artist", duration: 200,
                        metadataSource: .catalog),
                    transport: .playing,
                    timing: PlaybackTiming(position: 5, duration: 200, anchoredAt: HarnessDates.fixed))),
            source: .user)
    }

    func start() throws -> PlaybackEffectSettlement {
        runtime.refreshPosition()
        settlement = runtime.effects.settlement(of: .positionRefresh)
        return try #require(settlement)
    }

    func requireGetter() async throws {
        try await requireEventually(description: "position getter reaches the blocked engine") { self.gate.hasStarted }
    }

    func close() async {
        runtime.effects.cancel(.positionRefresh)
        gate.close()
        await settlement?.wait()
        await runtime.shutdownForTermination()
    }
}

@SessionRuntimeActor
private func withPositionRefresh(
    _ body: @SessionRuntimeActor (PositionRefreshFixture) async throws -> Void
) async throws {
    let fixture = PositionRefreshFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.close()
        throw error
    }
    await fixture.close()
}

private enum RefreshFixtureFailure: Error { case prerequisite }

@Suite("Playback position refresh outcomes")
@SessionRuntimeActor
struct PlaybackPositionRefreshOutcomeTests {
    @Test func acceptedPositionReplacesTheAnchor() async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.timing.position == 42)
        }
    }

    @Test func positionFromAReplacedAccountCannotStampSignedOutTiming() async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            resetAccount(fixture.runtime)
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.timing.position == 0)
        }
    }

    @Test func positionFromAReplacedEngineCannotReplaceTheAnchor() async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            replaceEngine(fixture.runtime)
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.timing.position == 5)
        }
    }

    @Test func cancelledPositionCannotReplaceTheAnchor() async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            _ = try #require(fixture.runtime.effects.cancel(.positionRefresh))
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.timing.position == 5)
        }
    }

    @Test func positionCannotCrossATrackTransition() async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            #expect(
                fixture.runtime.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(uri: "spotify:track:new"),
                            transport: fixture.runtime.state.transport, timing: fixture.runtime.state.timing)),
                    source: .user))
            #expect(fixture.runtime.state.currentTrack?.uri == "spotify:track:new")
            #expect(fixture.runtime.state.timing.position == 5)
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.timing.position == 5, "the old track's sample cannot stamp the new track")
        }
    }

    @Test(arguments: [false, true])
    func positionCannotCrossAPlaybackOwnerChange(hasRemoteOwner: Bool) async throws {
        try await withPositionRefresh { fixture in
            let effect = try fixture.start()
            try await fixture.requireGetter()
            let owner: PlaybackOwner =
                hasRemoteOwner
                ? .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true)) : .none
            #expect(fixture.runtime.send(.owner(owner), source: .engineDevices))
            #expect(fixture.runtime.setTiming(position: 75))
            fixture.gate.release()
            await effect.wait()
            #expect(fixture.runtime.state.currentTrack?.uri == "spotify:track:playing")
            #expect(
                fixture.runtime.state.timing.position == 75, "a local sample cannot overwrite another owner's timing")
        }
    }

    @Test(arguments: [false, true])
    func thrownPrerequisiteSettlesThePositionFixture(waitForGetter: Bool) async throws {
        var captured: PositionRefreshFixture?
        do {
            try await withPositionRefresh { fixture in
                captured = fixture
                _ = try fixture.start()
                if waitForGetter { try await fixture.requireGetter() }
                throw RefreshFixtureFailure.prerequisite
            }
            Issue.record("the failed prerequisite must propagate")
        } catch RefreshFixtureFailure.prerequisite {
            let fixture = try #require(captured)
            #expect(fixture.runtime.effects.settlements().isEmpty)
            #expect(fixture.runtime.isTearingDown)
            #expect(fixture.engine.shutdownCount == 1)
        }
    }
}

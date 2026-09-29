@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Testing
@testable import SpottySessionRuntime

@Suite("Track metadata runtime lifetime")
@MainActor
struct TrackMetadataLifetimeTests {
    @Test func nowPlayingMetadataDoesNotWaitForBlockingEngineWork() async throws {
        let gate = HarnessEngineGate(result: .ok)
        defer { gate.release() }
        let engine = HarnessEngine()
        engine.onInitialize = { gate.enter() }
        let remote = HarnessRemote(metadataTitle: "Independent metadata")
        let environment = HarnessEnvironment.make(engine: engine, remote: remote)
        let runtime = SessionRuntimeActor.sync { PlaybackSessionRuntime(environment: environment) }
        defer { SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() } }
        let coordinator = SessionRuntimeActor.sync { runtime.coordinator }
        let busy = Task { await coordinator.initializeEngine() }
        defer { busy.cancel() }
        try await requireEventually { gate.hasStarted }

        receiveTrack(runtime)

        try await requireEventually(description: "Now Playing resolves metadata while the engine worker is occupied") {
            SessionRuntimeActor.sync { runtime.state.currentTrack?.title == "Independent metadata" }
        }
        #expect(remote.requestedURIs == ["spotify:track:metadata"])
        gate.release()
        #expect(await busy.value == .ok)
        await runtime.shutdownForTermination()
    }

    @Test func accountEffectDrainSettlesMetadataBeforeAnUncooperativeResponse() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>(cancellation: .ignored)
        defer { responses.close() }
        let remote = HarnessRemote()
        remote.onMetadata = { _ in try await responses.wait() }
        let environment = HarnessEnvironment.make(remote: remote)
        let runtime = SessionRuntimeActor.sync { PlaybackSessionRuntime(environment: environment) }
        defer { SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() } }
        receiveTrack(runtime)
        try await requireEventually { responses.waiterCount == 1 }

        let settlements = await runtime.effects.cancelAccountScoped()
        let report = await runtime.effects.drain(settlements)

        #expect(report.requested.contains(.trackMetadata))
        #expect(report.settled.contains(.trackMetadata))
        #expect(report.timedOut.isEmpty)
        #expect(responses.waiterCount == 1, "remote completion is independent of caller settlement")
        await runtime.shutdownForTermination()
        responses.finish(HarnessFixtures.metadata(uri: "spotify:track:metadata", title: "Retired"))
        #expect(SessionRuntimeActor.sync { runtime.state.currentTrack == nil })
    }

    private func receiveTrack(_ runtime: PlaybackSessionRuntime) {
        SessionRuntimeActor.sync {
            runtime.receive(
                RustPlaybackState(
                    revision: 1, sessionGeneration: 1, isPlaying: false, isPaused: true,
                    trackURI: "spotify:track:metadata", positionMS: 0, durationMS: 180_000,
                    timestampMS: 0, shuffle: false, repeatTrack: false, repeatContext: false,
                    isActiveDevice: true),
                revision: 1, receivedAt: HarnessDates.fixed)
        }
    }
}

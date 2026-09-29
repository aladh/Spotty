@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime

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
private let lifecycleTiming = PlaybackTiming(
    position: 40,
    duration: 200,
    anchoredAt: Date(timeIntervalSince1970: 1_799_999_990)
)
@Suite("Playback idle startup")
struct PlaybackIdleStartupTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func idleStartupPlayUsesLocalEngineWithoutSelection(resume: Bool, hasResumeContext: Bool) async throws {
        let local = HarnessEngine(resumeContextURI: hasResumeContext ? "spotify:playlist:retained" : nil)
        let remote = HarnessRemote()
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: local, remote: remote))
        do {
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
            try await requireEventually(description: "Idle playback reaches the local engine") {
                local.executeCount == 1
            }
            if resume {
                #expect(player.state.pendingCommands[.transport] != nil)
                _ = player.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing, trackURI: lifecycleTrackA.uri, timing: lifecycleTiming,
                            contextURI: "", isActiveDevice: true)),
                    source: .enginePlayback, revision: 2)
            }
            try await requireEventually(description: "Idle playback settles") {
                local.executeCount == 1 && player.state.pendingCommands[.transport] == nil
            }
            #expect(player.transientCommandError == nil)
            let expectedURI: String? = resume ? nil : "spotify:track:new"
            #expect(playedURI(local) == expectedURI)
            if resume {
                if case let .resumeObserved(target) = local.operations.first {
                    #expect(target.trackURI == lifecycleTrackA.uri)
                    #expect(target.positionMS == UInt32(lifecycleTiming.position * 1_000))
                } else {
                    Issue.record("Idle resume must validate the displayed snapshot")
                }
            }
            #expect(remote.sendCount == 0)
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
        #expect(player.defaultLocalPlaybackDevice == nil)
    }
}

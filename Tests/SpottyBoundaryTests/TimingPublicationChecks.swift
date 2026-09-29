import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport

private let publishedPlayingTiming = PlaybackTiming(
    position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))

@MainActor
private func withTimingPresentation(
    joining: Bool = false, local: Bool = false,
    _ body: (PlaybackStore, HarnessRemote, HarnessEngine, HarnessEngineGate) async throws -> Void
) async throws {
    let remote = HarnessRemote(send: .park)
    let engine = HarnessEngine()
    let gate = HarnessEngineGate()
    engine.onExecute = { _ in gate.enter() }
    let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
    do {
        try #require(player.send(.session(.ready), source: .account))
        if joining {
            try #require(player.send(.owner(.uncertain(nil)), source: .command))
        } else {
            try #require(
                player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !local),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        }
        try #require(
            player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture", title: "Now", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: .playing, timing: publishedPlayingTiming)), source: .user))
        try await body(player, remote, engine, gate)
    } catch {
        gate.close()
        await player.shutdownForTermination()
        throw error
    }
    gate.close()
    await player.shutdownForTermination()
}

@Suite("Timing publication")
@MainActor
struct TimingPublicationTests {
    @Test(arguments: [false, true], [false, true])
    func rejectedCommandPublishesRestoredTimelineAndNotice(pause: Bool, local: Bool) async throws {
        try await withTimingPresentation(local: local) { player, remote, engine, gate in
            #expect(player.canTogglePlayback)
            if pause { player.togglePlayback() } else { player.seek(to: 0.4) }
            #expect(
                player.timeline
                    == PlaybackTiming(
                        position: pause ? 50 : 80, duration: 200, anchoredAt: HarnessDates.fixed))
            #expect(player.isPlaying == !pause)
            try await requireEventually(description: "The desktop command reaches its held dependency") {
                local ? gate.enteredCount == 1 : remote.parkedSendCount == 1
            }
            if local { gate.finish(with: .error) } else { try #require(remote.completePark(success: false)) }
            // Read only desktop publications here. A runtime synchronization call would mask a
            // broken subscription by applying a fresh snapshot directly to the presenter.
            try await requireEventually(description: "The desktop publishes the rejection and restored timeline") {
                player.timeline == publishedPlayingTiming
                    && player.transientCommandError == (pause ? "Pause was rejected" : "Seek was rejected")
            }
            #expect(player.isPlaying)
            #expect(player.canTogglePlayback)
            #expect(remote.sendCount == (local ? 0 : 1))
            #expect(engine.operations.count == (local ? 1 : 0))
        }
    }

    @Test func joiningRefusalPublishesNoticeWithoutChangingTimeline() async throws {
        try await withTimingPresentation(joining: true) { player, remote, engine, _ in
            player.togglePlayback()
            player.seek(to: 0.5)
            #expect(player.timeline == publishedPlayingTiming)
            #expect(player.isPlaying)
            #expect(player.transientCommandError == "Spotty is still joining Spotify Connect.")
            #expect(remote.sendCount == 0)
            #expect(engine.operations.isEmpty)
        }
    }
}

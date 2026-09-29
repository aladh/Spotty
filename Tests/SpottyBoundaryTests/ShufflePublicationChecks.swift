import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport

@Suite("Shuffle publication")
@MainActor
struct ShufflePublicationTests {
    @Test(arguments: [false, true])
    func rejectionPublishesTheRestoredChoiceAndActionNotice(useLocal: Bool) async throws {
        let gate = HarnessEngineGate()
        defer { gate.close() }
        let engine = HarnessEngine()
        if useLocal { engine.onExecute = { _ in gate.enter() } }
        let remote = HarnessRemote(send: .park)
        let preferences = HarnessPreferences(shuffle: true)
        let player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: remote, preferences: preferences))
        do {
            try #require(player.send(.session(.ready), source: .account))
            try #require(
                player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: useLocal),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !useLocal),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
            try #require(player.send(.options(PlaybackOptions(shuffle: true)), source: .user))
            try #require(
                player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: "spotify:track:fixture", title: "Track", artist: "Artist", duration: 200,
                                metadataSource: .catalog),
                            transport: .playing, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed))), source: .user
                ))
            player.toggleShuffle()
            #expect(!player.isShuffleEnabled)
            try await requireEventually { useLocal ? gate.enteredCount == 1 : remote.parkedSendCount == 1 }
            if useLocal { gate.finish(with: .error) } else { try #require(remote.completePark(success: false)) }
            // Only desktop publications after the reply: compatibility settlement handles would
            // directly refresh the presenter and conceal a missing subscription update.
            try await requireEventually {
                player.isShuffleEnabled && player.transientCommandError == "Could not update shuffle"
            }
            #expect(preferences.shuffleWrites.isEmpty)
            #expect(useLocal ? engine.operations.count == 1 : remote.sendCount == 1)
        } catch {
            gate.close()
            await player.shutdownForTermination()
            throw error
        }
        gate.close()
        await player.shutdownForTermination()
    }
}

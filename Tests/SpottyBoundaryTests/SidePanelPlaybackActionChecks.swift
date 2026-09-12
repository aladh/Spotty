import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@MainActor
struct SidePanelPlaybackActionTests {
    @Test func retainedRowsAndMenusCannotCommandTheReplacementAccount() {
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
        player.withRuntime { seedReady($0) }
        let oldRowsAndMenu = SidePanelPlaybackActions(player: player)
        #expect(oldRowsAndMenu.canStartPlayback)

        // Unlike a delayed runtime publication, the desktop already displays the replacement.
        // Native menu tracking and old hosted row actions still retain their original account.
        player.withRuntime {
            $0.accountStore.advanceEpoch()
            _ = $0.send(.reset(session: .ready), source: .account)
            seedReady($0)
        }
        #expect(player.canStartPlayback)
        let replacement = player.state

        oldRowsAndMenu.play(uri: "spotify:track:old-history-or-queue-row")
        oldRowsAndMenu.togglePlayback()
        oldRowsAndMenu.transfer(to: ConnectDevice(id: "remote", name: "Speaker", type: "speaker", isActive: false))
        #expect(!oldRowsAndMenu.removeUpcomingQueue(selectedIDs: ["old-occurrence"]))

        #expect(!oldRowsAndMenu.canStartPlayback)
        #expect(!oldRowsAndMenu.canTogglePlayback)
        #expect(!oldRowsAndMenu.canRemoveUpcomingQueue(selectedIDs: ["old-occurrence"]))
        #expect(player.state == replacement)
        #expect(engine.operations.isEmpty)

        // A newly rendered row keeps the normal admission path available.
        let currentRowsAndMenu = SidePanelPlaybackActions(player: player)
        #expect(currentRowsAndMenu.canStartPlayback)
        currentRowsAndMenu.play(uri: "spotify:track:current-selection")
        #expect(player.state.pendingCommands[.transport] != nil)
    }

    @SessionRuntimeActor
    private func seedReady(_ runtime: PlaybackSessionRuntime) {
        _ = runtime.send(.session(.ready), source: .account)
        _ = runtime.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                    localDeviceID: "mac", revision: 1)),
            source: .engineDevices, revision: 1)
    }
}

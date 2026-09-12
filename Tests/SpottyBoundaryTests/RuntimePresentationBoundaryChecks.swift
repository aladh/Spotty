import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@MainActor
struct RuntimePresentationBoundaryTests {
    @Test func autonomousRuntimePublicationUpdatesUnpolledDesktop() async {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let runtime = player.runtime
        let update = Task { @SessionRuntimeActor in
            _ = runtime.send(.session(.ready), source: .account)
        }
        await update.value

        // Observe only the desktop's published values. A privileged helper that synchronously
        // flushes the runtime here would hide a broken autonomous subscription.
        await expectEventually { player.phase == .ready }
        #expect(player.isConnected)
    }

    @Test func staleDesktopAccountCannotDispatchIntoReplacementAccount() {
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
        player.withRuntime { seedReady($0) }
        let displayedEpoch = player.accountEpoch
        let runtime = player.runtime

        // Keep MainActor occupied while the independent runtime changes account. The rendered
        // local device ID is intentionally identical, so route matching alone cannot protect it.
        SessionRuntimeActor.sync {
            runtime.accountStore.advanceEpoch()
            _ = runtime.send(.reset(session: .ready), source: .account)
            seedReady(runtime)
        }
        #expect(player.accountEpoch == displayedEpoch)
        player.play(uri: "spotify:track:old-account-selection")

        #expect(engine.operations.isEmpty)
        #expect(player.accountEpoch == displayedEpoch + 1)
    }

    @Test func everyExternallyReadStateHasItsOwnCommittedRevision() {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let runtime = player.runtime
        let values = SessionRuntimeActor.sync {
            _ = runtime.send(.session(.connecting), source: .account)
            let first = runtime.presentation()
            _ = runtime.send(.session(.ready), source: .account)
            let second = runtime.presentation()
            return (first, second)
        }

        #expect(values.0.state.session == .connecting)
        #expect(values.1.state.session == .ready)
        #expect(values.1.revision > values.0.revision)
    }

    @Test func droppingIdleDesktopCancelsItsLocalSubscription() async {
        var player: PlaybackStore? = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        weak let weakPlayer = player
        let runtime = player!.runtime
        #expect(SessionRuntimeActor.sync { runtime.presentationSubscribers.count } == 1)

        player = nil

        #expect(weakPlayer == nil)
        await expectEventually {
            SessionRuntimeActor.sync { runtime.presentationSubscribers.isEmpty }
        }
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

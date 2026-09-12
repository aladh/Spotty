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

    @Test func autonomousRuntimePublishesPreparedTimingQueueAndDeviceValues() async {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let runtime = player.runtime
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            QueueEntry(uri: "spotify:track:repeat", provider: "context", occurrence: 0, uid: "first"),
            QueueEntry(uri: "spotify:track:repeat", provider: "context", occurrence: 1, uid: "second"),
        ]
        let value = await Task { @SessionRuntimeActor in
            _ = runtime.send(.session(.ready), source: .account)
            _ = runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false)],
                        localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1)
            _ = runtime.send(.timing(position: 42, duration: 180, anchoredAt: anchor), source: .user)
            _ = runtime.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: entries.map { PlaybackQueueItem($0) }, source: .connect,
                        completeness: .complete, revision: 1, receivedAt: anchor)),
                source: .engineQueue, revision: 1)
            return runtime.presentation()
        }.value

        // No facade helper may force a publication before checking the subscribed values.
        await expectEventually { player.queueNextEntries == entries && player.position == 42 }
        #expect(value.semantic.session == .ready)
        #expect(value.timeline == PlaybackTiming(position: 42, duration: 180, anchoredAt: anchor))
        #expect(value.queueEntries == entries)
        #expect(value.defaultLocalDevice?.id == "mac")
        #expect(value.commandRoute == .local)
        #expect(player.semantic == value.semantic)
        #expect(player.timeline == value.timeline)
        #expect(player.connectDevices == value.devices)
        #expect(player.defaultLocalPlaybackDevice == value.defaultLocalDevice)
        #expect(player.commandRoute == value.commandRoute)
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

    @Test(arguments: [false, true])
    func staleDesktopLifetimeCannotDispatch(changesRoute: Bool) {
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
        player.withRuntime { seedReady($0) }
        let displayedGeneration = player.engineGeneration
        let displayedRoute = player.commandRoute
        let runtime = player.runtime

        // Hold MainActor while the runtime advances. The command must validate the published
        // generation and route even though the account itself is still current.
        SessionRuntimeActor.sync {
            if changesRoute {
                _ = runtime.send(
                    .owner(.remote(PlaybackDevice(id: "phone", name: "Phone", type: "phone", isActive: true))),
                    source: .user)
            } else {
                _ = runtime.send(
                    .reset(session: .ready), source: .account, engineEpoch: runtime.engineGeneration + 1)
                seedReady(runtime)
            }
        }
        #expect(player.engineGeneration == displayedGeneration)
        #expect(player.commandRoute == displayedRoute)
        player.play(uri: "spotify:track:old-lifetime-selection")

        #expect(engine.operations.isEmpty)
        if changesRoute {
            #expect(player.commandRoute != displayedRoute)
        } else {
            #expect(player.engineGeneration == displayedGeneration + 1)
        }
    }

    @Test func everyExternallyReadPresentationHasItsOwnCommittedRevision() {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let runtime = player.runtime
        let values = SessionRuntimeActor.sync {
            _ = runtime.send(.session(.connecting), source: .account)
            let first = runtime.presentation()
            _ = runtime.send(.session(.ready), source: .account)
            let second = runtime.presentation()
            return (first, second)
        }

        #expect(values.0.semantic.session == .connecting)
        #expect(values.1.semantic.session == .ready)
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

import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyEngineAdapter

@MainActor
private func yieldPasses(_ count: Int = 200) async {
    for _ in 0..<count {
        await Task.yield()
    }
}

@MainActor
private func seedReady(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
}

@MainActor
private func seedRemoteOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [
                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                ],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
        source: .command
    )
}

@Suite("Transient Feedback")
struct TransientFeedbackTests {
    @Test
    @MainActor
    func testTransientFeedback() async {
        do {
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": "Configured Name"])) == ("Configured Name"),
                "configured bundle display name drives the window title")
            #expect(
                (AppDisplayName.resolve(info: [:])) == ("Spotty"), "missing bundle display name falls back to Spotty")
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": "  \n"])) == ("Spotty"),
                "blank bundle display name falls back to Spotty")
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": 42])) == ("Spotty"),
                "non-string bundle display name falls back to Spotty")
        }

        do {
            let clock = HarnessClock(sleep: .uncooperativelyParked)
            let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)

            feedback.success("Queue request sent")
            #expect((feedback.message?.kind) == (.success), "success kind")
            #expect((feedback.message?.text) == ("Queue request sent"), "success text")
            #expect((feedback.message == nil ? 0 : 1) == (1), "one message after success")

            feedback.informational("Queue is at the limit")
            #expect((feedback.message?.kind) == (.informational), "informational replaces success")
            #expect((feedback.message?.text) == ("Queue is at the limit"), "informational text")
            #expect((feedback.message == nil ? 0 : 1) == (1), "still one message after informational")

            feedback.failure("Could not add that track to the queue.")
            #expect((feedback.message?.kind) == (.failure), "failure replaces informational")
            #expect((feedback.message?.text) == ("Could not add that track to the queue."), "failure text")
            let visibleID = feedback.message?.id
            #expect((visibleID) != nil, "replacement has an identity")

            feedback.success("   ")
            #expect((feedback.message?.id) == (visibleID), "blank text does not replace")

            feedback.dismiss()
            #expect((feedback.message) == nil, "explicit dismiss clears the current message")
            clock.releaseAll()
            await yieldPasses()
            #expect((feedback.message) == nil, "released sleeps after dismiss stay empty")
        }

        do {
            let cooperative = CooperativeParkedClock()
            let cancelling = TransientFeedbackPresenter(clock: cooperative, duration: 4)
            cancelling.success("First")
            await expectEventually { cooperative.waiterCount == 1 }
            let firstID = cancelling.message?.id
            cancelling.failure("Second")
            await expectEventually { cooperative.waiterCount == 1 && cancelling.message?.text == "Second" }
            #expect((cancelling.message?.text) == ("Second"), "replacement is the only visible message")
            #expect((cancelling.message?.id != firstID) == true, "replacement is a new identity")
            #expect(
                (cancelling.message?.text) == ("Second"),
                "cancelling the previous dismissal leaves the replacement visible"
            )
            cancelling.dismiss()
            cooperative.releaseAll()

            let uncooperative = HarnessClock(sleep: .uncooperativelyParked)
            let stale = TransientFeedbackPresenter(clock: uncooperative, duration: 4)
            stale.success("Keep me")
            await expectEventually { uncooperative.waiterCount == 1 }
            stale.failure("Replacement")
            await expectEventually { uncooperative.waiterCount == 2 }
            #expect((stale.message?.text) == ("Replacement"), "replacement is showing before stale wake")
            let replacementID = stale.message?.id

            uncooperative.releaseNext()
            await expectEventually { uncooperative.waiterCount == 1 }
            #expect((stale.message?.text) == ("Replacement"), "a stale dismissal cannot remove the replacement")
            #expect((stale.message?.id) == (replacementID), "replacement identity is unchanged")

            uncooperative.releaseNext()
            await expectEventually { stale.message == nil }
            #expect((stale.message) == nil, "the current dismissal still expires the replacement")
        }

        do {
            let clock = HarnessClock(sleep: .uncooperativelyParked)
            let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let player = PlaybackStore(
                environment: HarnessEnvironment.make(clock: clock),
                feedback: feedback
            )
            #expect((player.feedback === feedback) == true, "the store keeps the composed presenter")

            player.addToQueue(uris: ["spotify:track:fixture"])
            #expect(
                (feedback.message?.text) == ("Connect Spotify before adding to the queue."),
                "disconnected add reports through the injected presenter")
            #expect((feedback.message?.kind) == (.failure), "disconnected add is a failure")
            #expect((player.transientCommandError) == nil, "disconnected add does not use playback notice")
            await player.endSession(clearGrant: false, finalPhase: .signedOut)
            #expect((feedback.message) == nil, "account teardown clears leftover mutation feedback")
            clock.releaseAll()
            await player.shutdownForTermination()
        }

        do {
            let clock = HarnessClock(sleep: .uncooperativelyParked)

            let localSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let localSuccess = PlaybackStore(
                environment: HarnessEnvironment.make(engine: HarnessEngine(executeResult: .ok), clock: clock),
                feedback: localSuccessFeedback
            )
            seedReady(localSuccess)
            localSuccess.addToQueue(uris: ["spotify:track:local-ok"])
            await expectEventually { localSuccessFeedback.message?.kind == .success }
            #expect((localSuccessFeedback.message?.text) == ("Queue request sent"), "local add success")
            #expect((localSuccess.transientCommandError) == nil, "local add success is not a playback notice")
            await localSuccess.shutdownForTermination()

            let localFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let localFailure = PlaybackStore(
                environment: HarnessEnvironment.make(engine: HarnessEngine(executeResult: .error), clock: clock),
                feedback: localFailureFeedback
            )
            seedReady(localFailure)
            localFailure.addToQueue(uris: ["spotify:track:local-fail"])
            await expectEventually { localFailureFeedback.message?.kind == .failure }
            #expect(
                (localFailureFeedback.message?.text) == ("Could not add that track to the queue."), "local add failure")
            #expect((localFailure.transientCommandError) == nil, "local add failure is not a playback notice")
            await localFailure.shutdownForTermination()

            let joiningFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let joining = PlaybackStore(
                environment: HarnessEnvironment.make(clock: clock),
                feedback: joiningFeedback
            )
            seedReady(joining)
            _ = joining.send(
                .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
                source: .command
            )
            joining.addToQueue(uris: ["spotify:track:joining"])
            #expect(
                (joiningFeedback.message?.text) == ("Spotty is still joining Spotify Connect."),
                "waiting for Connect identity is a mutation failure")
            #expect((joining.transientCommandError) == nil, "joining add is not a playback notice")
            await joining.shutdownForTermination()

            let remote = HarnessRemote()
            let remoteSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let remoteSuccess = PlaybackStore(
                environment: HarnessEnvironment.make(remote: remote, clock: clock),
                feedback: remoteSuccessFeedback
            )
            seedRemoteOwner(remoteSuccess)
            remoteSuccess.addToQueue(uris: ["spotify:track:remote-ok"])
            await expectEventually { remoteSuccessFeedback.message?.kind == .success }
            #expect((remoteSuccessFeedback.message?.text) == ("Queue request sent"), "remote add success")
            #expect((remote.sendCount) == (1), "remote add still sends add_to_queue")
            #expect((remoteSuccess.transientCommandError) == nil, "remote add success is not a playback notice")
            await remoteSuccess.shutdownForTermination()

            let remoteFail = HarnessRemote(send: .fail)
            let remoteFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let remoteFailure = PlaybackStore(
                environment: HarnessEnvironment.make(remote: remoteFail, clock: clock),
                feedback: remoteFailureFeedback
            )
            seedRemoteOwner(remoteFailure)
            remoteFailure.addToQueue(uris: ["spotify:track:remote-fail"])
            await expectEventually { remoteFailureFeedback.message?.kind == .failure }
            #expect(
                (remoteFailureFeedback.message?.text) == ("Could not add that track to the queue."),
                "remote add failure")
            await remoteFailure.shutdownForTermination()

            let parkedRemote = HarnessRemote(send: .park)
            let cancelledFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let cancelled = PlaybackStore(
                environment: HarnessEnvironment.make(remote: parkedRemote, clock: clock),
                feedback: cancelledFeedback
            )
            seedRemoteOwner(cancelled)
            cancelled.addToQueue(uris: ["spotify:track:cancel"])
            #expect(
                (await waitUntil { parkedRemote.sendCount == 1 }) == true,
                "cancelled add started the remote command")
            cancelled.effects.cancelAccountScoped()
            parkedRemote.completePark(success: false)
            await yieldPasses()
            #expect((cancelledFeedback.message) == nil, "cancelled add reports no mutation feedback")
            await cancelled.shutdownForTermination()

            let staleRemote = HarnessRemote(send: .park)
            let staleFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let staleAccount = PlaybackStore(
                environment: HarnessEnvironment.make(remote: staleRemote, clock: clock),
                feedback: staleFeedback
            )
            seedRemoteOwner(staleAccount)
            staleAccount.addToQueue(uris: ["spotify:track:stale"])
            #expect(
                (await waitUntil { staleRemote.sendCount == 1 }) == true,
                "stale-account add started the remote command")
            staleAccount.accountStore.advanceEpoch()
            staleRemote.completePark(success: true)
            await yieldPasses()
            #expect((staleFeedback.message) == nil, "stale-account add reports no mutation feedback")
            await staleAccount.shutdownForTermination()

            clock.releaseAll()
        }

    }

    @Test
    @MainActor
    func testSettledCommandErrorTimerCannotDismissNewerPlaybackNotice() async {
        let clock = HarnessClock(sleep: .uncooperativelyParked)
        let player = PlaybackStore(
            environment: HarnessEnvironment.make(clock: clock),
            feedback: TransientFeedbackPresenter(clock: clock)
        )
        seedReady(player)

        player.showTransientCommandError("An older command failed.")
        #expect(
            (await waitUntil { clock.waiterCount == 1 }) == true,
            "the command-error dismissal is parked before the replacement arrives"
        )
        let oldNoticeID = player.playbackNotice?.id
        let failedURI = "spotify:track:unavailable-timer"
        player.receive(
            RustPlaybackState(
                revision: 1,
                sessionGeneration: player.engineGeneration,
                isPlaying: false,
                isPaused: true,
                trackURI: failedURI,
                positionMS: 0,
                durationMS: 180_000,
                timestampMS: 0,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false,
                trackUnavailable: true,
                isActiveDevice: true
            ),
            revision: 1,
            receivedAt: clock.now()
        )
        let unavailableNoticeID = player.playbackNotice?.id
        #expect((unavailableNoticeID) != nil, "the accepted local failure replaces the old notice")
        #expect((unavailableNoticeID) != (oldNoticeID), "the replacement has a new notice identity")
        #expect(
            (player.playbackNotice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "the unavailable-track notice is visible before the old timer settles"
        )

        let commandError = player.effects.settlement(of: .commandError)
        #expect((commandError) != nil, "the old command-error timer remains observable")
        clock.releaseNext()
        await commandError?.wait()

        #expect(
            (player.playbackNotice?.id) == (unavailableNoticeID),
            "the settled old timer cannot dismiss the newer notice"
        )
        #expect(
            (player.playbackNotice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "the actionable unavailable-track notice survives the old timer"
        )

        await player.shutdownForTermination()
    }
}

import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@MainActor
private func withRepeatPresentation(
    local: Bool = false, flags: RepeatFlags = RepeatMode.off.flags,
    _ body: (PlaybackStore, HarnessRemote, HarnessEngineGate) async throws -> Void
) async throws {
    let engine = HarnessEngine()
    let gate = HarnessEngineGate()
    engine.onExecute = { _ in gate.enter() }
    let remote = HarnessRemote(send: .park)
    let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
    do {
        try #require(player.send(.session(.ready), source: .account))
        try #require(
            player.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !local),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            player.send(
                .options(
                    PlaybackOptions(
                        repeatMode: RepeatMode(context: flags.context, track: flags.track), repeatFlags: flags)),
                source: .user))
        try await body(player, remote, gate)
    } catch {
        gate.close()
        await player.shutdownForTermination()
        throw error
    }
    gate.close()
    await player.shutdownForTermination()
}

@Suite("Repeat publication")
@MainActor
struct RepeatPublicationTests {
    @Test(arguments: [false, true])
    func rejectionPublishesTheRestoredChoiceAndNotice(local: Bool) async throws {
        try await withRepeatPresentation(local: local) { player, remote, gate in
            player.cycleRepeat()
            #expect(player.repeatMode == .context)
            try await requireEventually { local ? gate.enteredCount == 1 : remote.parkedSendCount == 1 }
            if local { gate.finish(with: .error) } else { try #require(remote.completePark(success: false)) }
            // Publication reads only after the reply; compatibility effect handles can refresh
            // the presenter directly and conceal a missing subscription update.
            try await requireEventually {
                player.repeatMode == .off && player.transientCommandError == "Could not update repeat"
            }
            #expect(player.semantic.options.repeatFlags == RepeatMode.off.flags)
            #expect(remote.sendCount == (local ? 0 : 1))
        }
    }

    @Test(arguments: [false, true])
    func compensationPublishesTheRestoredRawFlagsAfterAnIntermediateObservation(bothTrue: Bool) async throws {
        let previous = bothTrue ? RepeatFlags(context: true, track: true) : RepeatMode.context.flags
        let intermediate = bothTrue ? RepeatMode.track.flags : RepeatMode.off.flags
        try await withRepeatPresentation(flags: previous) { player, remote, _ in
            let runtime = player.runtime
            player.cycleRepeat()
            #expect(player.repeatMode == (bothTrue ? .off : .track))
            try await requireEventually { remote.sendCount == 1 && remote.parkedSendCount == 1 }
            if !bothTrue {
                try #require(remote.completePark(success: true))
                try await requireEventually { remote.sendCount == 2 && remote.parkedSendCount == 1 }
            }
            // Inject into the runtime itself so only the subscription can publish this observation.
            let accepted = await runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused, trackURI: nil, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed),
                        shuffle: false,
                        repeatMode: RepeatMode(context: intermediate.context, track: intermediate.track),
                        repeatFlags: intermediate)), source: .enginePlayback, revision: 1)
            try #require(accepted)
            try await requireEventually { player.semantic.options.repeatFlags == intermediate }
            if bothTrue {
                try #require(remote.completePark(success: true))
                try await requireEventually { remote.sendCount == 2 && remote.parkedSendCount == 1 }
            }
            try #require(remote.completePark(success: false))
            try await requireEventually { remote.sendCount == 3 && remote.parkedSendCount == 1 }
            try #require(remote.completePark(success: true))
            try await requireEventually {
                player.semantic.options.repeatFlags == previous
                    && player.transientCommandError == "Could not update repeat"
            }
            #expect(player.repeatMode == (bothTrue ? .track : .context))
            #expect(remote.sendCount == 3)
        }
    }
}

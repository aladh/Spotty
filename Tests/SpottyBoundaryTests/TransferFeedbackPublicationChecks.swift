import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport

@Suite("Transfer feedback publication")
@MainActor
struct TransferFeedbackPublicationTests {
    @Test(arguments: [false, true])
    func rejectedTransferPublishesThePriorOwnerAndTargetSpecificNotice(thisMac: Bool) async throws {
        try await withTransferPresentation { player, engine, gate in
            let target = ConnectDevice(
                id: thisMac ? "mac" : "speaker-b", name: thisMac ? "Mac" : "Speaker B",
                type: thisMac ? "computer" : "speaker", isActive: false)
            player.transferPlayback(to: target)
            #expect(
                player.semantic.owner
                    == (thisMac
                        ? publishedTransferOwner
                        : .uncertain(
                            PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"))))
            try await requireEventually { gate.enteredCount == 1 }
            gate.finish(with: .error)
            // No compatibility state/effect reads after release: the ordinary subscription must
            // deliver both the owner rollback and action-specific error to the desktop.
            try await requireEventually {
                player.semantic.owner == publishedTransferOwner
                    && player.transientCommandError
                        == (thisMac ? "Could not move playback to this Mac" : "Could not move playback to Speaker B")
            }
            #expect(player.feedback.message == nil)
            #expect(engine.operations.count == 1)
        }
    }

    @Test func acceptedTransferToThisMacPublishesNamedSuccessWithoutInventingOwnership() async throws {
        try await withTransferPresentation { player, engine, gate in
            player.transferPlayback(to: ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false))
            #expect(player.semantic.owner == publishedTransferOwner)
            try await requireEventually { gate.enteredCount == 1 }
            gate.finish(with: .ok)
            try await requireEventually {
                player.feedback.message
                    == TransientFeedbackMessage(id: 1, kind: .success, text: "Playback request sent to This Mac")
            }
            #expect(player.semantic.owner == publishedTransferOwner)
            #expect(player.transientCommandError == nil)
            #expect(engine.operations.count == 1)
            if case .transferToLocal? = engine.operations.first {
            } else {
                Issue.record("Transfer to this Mac must use the explicit local engine operation")
            }
        }
    }

    @Test func explicitTransferKeepsItsDeliberateDeviceTarget() async throws {
        let local = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: local))
        do {
            try #require(player.send(.session(.ready), source: .account))
            try #require(
                player.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true),
                                PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker"),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
            try #require(
                player.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: "spotify:track:dispatch", title: "Dispatch", artist: "Artist", duration: 200,
                                metadataSource: .catalog),
                            transport: .paused,
                            timing: PlaybackTiming(position: 10, duration: 200, anchoredAt: HarnessDates.fixed))),
                    source: .user))
            let target = ConnectDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: false)
            player.transferPlayback(to: target)
            try await requireEventually(description: "The desktop publishes transfer success") {
                player.feedback.message?.text == "Playback request sent to Speaker A"
            }
            #expect(player.state.pendingCommands[.transfer] == nil)
            #expect(local.operations.count == 1)
            if case let .transferToDevice(id)? = local.operations.first {
                #expect(id == "speaker-a", "Explicit transfer preserves its deliberate device target")
            } else {
                Issue.record("Explicit transfer must use a device-targeted operation")
            }
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }
}

private let publishedTransferOwner = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true))

@MainActor
private func withTransferPresentation(
    _ body: (PlaybackStore, HarnessEngine, HarnessEngineGate) async throws -> Void
) async throws {
    let engine = HarnessEngine()
    let gate = HarnessEngineGate()
    defer { gate.close() }
    engine.onExecute = { _ in gate.enter() }
    let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
    do {
        try #require(player.send(.session(.ready), source: .account))
        try #require(
            player.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                            PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                            PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(player.send(.owner(publishedTransferOwner), source: .command))
        try #require(
            player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture", title: "Track", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: .playing, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed))), source: .user))
        try await body(player, engine, gate)
    } catch {
        gate.close()
        await player.shutdownForTermination()
        throw error
    }
    gate.close()
    await player.shutdownForTermination()
}

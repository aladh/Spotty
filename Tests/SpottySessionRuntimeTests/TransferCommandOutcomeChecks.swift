import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let transferOwnerA = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true))
private let transferTargetB = ConnectDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: false)
private let transferTargetD = ConnectDevice(id: "speaker-d", name: "Speaker D", type: "speaker", isActive: false)
private let transferMac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)
private let optimisticOwnerB = PlaybackOwner.uncertain(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"))
private let observedOwnerB = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true))
private let observedOwnerC = PlaybackOwner.remote(
    PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true))

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedTransfer() throws {
        try #require(runtime.send(.session(.ready), source: .account))
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                            PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                            PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                            PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker"),
                            PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(runtime.send(.owner(transferOwnerA), source: .command))
        try #require(
            runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:a", title: "A", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: .playing,
                        timing: PlaybackTiming(
                            position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10)))),
                source: .user))
    }

    func transfer(to target: ConnectDevice = transferTargetB) throws -> Command {
        try capture(.transfer) { runtime.transferPlayback(to: target) }
    }

    func observeOwner(_ owner: PlaybackOwner) throws {
        try #require(
            runtime.send(
                .engineConnection(EngineConnectionSnapshot(session: .ready, owner: owner, localDeviceID: "mac")),
                source: .engineConnection, revision: 1))
    }
}

@SessionRuntimeActor
private func withTransferCommand(_ body: (CommandRuntimeFixture) async throws -> Void) async throws {
    try await withCommandRuntime { fixture in
        try fixture.seedTransfer()
        try await body(fixture)
    }
}

@Suite("Transfer command outcomes")
@SessionRuntimeActor
struct TransferCommandOutcomeTests {
    @Test(arguments: [false, true])
    func remoteTargetUsesTheEngineAndItsReplyOwnsRollbackAndFeedback(success: Bool) async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            #expect(fixture.runtime.state.owner == optimisticOwnerB)
            #expect(fixture.runtime.state.pendingCommands[.transfer]?.rollbackOwner == transferOwnerA)
            try await fixture.requireDispatch(through: .local)
            guard case .transferToDevice("speaker-b")? = fixture.engine.operations.first else {
                Issue.record("A remote target still uses the engine's explicit transfer operation")
                return
            }
            #expect(fixture.engine.operations.count == 1)
            #expect(fixture.remote.sendCount == 0)
            try await fixture.reply(through: .local, success: success)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == (success ? optimisticOwnerB : transferOwnerA))
            #expect(
                fixture.runtime.semantic.notice?.message == (success ? nil : "Could not move playback to Speaker B"))
            #expect(
                fixture.runtime.feedback.message
                    == (success
                        ? RuntimeFeedbackMessage(
                            revision: 1, kind: .success, text: "Playback request sent to Speaker B") : nil))
        }
    }

    @Test func successiveAcceptedTransfersKeepTheirOwnTarget() async throws {
        try await withTransferCommand { fixture in
            let first = try fixture.transfer()
            try await fixture.reply(through: .local, success: true)
            await first.settlement.wait()
            let second = try fixture.transfer(to: transferTargetD)
            let expected = PlaybackOwner.uncertain(PlaybackDevice(id: "speaker-d", name: "Speaker D", type: "speaker"))
            #expect(fixture.runtime.state.owner == expected)
            try await fixture.requireDispatch(through: .local, number: 2)
            try #require(fixture.engine.operations.count == 2)
            try await fixture.reply(through: .local, number: 2, success: true)
            await second.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == expected)
            #expect(
                fixture.runtime.feedback.message
                    == RuntimeFeedbackMessage(revision: 2, kind: .success, text: "Playback request sent to Speaker D"))
            if case let .transferToDevice(id)? = fixture.engine.operations.last {
                #expect(id == "speaker-d")
            } else {
                Issue.record("The second transfer must retain its own target")
            }
        }
    }

    @Test func laggingOwnerPreservesOptimismAndRollback() async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            try await fixture.requireDispatch(through: .local)
            try fixture.observeOwner(transferOwnerA)
            #expect(fixture.runtime.state.owner == optimisticOwnerB)
            #expect(fixture.runtime.state.pendingCommands[.transfer]?.id == command.id)
            try await fixture.reply(through: .local, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == transferOwnerA)
            #expect(fixture.runtime.semantic.notice?.message == "Could not move playback to Speaker B")
        }
    }

    enum Observation: CaseIterable { case target, other, absent }

    @Test(arguments: Observation.allCases)
    func observedOwnershipWinsOverTheLateReply(_ observation: Observation) async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            try await fixture.requireDispatch(through: .local)
            let owner: PlaybackOwner =
                switch observation {
                case .target: observedOwnerB
                case .other: observedOwnerC
                case .absent: .none
                }
            try fixture.observeOwner(owner)
            #expect(fixture.runtime.state.owner == owner)
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            if observation == .target {
                #expect(fixture.runtime.state.transportCommandResolutions[command.id] == .confirmed)
            }
            try await fixture.reply(through: .local, success: observation == .absent)
            await command.settlement.wait()
            #expect(fixture.runtime.state.owner == owner)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(
                fixture.runtime.feedback.message
                    == (observation == .target
                        ? RuntimeFeedbackMessage(
                            revision: 1, kind: .success, text: "Playback request sent to Speaker B") : nil))
        }
    }

    @Test func disconnectedSessionRefusesWithoutChangingOwnership() async throws {
        try await withCommandRuntime { fixture in
            try #require(fixture.runtime.send(.owner(transferOwnerA), source: .command))
            fixture.runtime.transferPlayback(to: transferTargetB)
            #expect(fixture.runtime.state.owner == transferOwnerA)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.engine.operations.isEmpty)
            #expect(fixture.remote.sendCount == 0)
        }
    }

    @Test func duplicateTransferCannotReplaceThePendingTarget() async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            fixture.runtime.transferPlayback(to: transferTargetD)
            #expect(fixture.runtime.state.owner == optimisticOwnerB)
            #expect(fixture.runtime.state.pendingCommands[.transfer]?.id == command.id)
            try await fixture.requireDispatch(through: .local)
            #expect(fixture.engine.operations.count == 1)
            try await fixture.reply(through: .local, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == transferOwnerA)
        }
    }

    @Test func cancellationRestoresOwnershipBeforeTheEnteredEngineCallReturns() async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            try await fixture.requireDispatch(through: .local)
            let cancelled = fixture.runtime.effects.cancel(.command(command.id))
            try #require(cancelled != nil)
            #expect(fixture.runtime.state.owner == transferOwnerA)
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            try await fixture.reply(through: .local, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.feedback.message == nil)
        }
    }

    @Test(arguments: [false, true])
    func engineReplacementCannotRestoreTheOldOwnerOrAnnounceSuccess(afterDispatch: Bool) async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer()
            if afterDispatch { try await fixture.requireDispatch(through: .local) }
            try #require(
                fixture.runtime.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection, revision: 1, engineEpoch: fixture.runtime.engineGeneration + 1))
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == .none)
            if afterDispatch { try await fixture.reply(through: .local, success: false) }
            await command.settlement.wait()
            #expect(fixture.runtime.state.owner == .none)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            #expect(fixture.runtime.feedback.message == nil)
            #expect(fixture.engine.operations.count == (afterDispatch ? 1 : 0))
        }
    }

    @Test(arguments: [false, true])
    func thisMacDoesNotInventLocalOwnershipBeforeTheEngineObservesIt(success: Bool) async throws {
        try await withTransferCommand { fixture in
            let command = try fixture.transfer(to: transferMac)
            #expect(fixture.runtime.state.owner == transferOwnerA)
            #expect(fixture.runtime.state.pendingCommands[.transfer]?.rollbackOwner == nil)
            try await fixture.requireDispatch(through: .local)
            guard case .transferToLocal? = fixture.engine.operations.first else {
                Issue.record("Selecting this Mac uses the engine's local transfer operation")
                return
            }
            try await fixture.reply(through: .local, success: success)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transfer] == nil)
            #expect(fixture.runtime.state.owner == transferOwnerA)
            #expect(fixture.runtime.semantic.notice?.message == (success ? nil : "Could not move playback to this Mac"))
            #expect(
                fixture.runtime.feedback.message
                    == (success
                        ? RuntimeFeedbackMessage(revision: 1, kind: .success, text: "Playback request sent to This Mac")
                        : nil))
            #expect(fixture.engine.operations.count == 1)
            #expect(fixture.remote.sendCount == 0)
        }
    }
}

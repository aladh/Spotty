import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let bothRepeatFlags = RepeatFlags(context: true, track: true)
private let repeatStarts = [RepeatMode.off.flags, RepeatMode.context.flags, RepeatMode.track.flags, bothRepeatFlags]

private struct RepeatSend: Equatable {
    let endpoint: SpotifyConnectCommand.Kind
    let enabled: Bool?

    init(_ mutation: RepeatFlagMutation) {
        endpoint = mutation.flag == .context ? .repeatContext : .repeatTrack
        enabled = mutation.enabled
    }

    init(_ command: SpotifyConnectCommand) {
        endpoint = command.endpoint
        if case let .boolean(value) = command.value { enabled = value } else { enabled = nil }
    }
}

/// Literal expectations for the four starting pairs; never ask the production planner for its answer.
private func expectedRepeatPlan(from flags: RepeatFlags) -> RepeatTransitionPlan {
    if flags == RepeatMode.off.flags {
        return .init(mutations: [.init(flag: .context, enabled: true)], compensation: [])
    }
    if flags == RepeatMode.context.flags {
        return .init(
            mutations: [.init(flag: .context, enabled: false), .init(flag: .track, enabled: true)],
            compensation: [.init(flag: .context, enabled: true)])
    }
    if flags == RepeatMode.track.flags {
        return .init(mutations: [.init(flag: .track, enabled: false)], compensation: [])
    }
    return .init(
        mutations: [.init(flag: .context, enabled: false), .init(flag: .track, enabled: false)],
        compensation: [.init(flag: .context, enabled: true)])
}

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedRepeat(local: Bool = false, flags: RepeatFlags = RepeatMode.off.flags) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !local),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            runtime.send(
                .options(
                    PlaybackOptions(
                        repeatMode: RepeatMode(context: flags.context, track: flags.track), repeatFlags: flags)),
                source: .user))
    }

    func cycle() throws -> Command { try capture(.options) { runtime.cycleRepeat() } }

    func observeRepeat(_ flags: RepeatFlags, revision: UInt64 = 1) throws {
        try #require(
            runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused, trackURI: nil, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed),
                        shuffle: false, repeatMode: RepeatMode(context: flags.context, track: flags.track),
                        repeatFlags: flags)),
                source: .enginePlayback, revision: revision))
    }
}

@Suite("Repeat command outcomes")
@SessionRuntimeActor
struct RepeatCommandOutcomeTests {
    @Test(arguments: repeatStarts, [false, true])
    func localReplyKeepsOrRestoresCapturedOptions(flags: RepeatFlags, success: Bool) async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(local: true, flags: flags)
            let next = fixture.runtime.repeatMode.next
            let command = try fixture.cycle()
            #expect(fixture.runtime.state.options.repeatFlags == next.flags)
            try await fixture.requireDispatch(through: .local)
            let operation = try #require(fixture.engine.operations.first)
            guard case let .repeatOptions(plan) = operation else {
                Issue.record("Repeat must submit a local repeat plan")
                return
            }
            #expect(plan == expectedRepeatPlan(from: flags))
            try await fixture.reply(through: .local, success: success)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.repeatFlags == (success ? next.flags : flags))
            #expect(fixture.runtime.semantic.notice?.message == (success ? nil : "Could not update repeat"))
            #expect(fixture.engine.operations.count == 1)
            #expect(fixture.remote.sendCount == 0)
        }
    }

    @Test(arguments: repeatStarts)
    func remoteCycleSendsOnlyChangedFlags(flags: RepeatFlags) async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(flags: flags)
            let next = fixture.runtime.repeatMode.next
            #expect(fixture.runtime.state.options.repeatFlags == flags)
            let command = try fixture.cycle()
            let expected = expectedRepeatPlan(from: flags).mutations
            for number in 1...expected.count {
                try await fixture.reply(through: .remote, number: number, success: true)
            }
            await command.settlement.wait()
            #expect(fixture.remote.commands.map(RepeatSend.init) == expected.map(RepeatSend.init))
            #expect(fixture.runtime.state.options.repeatFlags == next.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.engine.operations.isEmpty)
        }
    }

    @Test func firstRemoteFailureDoesNotCompensate() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.remote.commands.map(RepeatSend.init) == [RepeatSend(.init(flag: .context, enabled: true))])
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice?.message == "Could not update repeat")
        }
    }

    @Test(arguments: [false, true])
    func laterRemoteFailureCompensatesWithoutClaimingSuccess(compensationFails: Bool) async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(flags: RepeatMode.context.flags)
            let command = try fixture.cycle()
            try await fixture.reply(through: .remote, number: 1, success: true)
            try await fixture.reply(through: .remote, number: 2, success: false)
            try await fixture.reply(through: .remote, number: 3, success: !compensationFails)
            await command.settlement.wait()
            let plan = expectedRepeatPlan(from: RepeatMode.context.flags)
            #expect(
                fixture.remote.commands.map(RepeatSend.init)
                    == (plan.mutations + plan.compensation).map(RepeatSend.init))
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice?.message == "Could not update repeat")
        }
    }

    @Test(arguments: [false, true])
    func targetObservationWinsOverALateFirstFailure(local: Bool) async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(local: local)
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: local ? .local : .remote)
            try fixture.observeRepeat(RepeatMode.context.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.transportCommandResolutions[command.id] == .confirmed)
            try await fixture.reply(through: local ? .local : .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
        }
    }

    @Test func targetObservationWinsWhileFailedSecondStepStillFinishesCompensation() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(flags: RepeatMode.context.flags)
            let command = try fixture.cycle()
            try await fixture.reply(through: .remote, number: 1, success: true)
            try await fixture.requireDispatch(through: .remote, number: 2)
            try fixture.observeRepeat(RepeatMode.track.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.transportCommandResolutions[command.id] == .confirmed)
            try await fixture.reply(through: .remote, number: 2, success: false)
            try await fixture.reply(through: .remote, number: 3, success: true)
            await command.settlement.wait()
            let plan = expectedRepeatPlan(from: RepeatMode.context.flags)
            #expect(
                fixture.remote.commands.map(RepeatSend.init)
                    == (plan.mutations + plan.compensation).map(RepeatSend.init))
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.track.flags)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func intermediateObservationCannotReplaceCapturedRollbackFlags(bothTrue: Bool) async throws {
        try await withCommandRuntime { fixture in
            let previous = bothTrue ? bothRepeatFlags : RepeatMode.context.flags
            let intermediate = bothTrue ? RepeatMode.track.flags : RepeatMode.off.flags
            try fixture.seedRepeat(flags: previous)
            let command = try fixture.cycle()
            // Preserve both schedules: raw both-true changes while the first send is held;
            // canonical context-to-track changes after the first send succeeded.
            if !bothTrue { try await fixture.reply(through: .remote, number: 1, success: true) }
            try await fixture.requireDispatch(through: .remote, number: bothTrue ? 1 : 2)
            try fixture.observeRepeat(intermediate)
            #expect(fixture.runtime.state.options.repeatFlags == intermediate)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            if bothTrue { try await fixture.reply(through: .remote, number: 1, success: true) }
            try await fixture.reply(through: .remote, number: 2, success: false)
            try await fixture.reply(through: .remote, number: 3, success: true)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == previous)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice?.message == "Could not update repeat")
            let plan = expectedRepeatPlan(from: previous)
            #expect(
                fixture.remote.commands.map(RepeatSend.init)
                    == (plan.mutations + plan.compensation).map(RepeatSend.init))
            if bothTrue {
                let next = try fixture.cycle()
                try await fixture.reply(through: .remote, number: 4, success: true)
                try await fixture.reply(through: .remote, number: 5, success: true)
                await next.settlement.wait()
                #expect(
                    fixture.remote.commands.suffix(2).map(RepeatSend.init) == [
                        RepeatSend(.init(flag: .context, enabled: false)),
                        RepeatSend(.init(flag: .track, enabled: false)),
                    ])
                #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            }
        }
    }

    @Test func unrelatedAuthoritativeFlagsSurviveLateFailure() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: .remote)
            try fixture.observeRepeat(RepeatMode.track.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.track.flags)
            #expect(fixture.runtime.semantic.notice == nil)
        }
    }

    @Test func laggingPriorFlagsKeepOptimismAndRollbackOwnership() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: .remote)
            try fixture.observeRepeat(RepeatMode.off.flags)
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            #expect(fixture.runtime.semantic.notice?.message == "Could not update repeat")
        }
    }

    @Test func matchingUserOptionsAdoptShuffleWithoutConfirmingRepeat() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: .remote)
            try #require(
                fixture.runtime.send(
                    .options(
                        PlaybackOptions(shuffle: true, repeatMode: .context, repeatFlags: RepeatMode.context.flags)),
                    source: .user))
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.semantic.notice?.message == "Could not update repeat")
        }
    }

    @Test func cancellationRestoresCapturedFlagsWithoutANotice() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: .remote)
            try #require(fixture.runtime.effects.cancel(.command(command.id)) != nil)
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remoteResponses.waiterCount == 0)
        }
    }

    @Test func cancellationDuringTheSecondStepStillAttemptsCompensation() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat(flags: RepeatMode.context.flags)
            let command = try fixture.cycle()
            try await fixture.reply(through: .remote, number: 1, success: true)
            try await fixture.requireDispatch(through: .remote, number: 2)
            try #require(fixture.runtime.effects.cancel(.command(command.id)) != nil)
            await command.settlement.wait()
            let plan = expectedRepeatPlan(from: RepeatMode.context.flags)
            #expect(
                fixture.remote.commands.map(RepeatSend.init)
                    == (plan.mutations + plan.compensation).map(RepeatSend.init))
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remoteResponses.waiterCount == 0)
        }
    }

    @Test func terminationJoinsTheEnteredRepeatWorker() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            try await fixture.requireDispatch(through: .remote)
            await fixture.runtime.shutdownForTermination()
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remoteResponses.waiterCount == 0)
            #expect(fixture.remote.sendCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func engineReplacementPreservesOptimismAndRejectsRetiredFailure(afterDispatch: Bool) async throws {
        try await withCommandRuntime(remoteCancellation: .ignored) { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            if afterDispatch { try await fixture.requireDispatch(through: .remote) }
            try #require(
                fixture.runtime.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection, revision: 1, engineEpoch: fixture.runtime.engineGeneration + 1))
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            if afterDispatch { try await fixture.reply(through: .remote, success: false) }
            await command.settlement.wait()
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.context.flags)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remote.sendCount == (afterDispatch ? 1 : 0))
        }
    }

    @Test(arguments: [false, true])
    func accountReplacementRejectsRetiredFailure(afterDispatch: Bool) async throws {
        try await withCommandRuntime(remoteCancellation: .ignored) { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            if afterDispatch { try await fixture.requireDispatch(through: .remote) }
            fixture.runtime.accountStore.advanceEpoch()
            try #require(
                fixture.runtime.send(
                    .reset(session: .signedOut), source: .account, accountEpoch: fixture.runtime.accountEpoch))
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            if afterDispatch { try await fixture.reply(through: .remote, success: false) }
            await command.settlement.wait()
            #expect(fixture.runtime.state.session == .signedOut)
            #expect(fixture.runtime.state.options.repeatFlags == RepeatMode.off.flags)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remote.sendCount == (afterDispatch ? 1 : 0))
        }
    }

    @Test func joiningRefusalCannotChangeRepeatOrDispatch() async throws {
        try await withCommandRuntime { fixture in
            try #require(fixture.runtime.send(.session(.ready), source: .account))
            try #require(
                fixture.runtime.send(
                    .owner(.uncertain(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
                    source: .command))
            let before = fixture.runtime.state.options
            fixture.runtime.cycleRepeat()
            #expect(fixture.runtime.state.options == before)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.runtime.semantic.notice?.message == "Spotty is still joining Spotify Connect.")
            #expect(fixture.remote.sendCount == 0)
            #expect(fixture.engine.operations.isEmpty)
        }
    }

    @Test func duplicateRepeatKeepsTheOriginalAdmission() async throws {
        try await withCommandRuntime { fixture in
            try fixture.seedRepeat()
            let command = try fixture.cycle()
            let admitted = fixture.runtime.state.options
            fixture.runtime.cycleRepeat()
            #expect(fixture.runtime.state.options == admitted)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            try await fixture.requireDispatch(through: .remote)
            #expect(fixture.remote.sendCount == 1)
            try #require(fixture.runtime.effects.cancel(.command(command.id)) != nil)
            await command.settlement.wait()
        }
    }
}

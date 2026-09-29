import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let priorPlayingTiming = PlaybackTiming(
    position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))
private let priorPausedTiming = PlaybackTiming(
    position: 50, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))
private let anchoredToggleTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: HarnessDates.fixed)
private let optimisticSeekTiming = PlaybackTiming(position: 80, duration: 200, anchoredAt: HarnessDates.fixed)
private enum TimingRoute { case local, remote, joining }
private enum TimingFixtureExit: Error { case prerequisiteFailed }

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedTiming(playing: Bool, route: TimingRoute) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        if route == .joining {
            try #require(runtime.send(.owner(.uncertain(nil)), source: .command))
        } else {
            try #require(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: route == .local),
                                PlaybackDevice(
                                    id: "speaker", name: "Speaker", type: "speaker", isActive: route == .remote),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        }
        try #require(
            runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture", title: "Now", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: playing ? .playing : .paused,
                        timing: playing ? priorPlayingTiming : priorPausedTiming)), source: .user))
    }

    func toggle() throws -> Command { try capture(.transport) { runtime.togglePlayback() } }
    func seek() throws -> Command { try capture(.seek) { runtime.seek(to: 0.4) } }
}

@SessionRuntimeActor
private func withTimingCommand(
    route: TimingRoute = .remote, playing: Bool = true,
    _ body: (CommandRuntimeFixture) async throws -> Void
) async throws {
    try await withCommandRuntime { fixture in
        try fixture.seedTiming(playing: playing, route: route)
        try await body(fixture)
    }
}

@Suite("Timing command outcomes")
@SessionRuntimeActor
struct TimingCommandOutcomeTests {
    @Test(arguments: [false, true])
    func rejectedToggleRestoresTheExactTiming(playing: Bool) async throws {
        try await withTimingCommand(playing: playing) { fixture in
            #expect(fixture.runtime.canTogglePlayback)
            let command = try fixture.toggle()
            #expect(fixture.runtime.state.transport == (playing ? .paused : .playing))
            #expect(fixture.runtime.state.timing == anchoredToggleTiming)
            try await fixture.requireDispatch(through: .remote)
            #expect(fixture.remote.endpoints == [playing ? .pause : .resume])
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            #expect(fixture.runtime.state.transport == (playing ? .playing : .paused))
            #expect(fixture.runtime.state.timing == (playing ? priorPlayingTiming : priorPausedTiming))
            #expect(
                fixture.runtime.semantic.notice?.message == (playing ? "Pause was rejected" : "Resume was rejected"))
        }
    }

    @Test func acceptedPauseKeepsFrozenTiming() async throws {
        try await withTimingCommand { fixture in
            let command = try fixture.toggle()
            try await fixture.requireDispatch(through: .remote)
            try await fixture.reply(through: .remote, success: true)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            #expect(fixture.runtime.state.transport == .paused)
            #expect(fixture.runtime.state.timing == anchoredToggleTiming)
            #expect(fixture.runtime.semantic.notice == nil)
        }
    }

    @Test(arguments: [false, true])
    func rejectedSeekRestoresTheExactTiming(useLocal: Bool) async throws {
        try await withTimingCommand(route: useLocal ? .local : .remote) { fixture in
            let command = try fixture.seek()
            #expect(fixture.runtime.state.timing == optimisticSeekTiming)
            #expect(fixture.runtime.state.transport == .playing)
            try await fixture.requireDispatch(through: useLocal ? .local : .remote)
            if useLocal {
                #expect(fixture.engine.operations.count == 1)
                guard case .seek(80_000)? = fixture.engine.operations.first else {
                    Issue.record("A local seek must carry the admitted milliseconds")
                    return
                }
                #expect(fixture.remote.sendCount == 0)
            } else {
                #expect(fixture.remote.endpoints == [.seek])
            }
            try await fixture.reply(through: useLocal ? .local : .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            #expect(fixture.runtime.state.timing == priorPlayingTiming)
            #expect(fixture.runtime.state.transport == .playing)
            #expect(fixture.runtime.semantic.notice?.message == "Seek was rejected")
        }
    }

    @Test func acceptedSeekKeepsPositionWithoutChangingTransport() async throws {
        try await withTimingCommand(playing: false) { fixture in
            let command = try fixture.seek()
            try await fixture.requireDispatch(through: .remote)
            try await fixture.reply(through: .remote, success: true)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            #expect(fixture.runtime.state.timing == optimisticSeekTiming)
            #expect(fixture.runtime.state.transport == .paused)
        }
    }

    @Test func joiningRouteCannotAdmitTimingCommands() async throws {
        try await withTimingCommand(route: .joining) { fixture in
            let before = fixture.runtime.state
            fixture.runtime.togglePlayback()
            fixture.runtime.seek(to: 0.5)
            #expect(fixture.runtime.state.transport == before.transport)
            #expect(fixture.runtime.state.timing == before.timing)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.runtime.semantic.notice?.message == "Spotty is still joining Spotify Connect.")
            #expect(fixture.remote.sendCount == 0)
            #expect(fixture.engine.operations.isEmpty)
        }
    }

    @Test func pendingSeekRefusesAToggle() async throws {
        try await withTimingCommand { fixture in
            let command = try fixture.seek()
            let afterSeek = fixture.runtime.state
            fixture.runtime.togglePlayback()
            #expect(fixture.runtime.state.transport == afterSeek.transport)
            #expect(fixture.runtime.state.timing == afterSeek.timing)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            try await fixture.requireDispatch(through: .remote)
            #expect(fixture.remote.endpoints == [.seek])
            let cancelled = fixture.runtime.effects.cancel(.command(command.id))
            try #require(cancelled != nil)
            await command.settlement.wait()
        }
    }

    @Test func cancelledPauseRestoresTimingWithoutNotice() async throws {
        try await withTimingCommand { fixture in
            let command = try fixture.toggle()
            try await fixture.requireDispatch(through: .remote)
            let cancelled = fixture.runtime.effects.cancel(.command(command.id))
            try #require(cancelled != nil)
            await command.settlement.wait()
            #expect(fixture.runtime.state.transport == .playing)
            #expect(fixture.runtime.state.timing == priorPlayingTiming)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
        }
    }

    @Test(arguments: [false, true])
    func engineReplacementKeepsOptimisticSeekTiming(afterDispatch: Bool) async throws {
        try await withTimingCommand { fixture in
            let command = try fixture.seek()
            if afterDispatch { try await fixture.requireDispatch(through: .remote) }
            let timing = fixture.runtime.state.timing
            try #require(
                fixture.runtime.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection, revision: 1, engineEpoch: fixture.runtime.engineGeneration + 1))
            #expect(fixture.runtime.state.pendingCommands[.seek] == nil)
            #expect(fixture.runtime.state.timing == timing)
            // Replacing the generation revokes admission, not a request already sent.
            // Release that exact response before joining and check that its rejection is stale.
            if afterDispatch {
                try await fixture.reply(through: .remote, success: false)
                await command.settlement.wait()
                #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            } else {
                await command.settlement.wait()
            }
            #expect(fixture.runtime.state.timing == timing)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remote.sendCount == (afterDispatch ? 1 : 0))
        }
    }

    @Test func trackSwitchSuppressesTheLateSeekFailure() async throws {
        try await withTimingCommand { fixture in
            let command = try fixture.seek()
            try await fixture.requireDispatch(through: .remote)
            let nextTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: HarnessDates.fixed)
            try #require(
                fixture.runtime.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(transport: .playing, trackURI: "spotify:track:other", timing: nextTiming)
                    ),
                    source: .enginePlayback, revision: 1))
            #expect(fixture.runtime.state.currentTrack?.uri == "spotify:track:other")
            #expect(fixture.runtime.state.timing == nextTiming)
            #expect(fixture.runtime.state.pendingCommands[.seek] == nil)
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[command.kind] == nil)
            #expect(fixture.runtime.state.currentTrack?.uri == "spotify:track:other")
            #expect(fixture.runtime.state.timing == nextTiming)
            #expect(fixture.runtime.semantic.notice == nil)
        }
    }

    @Test(arguments: [TimingRoute.local, .remote])
    private func thrownPrerequisiteJoinsTheEnteredCommand(_ route: TimingRoute) async throws {
        var captured: CommandRuntimeFixture?
        do {
            try await withTimingCommand(route: route) { fixture in
                captured = fixture
                _ = try fixture.seek()
                try await fixture.requireDispatch(through: route == .local ? .local : .remote)
                throw TimingFixtureExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch TimingFixtureExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(fixture.remoteResponses.waiterCount == 0)
    }
}

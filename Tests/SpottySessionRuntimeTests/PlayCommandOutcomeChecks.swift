import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let priorPlayTrack = CurrentTrack(
    uri: "spotify:track:a", title: "A", artist: "Artist", duration: 200, metadataSource: .catalog)
private let requestedPlayTrack = HarnessFixtures.track(uri: "spotify:track:b", title: "B", duration: 180)
private let priorPlayTiming = PlaybackTiming(
    position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))
private let requestedPlayTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: HarnessDates.fixed)
private enum PlayFixtureExit: Error { case prerequisiteFailed }

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedPlay(useLocal: Bool, joining: Bool) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        if joining {
            try #require(runtime.send(.owner(.uncertain(nil)), source: .command))
        } else {
            try #require(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: useLocal),
                                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !useLocal),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        }
        try #require(
            runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: priorPlayTrack, transport: .playing, timing: priorPlayTiming)), source: .user))
    }

    func play(rawURI: Bool = false) throws -> Command {
        try capture(.transport) {
            if rawURI { runtime.play(uri: requestedPlayTrack.uri) } else { runtime.play(track: requestedPlayTrack) }
        }
    }

    func observe(uri: String?, timing: PlaybackTiming, revision: UInt64 = 1) throws {
        try #require(
            runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: uri == nil ? .stopped : .playing, trackURI: uri, timing: timing)),
                source: .enginePlayback, revision: revision))
    }
}

@SessionRuntimeActor
private func withPlayCommand(
    useLocal: Bool = false, joining: Bool = false,
    _ body: (CommandRuntimeFixture) async throws -> Void
) async throws {
    try await withCommandRuntime { fixture in
        try fixture.seedPlay(useLocal: useLocal, joining: joining)
        try await body(fixture)
    }
}

@Suite("Play command outcomes")
@SessionRuntimeActor
struct PlayCommandOutcomeTests {
    @Test(arguments: [false, true], [false, true])
    func knownTrackReturnPreservesRollbackAndWaitsForObservedHistory(useLocal: Bool, accepted: Bool) async throws {
        try await withPlayCommand(useLocal: useLocal) { fixture in
            let running = try fixture.play()
            #expect(fixture.runtime.state.currentTrack?.uri == requestedPlayTrack.uri)
            #expect(fixture.runtime.state.transport == .playing)
            #expect(fixture.runtime.state.timing == requestedPlayTiming)
            #expect(fixture.runtime.history.entries.isEmpty)
            try await fixture.requireDispatch(through: useLocal ? .local : .remote)
            try await fixture.reply(through: useLocal ? .local : .remote, success: accepted)
            await running.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.history.entries.isEmpty)
            if accepted {
                #expect(fixture.runtime.state.currentTrack?.uri == requestedPlayTrack.uri)
                #expect(fixture.runtime.state.transport == .playing)
                let observed = PlaybackTiming(position: 1, duration: 180, anchoredAt: HarnessDates.fixed)
                try fixture.observe(uri: requestedPlayTrack.uri, timing: observed)
                #expect(fixture.runtime.history.entries.map(\.uri) == [requestedPlayTrack.uri])
            } else {
                #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
                #expect(fixture.runtime.state.timing == priorPlayTiming)
                #expect(fixture.runtime.semantic.notice?.message == "Could not play that Spotify URI")
            }
        }
    }

    @Test(arguments: [false, true])
    func laggingTrackPreservesOptimismUntilRejection(useLocal: Bool) async throws {
        try await withPlayCommand(useLocal: useLocal) { fixture in
            let running = try fixture.play()
            try await fixture.requireDispatch(through: useLocal ? .local : .remote)
            try fixture.observe(
                uri: priorPlayTrack.uri,
                timing: PlaybackTiming(position: 44, duration: 200, anchoredAt: HarnessDates.fixed))
            #expect(fixture.runtime.state.currentTrack?.uri == requestedPlayTrack.uri)
            #expect(fixture.runtime.state.timing == requestedPlayTiming)
            #expect(fixture.runtime.state.pendingCommands[.transport]?.id == running.id)
            try await fixture.reply(through: useLocal ? .local : .remote, success: false)
            await running.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
            #expect(fixture.runtime.state.timing == priorPlayTiming)
            #expect(fixture.runtime.history.entries.isEmpty)
        }
    }

    enum ObservedTrack: CaseIterable { case target, other, absent }

    @Test(arguments: ObservedTrack.allCases)
    func rejectedReturnCannotUndoAnObservedTrack(_ observed: ObservedTrack) async throws {
        try await withPlayCommand { fixture in
            let running = try fixture.play()
            try await fixture.requireDispatch(through: .remote)
            let uri: String?
            let timing: PlaybackTiming
            switch observed {
            case .target:
                uri = requestedPlayTrack.uri
                timing = PlaybackTiming(position: 1, duration: 180, anchoredAt: HarnessDates.fixed)
            case .other:
                uri = "spotify:track:c"
                timing = PlaybackTiming(position: 8, duration: 240, anchoredAt: HarnessDates.fixed)
            case .absent:
                uri = nil
                timing = PlaybackTiming(anchoredAt: HarnessDates.fixed)
            }
            try fixture.observe(uri: uri, timing: timing)
            #expect(fixture.runtime.state.currentTrack?.uri == uri)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            if observed == .target {
                #expect(fixture.runtime.state.transportCommandResolutions[running.id] == .confirmed)
            }
            try await fixture.reply(through: .remote, success: false)
            await running.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.state.currentTrack?.uri == uri)
            #expect(fixture.runtime.state.timing == timing)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            #expect(
                fixture.runtime.history.entries.contains { $0.uri == requestedPlayTrack.uri } == (observed == .target))
        }
    }

    @Test func joiningRefusesBeforeTrackAdmissionOrHistory() async throws {
        try await withPlayCommand(joining: true) { fixture in
            fixture.runtime.play(track: requestedPlayTrack)
            #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
            #expect(fixture.runtime.state.timing == priorPlayTiming)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.runtime.history.entries.isEmpty)
            #expect(fixture.remote.sendCount == 0)
            #expect(fixture.engine.operations.isEmpty)
        }
    }

    @Test func duplicatePlayKeepsTheOriginalAdmission() async throws {
        try await withPlayCommand { fixture in
            let running = try fixture.play()
            let afterFirst = fixture.runtime.state.currentTrack
            fixture.runtime.play(track: requestedPlayTrack)
            #expect(fixture.runtime.state.currentTrack == afterFirst)
            #expect(fixture.runtime.state.pendingCommands[.transport]?.id == running.id)
            try await fixture.requireDispatch(through: .remote)
            #expect(fixture.remote.sendCount == 1)
            try await fixture.reply(through: .remote, success: true)
            await running.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
        }
    }

    @Test func cancelledPlayRestoresTrackWithoutHistory() async throws {
        try await withPlayCommand { fixture in
            let running = try fixture.play()
            try await fixture.requireDispatch(through: .remote)
            let cancelled = fixture.runtime.effects.cancel(.command(running.id))
            try #require(cancelled != nil)
            await running.settlement.wait()
            #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
            #expect(fixture.runtime.state.timing == priorPlayTiming)
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.history.entries.isEmpty)
            #expect(fixture.runtime.semantic.notice == nil)
        }
    }

    @Test(arguments: [false, true])
    func engineReplacementKeepsTheOptimisticTrack(afterDispatch: Bool) async throws {
        try await withPlayCommand { fixture in
            let running = try fixture.play()
            if afterDispatch { try await fixture.requireDispatch(through: .remote) }
            try #require(
                fixture.runtime.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection, revision: 1, engineEpoch: fixture.runtime.engineGeneration + 1))
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.state.currentTrack?.uri == requestedPlayTrack.uri)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            if afterDispatch {
                try await fixture.reply(through: .remote, success: false)
                await running.settlement.wait()
                #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            } else {
                await running.settlement.wait()
            }
            #expect(fixture.runtime.state.currentTrack?.uri == requestedPlayTrack.uri)
            #expect(fixture.runtime.history.entries.isEmpty)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.remote.sendCount == (afterDispatch ? 1 : 0))
        }
    }

    @Test func rawURIRequiresAMatchingObservationBeforeHistory() async throws {
        try await withPlayCommand(useLocal: true) { fixture in
            let running = try fixture.play(rawURI: true)
            #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
            try await fixture.requireDispatch(through: .local)
            try await fixture.reply(through: .local, success: true)
            await running.settlement.wait()
            #expect(fixture.runtime.state.pendingCommands[.transport] == nil)
            #expect(fixture.runtime.state.currentTrack == priorPlayTrack)
            #expect(fixture.runtime.history.entries.isEmpty)
            let timing = PlaybackTiming(position: 1, duration: 180, anchoredAt: HarnessDates.fixed)
            try fixture.observe(uri: priorPlayTrack.uri, timing: timing)
            #expect(fixture.runtime.state.intents.last?.outcome == .sent)
            try fixture.observe(uri: requestedPlayTrack.uri, timing: timing, revision: 2)
            #expect(fixture.runtime.history.entries.map(\.uri) == [requestedPlayTrack.uri])
        }
    }

    @Test(arguments: [false, true])
    func thrownPrerequisiteJoinsEnteredPlay(useLocal: Bool) async throws {
        var captured: CommandRuntimeFixture?
        do {
            try await withPlayCommand(useLocal: useLocal) { fixture in
                captured = fixture
                _ = try fixture.play()
                try await fixture.requireDispatch(through: useLocal ? .local : .remote)
                throw PlayFixtureExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch PlayFixtureExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(fixture.remoteResponses.waiterCount == 0)
    }
}

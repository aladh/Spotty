import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private enum CommandScopeExit: Error { case prerequisiteFailed }

@Suite("Command runtime fixture lifetime")
@SessionRuntimeActor
struct CommandRuntimeFixtureTests {
    @Test(arguments: [false, true])
    func throwingAfterTheSecondRequestJoinsBothCapturedCommands(useLocal: Bool) async throws {
        var captured: CommandRuntimeFixture?
        do {
            try await withCommandRuntime { fixture in
                captured = fixture
                try seed(fixture, useLocal: useLocal)
                let first = try fixture.capture(.options) { fixture.runtime.toggleShuffle() }
                try await fixture.reply(through: useLocal ? .local : .remote, success: true)
                await first.settlement.wait()
                let second = try fixture.capture(.options) { fixture.runtime.toggleShuffle() }
                #expect(first.id != second.id)
                try await fixture.requireDispatch(through: useLocal ? .local : .remote, number: 2)
                try #require(
                    useLocal ? fixture.engine.operations.count == 2 : fixture.remoteResponses.requestCount == 2)
                throw CommandScopeExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch CommandScopeExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(fixture.runtime.state.pendingCommands.isEmpty)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(fixture.remoteResponses.waiterCount == 0)
        #expect(fixture.preferences.shuffleWrites == [true])
    }

    @Test func throwingClosesARemoteResponseThatIgnoresCancellation() async throws {
        var captured: CommandRuntimeFixture?
        do {
            try await withCommandRuntime(remoteCancellation: .ignored) { fixture in
                captured = fixture
                try seed(fixture, useLocal: false)
                _ = try fixture.capture(.options) { fixture.runtime.toggleShuffle() }
                try await fixture.requireDispatch(through: .remote)
                throw CommandScopeExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch CommandScopeExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(fixture.remoteResponses.waiterCount == 0)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(fixture.preferences.shuffleWrites.isEmpty)
    }

    @Test func throwingReleasesAnEnteredPreferenceWriteBeforeJoiningShutdown() async throws {
        let writes = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { writes.close() }
        let preferences = HarnessPreferences(beforeShuffleWrite: { _ in try? await writes.wait() })
        var captured: CommandRuntimeFixture?
        do {
            try await withCommandRuntime(preferences: preferences, closing: { writes.close() }) { fixture in
                captured = fixture
                try seed(fixture, useLocal: false)
                let command = try fixture.capture(.options) { fixture.runtime.toggleShuffle() }
                try await fixture.reply(through: .remote, success: true)
                await command.settlement.wait()
                try await requireEventually { writes.waiterCount == 1 }
                throw CommandScopeExit.prerequisiteFailed
            }
            Issue.record("The injected prerequisite must throw")
        } catch CommandScopeExit.prerequisiteFailed {}
        let fixture = try #require(captured)
        #expect(fixture.runtime.effects.settlements().isEmpty)
        #expect(writes.waiterCount == 0)
        #expect(fixture.engine.shutdownCount == 1)
        #expect(preferences.shuffleWrites == [true], "An accepted write survives caller cancellation")
    }

    private func seed(_ fixture: CommandRuntimeFixture, useLocal: Bool) throws {
        try #require(fixture.runtime.send(.session(.ready), source: .account))
        try #require(
            fixture.runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: useLocal),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !useLocal),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            fixture.runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:fixture", title: "Track", artist: "Artist", duration: 200,
                            metadataSource: .catalog),
                        transport: .playing, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed))), source: .user))
    }
}

import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private enum ShuffleRoute { case local, remote, joining, idle }
private let shuffleTrack = CurrentTrack(
    uri: "spotify:track:a", title: "A", artist: "Artist", duration: 200, metadataSource: .catalog)
private let shuffleTiming = PlaybackTiming(
    position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))

@SessionRuntimeActor
private extension CommandRuntimeFixture {
    func seedShuffle(route: ShuffleRoute) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        switch route {
        case .local, .remote:
            try #require(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: route == .local),
                                PlaybackDevice(
                                    id: "speaker", name: "Speaker", type: "speaker", isActive: route == .remote),
                            ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        case .joining:
            // An active remote without local Connect identity must take the joining route.
            // Uncertain(nil) would instead exercise the preference-only branch of shuffle.
            try #require(
                runtime.send(
                    .owner(.uncertain(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
                    source: .command))
        case .idle: break
        }
        if route != .idle {
            try #require(
                runtime.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: shuffleTrack, transport: .playing, timing: shuffleTiming)), source: .user))
        }
        runtime.setShuffleEnabled(preferences.storedShuffle)
    }

    func shuffle() throws -> Command { try capture(.options) { runtime.toggleShuffle() } }

    func observeShuffle(_ enabled: Bool) throws {
        try #require(
            runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing, trackURI: shuffleTrack.uri, timing: shuffleTiming, shuffle: enabled)),
                source: .enginePlayback, revision: 1))
    }
}

@SessionRuntimeActor
private func withShuffleCommand(
    route: ShuffleRoute = .remote,
    preferences: HarnessPreferences = HarnessPreferences(shuffle: true),
    closing: () -> Void = {},
    _ body: (CommandRuntimeFixture) async throws -> Void
) async throws {
    try await withCommandRuntime(preferences: preferences, closing: closing) { fixture in
        try fixture.seedShuffle(route: route)
        try await body(fixture)
    }
}

@Suite("Shuffle command outcomes")
@SessionRuntimeActor
struct ShuffleCommandOutcomeTests {
    @Test(arguments: [false, true], [false, true])
    func commandReplyControlsRollbackAndPersistence(useLocal: Bool, success: Bool) async throws {
        try await withShuffleCommand(route: useLocal ? .local : .remote) { fixture in
            let command = try fixture.shuffle()
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            try await fixture.reply(through: useLocal ? .local : .remote, success: success)
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.shuffle == !success)
            #expect(fixture.preferences.shuffleWrites == (success ? [false] : []))
            #expect(fixture.runtime.semantic.notice?.message == (success ? nil : "Could not update shuffle"))
        }
    }

    @Test func successiveAcceptedLocalChoicesPersistTheirOwnValues() async throws {
        try await withShuffleCommand(route: .local) { fixture in
            for number in 1...2 {
                let command = try fixture.shuffle()
                #expect(fixture.runtime.state.options.shuffle == (number == 2))
                try await fixture.requireDispatch(through: .local, number: number)
                try #require(fixture.engine.operations.count == number, "Each reply follows its own engine entry")
                try await fixture.reply(through: .local, number: number, success: true)
                await command.settlement.wait()
                await fixture.runtime.preferenceState.flush()
                #expect(fixture.runtime.state.pendingCommands[.options] == nil)
                #expect(fixture.runtime.state.options.shuffle == (number == 2))
                #expect(fixture.preferences.shuffleWrites == (number == 1 ? [false] : [false, true]))
            }
        }
    }

    @Test(arguments: [false, true])
    func laggingEngineObservationPreservesOptimismAndRollback(useLocal: Bool) async throws {
        try await withShuffleCommand(route: useLocal ? .local : .remote) { fixture in
            let command = try fixture.shuffle()
            try await fixture.requireDispatch(through: useLocal ? .local : .remote)
            try fixture.observeShuffle(true)
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            try await fixture.reply(through: useLocal ? .local : .remote, success: false)
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.preferences.shuffleWrites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func observedConfirmationWinsOverALateFailureAndPersists(useLocal: Bool) async throws {
        try await withShuffleCommand(route: useLocal ? .local : .remote) { fixture in
            let command = try fixture.shuffle()
            try await fixture.requireDispatch(through: useLocal ? .local : .remote)
            try fixture.observeShuffle(false)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.transportCommandResolutions[command.id] == .confirmed)
            try await fixture.reply(through: useLocal ? .local : .remote, success: false)
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.preferences.shuffleWrites == [false])
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
        }
    }

    @Test func joiningRefusalCannotChangeOrPersistShuffle() async throws {
        try await withShuffleCommand(route: .joining) { fixture in
            let before = fixture.runtime.state.options
            fixture.runtime.toggleShuffle()
            #expect(fixture.runtime.state.options == before)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            #expect(fixture.runtime.semantic.notice?.message == "Spotty is still joining Spotify Connect.")
            #expect(fixture.preferences.shuffleWrites.isEmpty)
            #expect(fixture.engine.operations.isEmpty)
            #expect(fixture.remote.sendCount == 0)
        }
    }

    @Test func duplicateChoiceCannotReplaceTheOriginalAdmission() async throws {
        try await withShuffleCommand { fixture in
            let command = try fixture.shuffle()
            let afterFirst = fixture.runtime.state.options
            fixture.runtime.toggleShuffle()
            #expect(fixture.runtime.state.options == afterFirst)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            try await fixture.requireDispatch(through: .remote)
            #expect(fixture.remote.sendCount == 1)
            #expect(fixture.preferences.shuffleWrites.isEmpty)
            let cancelled = fixture.runtime.effects.cancel(.command(command.id))
            try #require(cancelled != nil)
            await command.settlement.wait()
        }
    }

    @Test func cancellationRollsBackWithoutPersisting() async throws {
        try await withShuffleCommand { fixture in
            let command = try fixture.shuffle()
            try await fixture.requireDispatch(through: .remote)
            let cancelled = fixture.runtime.effects.cancel(.command(command.id))
            try #require(cancelled != nil)
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.preferences.shuffleWrites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func engineReplacementKeepsOptimismButCannotPersistTheRetiredCommand(afterDispatch: Bool) async throws {
        try await withShuffleCommand { fixture in
            let command = try fixture.shuffle()
            if afterDispatch { try await fixture.requireDispatch(through: .remote) }
            try #require(
                fixture.runtime.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection, revision: 1, engineEpoch: fixture.runtime.engineGeneration + 1))
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            if afterDispatch { try await fixture.reply(through: .remote, success: false) }
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.semantic.notice == nil)
            #expect(fixture.preferences.shuffleWrites.isEmpty)
            #expect(fixture.remote.sendCount == (afterDispatch ? 1 : 0))
        }
    }

    @Test(arguments: [false, true])
    func userOptionsCanAdoptRepeatButCannotConfirmShuffle(matches: Bool) async throws {
        try await withShuffleCommand { fixture in
            let command = try fixture.shuffle()
            try await fixture.requireDispatch(through: .remote)
            try #require(
                fixture.runtime.send(
                    .options(PlaybackOptions(shuffle: !matches, repeatMode: matches ? .track : .off)), source: .user))
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.options.repeatMode == (matches ? .track : .off))
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == command.id)
            #expect(fixture.runtime.state.transportCommandResolutions.isEmpty)
            try await fixture.reply(through: .remote, success: false)
            await command.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.preferences.shuffleWrites.isEmpty)
        }
    }

    @Test func aDelayedWritePersistsTheAcceptedChoiceWhileTheNextChoiceIsStillPending() async throws {
        let writing = HarnessResponseGate<Void>(cancellation: .ignored)
        let preferences = HarnessPreferences(shuffle: true, beforeShuffleWrite: { _ in try? await writing.wait() })
        try await withShuffleCommand(route: .local, preferences: preferences, closing: { writing.close() }) { fixture in
            let first = try fixture.shuffle()
            try await fixture.reply(through: .local, success: true)
            await first.settlement.wait()
            try await requireEventually { writing.waiterCount == 1 }
            #expect(fixture.preferences.storedShuffle, "The first write has entered but has not committed")
            let second = try fixture.shuffle()
            try await fixture.requireDispatch(through: .local, number: 2)
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands[.options]?.id == second.id)
            writing.finish(())
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.preferences.shuffleWrites == [false])
            #expect(!fixture.preferences.storedShuffle)
            try await fixture.reply(through: .local, number: 2, success: false)
            await second.settlement.wait()
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.runtime.state.pendingCommands[.options] == nil)
            #expect(!fixture.runtime.state.options.shuffle)
            #expect(fixture.preferences.shuffleWrites == [false])
        }
    }

    @Test func idleShufflePersistsWithoutDispatchingACommand() async throws {
        try await withShuffleCommand(route: .idle, preferences: HarnessPreferences()) { fixture in
            fixture.runtime.toggleShuffle()
            #expect(fixture.runtime.state.options.shuffle)
            #expect(fixture.runtime.state.pendingCommands.isEmpty)
            await fixture.runtime.preferenceState.flush()
            #expect(fixture.preferences.shuffleWrites == [true])
            #expect(fixture.remote.sendCount == 0)
            #expect(fixture.engine.operations.isEmpty)
        }
    }
}

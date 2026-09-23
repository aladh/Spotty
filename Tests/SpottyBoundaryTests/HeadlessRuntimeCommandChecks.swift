import Foundation
import SpottyDomain
import Testing
@testable import SpottySessionRuntime

/// Headless scenarios use the shipping runtime's command and publication path without a window.
@MainActor
struct HeadlessRuntimeCommandTests {
    @Test(arguments: [false, true])
    func playbackObservationUsesTheReducerOutcomeAfterDispatch(expiresFirst: Bool) async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        defer { SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() } }
        let intent = try #require(
            SessionRuntimeActor.sync {
                runtime.play(uri: "spotify:track:requested")
                return runtime.state.intents.last
            })
        #expect(intent.outcome == .admitted)
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intent.command.id)) }
        await settlement?.wait()
        #expect(SessionRuntimeActor.sync { runtime.state.intents.last?.outcome } == .sent)
        #expect(engine.operations.count == 1)
        #expect(
            engine.operations.contains {
                if case let .playURI(uri) = $0 { return uri == "spotify:track:requested" }
                return false
            })

        let presentation = SessionRuntimeActor.sync {
            if expiresFirst { _ = runtime.send(.commandTimedOut(id: intent.command.id), source: .command) }
            _ = runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing, trackURI: "spotify:track:requested",
                        timing: PlaybackTiming(duration: 180, anchoredAt: HarnessDates.fixed))),
                source: .enginePlayback, revision: 1, receivedAt: HarnessDates.fixed)
            return runtime.presentation()
        }
        #expect(
            SessionRuntimeActor.sync { runtime.state.intents.last?.outcome }
                == (expiresFirst ? .timedOut : .observedConfirmed))
        #expect(presentation.currentTrackIndicator.trackURI == "spotify:track:requested")
        #expect(presentation.currentTrackIndicator.isPlaying)
        #expect(engine.operations.count == 1)
    }

    @Test
    func duplicateQueueAddsNeedDistinctObservedOccurrences() async {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        defer { SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() } }
        observeQueue([], revision: 1, runtime: runtime)
        SessionRuntimeActor.sync { runtime.addToQueue(uris: ["spotify:track:a", "spotify:track:a"]) }
        await expectEventually {
            SessionRuntimeActor.sync {
                runtime.state.intents.count == 2 && runtime.state.intents.allSatisfy { $0.outcome == .sent }
            }
        }
        #expect(
            engine.operations.compactMap { operation -> String? in
                if case let .addToQueue(uri) = operation { return uri }
                return nil
            } == ["spotify:track:a", "spotify:track:a"])

        observeQueue(["first"], revision: 2, runtime: runtime)
        #expect(SessionRuntimeActor.sync { runtime.state.intents.map(\.outcome) } == [.observedConfirmed, .sent])
        observeQueue(["first", "second"], revision: 3, runtime: runtime)
        let presentation = SessionRuntimeActor.sync { runtime.presentation() }
        #expect(
            SessionRuntimeActor.sync { runtime.state.intents.map(\.outcome) }
                == [.observedConfirmed, .observedConfirmed])
        #expect(presentation.queueEntries.map(\.uid) == ["first", "second"])
        #expect(engine.operations.count == 2)
    }

    private func observeQueue(_ uids: [String], revision: UInt64, runtime: PlaybackSessionRuntime) {
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: uids.map { PlaybackQueueItem(uri: "spotify:track:a", provider: "queue", uid: $0) },
                        source: .connect, completeness: .complete, revision: revision,
                        receivedAt: HarnessDates.fixed, contextURI: "spotify:playlist:context")),
                source: .engineQueue, revision: revision)
        }
    }

    @Test(arguments: [false, true])
    func seeksBoundPositionsBeforeRouting(useRemote: Bool) async throws {
        let cases: [(fraction: Double, duration: Double, expected: UInt32)] = [
            (0.4, 200, 80_000), (-1, 200, 0), (2, 200, 200_000),
            (1, Double(UInt32.max), UInt32.max), (1, .greatestFiniteMagnitude, UInt32.max),
        ]
        for value in cases {
            let engine = HarnessEngine()
            let remote = HarnessRemote()
            let runtime = makeSeekRuntime(engine, remote: remote, duration: value.duration, useRemote: useRemote)
            let intent = try #require(
                SessionRuntimeActor.sync {
                    runtime.seek(to: value.fraction)
                    return runtime.state.intents.last
                })
            let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intent.command.id)) }
            await settlement?.wait()
            #expect(SessionRuntimeActor.sync { runtime.state.timing.position } == Double(value.expected) / 1_000)
            if useRemote {
                #expect(engine.operations.isEmpty)
                #expect(remote.commands.count == 1)
                let command = try #require(remote.commands.first)
                #expect(command.endpoint == .seek)
                guard case let .integer(milliseconds) = command.value else {
                    Issue.record("Seek must carry integer milliseconds")
                    return
                }
                #expect(milliseconds == Int(value.expected))
            } else {
                #expect(remote.commands.isEmpty)
                #expect(engine.operations.count == 1)
                guard case let .seek(milliseconds) = try #require(engine.operations.first) else {
                    Issue.record("Expected one local seek")
                    return
                }
                #expect(milliseconds == value.expected)
            }
            await runtime.shutdownForTermination()
        }
    }

    @Test(arguments: [false, true])
    func invalidSeekInputsDoNotAdmitAnIntent(useRemote: Bool) async {
        let cases: [(fraction: Double, duration: Double)] = [
            (.nan, 200), (.infinity, 200), (-.infinity, 200),
            (0.5, .nan), (0.5, .infinity), (0.5, -.infinity), (0.5, -1), (0.5, 0),
        ]
        for value in cases {
            let engine = HarnessEngine()
            let remote = HarnessRemote()
            let runtime = makeSeekRuntime(engine, remote: remote, duration: value.duration, useRemote: useRemote)
            SessionRuntimeActor.sync {
                runtime.seek(to: value.fraction)
                #expect(runtime.state.intents.isEmpty)
                #expect(runtime.state.pendingCommands.isEmpty)
                #expect(runtime.state.timing.position == 17)
            }
            await runtime.shutdownForTermination()
            #expect(engine.operations.isEmpty)
            #expect(remote.commands.isEmpty)
        }
    }

    private func makeSeekRuntime(
        _ engine: HarnessEngine, remote: HarnessRemote, duration: Double, useRemote: Bool
    ) -> PlaybackSessionRuntime {
        let runtime = makeRuntime(engine, remote: remote)
        SessionRuntimeActor.sync {
            if useRemote {
                _ = runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true)],
                            localDeviceID: "mac", revision: 2)), source: .engineDevices, revision: 2)
            }
            _ = runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: "spotify:track:seek", duration: duration, metadataSource: .catalog),
                        transport: .paused,
                        timing: PlaybackTiming(position: 17, duration: duration, anchoredAt: HarnessDates.fixed))),
                source: .user)
        }
        return runtime
    }

    private func makeRuntime(_ engine: HarnessEngine, remote: HarnessRemote = HarnessRemote()) -> PlaybackSessionRuntime
    {
        let environment = HarnessEnvironment.make(engine: engine, remote: remote)
        return SessionRuntimeActor.sync {
            let runtime = PlaybackSessionRuntime(environment: environment)
            _ = runtime.send(.session(.ready), source: .account)
            _ = runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                        localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1)
            return runtime
        }
    }
}

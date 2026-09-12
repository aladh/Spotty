import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@MainActor
struct SessionServiceRuntimeTests {
    @Test func writeReceiptsFollowObservationAndRemainFencedAfterSnapshotEviction() async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        let snapshot = await runtime.snapshot()
        let command = SessionCommand(
            sessionID: snapshot.sessionID, expectedRouteRevision: snapshot.routeRevision,
            action: .playURI("spotify:track:requested"))
        let admitted = await runtime.submit(command)
        #expect(admitted.disposition == .admitted)
        let intentID = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[command.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(intentID)) }
        await settlement?.wait()
        let sent = await runtime.submit(command)
        #expect(sent.disposition == .sent)
        #expect(engine.operations.count == 1)
        #expect(
            engine.operations.contains { operation in
                if case let .playURI(uri) = operation { return uri == "spotify:track:requested" }
                return false
            })
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing, trackURI: "spotify:track:requested",
                        timing: PlaybackTiming(duration: 180, anchoredAt: HarnessDates.fixed))),
                source: .enginePlayback, revision: 1, receivedAt: HarnessDates.fixed)
        }
        let confirmed = await runtime.submit(command)
        #expect(confirmed.disposition == .observedConfirmed)
        for _ in 0..<130 {
            _ = await runtime.submit(SessionCommand(sessionID: snapshot.sessionID, action: .seek(fraction: .nan)))
        }
        #expect(!(await runtime.snapshot()).receipts.contains { $0.commandID == command.id })
        #expect(await runtime.submit(command) == confirmed)
        #expect(engine.operations.count == 1)
        SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
    }

    @Test func invalidRouteAndUnknownDeviceNeverReachAnEngine() async {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        let snapshot = await runtime.snapshot()
        let wrongRoute = await runtime.submit(
            SessionCommand(
                sessionID: snapshot.sessionID, expectedRouteRevision: snapshot.routeRevision &+ 1,
                action: .playURI("spotify:track:requested")))
        let wrongAccount = await runtime.submit(SessionCommand(sessionID: UUID(), action: .next))
        let unknownDevice = await runtime.submit(
            SessionCommand(
                sessionID: snapshot.sessionID,
                action: .transfer(
                    ConnectDevice(
                        id: "unobserved-device", name: "Forged speaker", type: "speaker", isActive: false))))
        #expect(wrongRoute.disposition == .rejected)
        #expect(wrongAccount.disposition == .rejected)
        #expect(unknownDevice.disposition == .rejected)
        #expect(engine.operations.isEmpty)
    }

    @Test func orderedTrackRequestDispatchesEveryOccurrence() async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        let snapshot = await runtime.snapshot()
        let tracks = ["a", "b", "a"].enumerated().map { offset, value in
            CatalogTrack(
                id: "row-\(offset)", uri: "spotify:track:\(value)", title: value,
                artist: "Artist", album: "Album", duration: 180, artworkURL: nil, addedAt: nil)
        }
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .playTracks(tracks, contextURI: nil))
        _ = await runtime.submit(command)
        let id = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[command.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(id)) }
        await settlement?.wait()
        #expect(engine.operations.count == 1)
        #expect(
            engine.operations.contains { operation in
                if case let .playTracks(uris) = operation { return uris == tracks.map(\.uri) }
                return false
            })
        SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
    }

    @Test func asynchronousQueueOccurrencesCorrelateToOneClientCommand() async {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: [], source: .connect, completeness: .complete,
                        revision: 1, receivedAt: HarnessDates.fixed, contextURI: "spotify:playlist:context")),
                source: .engineQueue, revision: 1)
        }
        let snapshot = await runtime.snapshot()
        let command = SessionCommand(
            sessionID: snapshot.sessionID,
            action: .addToQueue(["spotify:track:a", "spotify:track:a"]))
        #expect(await runtime.submit(command).disposition == .admitted)
        await expectEventually {
            await runtime.submit(command).disposition == .sent
        }
        #expect(engine.operations.count == 2)
        #expect(
            engine.operations.compactMap { operation -> String? in
                if case let .addToQueue(uri) = operation { return uri }
                return nil
            } == ["spotify:track:a", "spotify:track:a"])
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: [PlaybackQueueItem(uri: "spotify:track:a", provider: "queue", uid: "a1")],
                        source: .connect, completeness: .complete, revision: 2,
                        receivedAt: HarnessDates.fixed, contextURI: "spotify:playlist:context")),
                source: .engineQueue, revision: 2)
        }
        #expect(await runtime.submit(command).disposition == .sent)
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: [
                            PlaybackQueueItem(uri: "spotify:track:a", provider: "queue", uid: "a1"),
                            PlaybackQueueItem(uri: "spotify:track:a", provider: "queue", uid: "a2"),
                        ],
                        source: .connect, completeness: .complete, revision: 3,
                        receivedAt: HarnessDates.fixed, contextURI: "spotify:playlist:context")),
                source: .engineQueue, revision: 3)
        }
        #expect(await runtime.submit(command).disposition == .observedConfirmed)
        SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
    }

    @Test func unknownWriteCannotBecomeConfirmedOrReplayWhenObservationArrivesLate() async throws {
        let engine = HarnessEngine()
        let runtime = makeRuntime(engine)
        let snapshot = await runtime.snapshot()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .playURI("spotify:track:requested"))
        _ = await runtime.submit(command)
        let id = try #require(SessionRuntimeActor.sync { runtime.serviceIntentIDs[command.id]?.first })
        let settlement = SessionRuntimeActor.sync { runtime.effects.settlement(of: .command(id)) }
        await settlement?.wait()
        SessionRuntimeActor.sync { _ = runtime.send(.commandTimedOut(id: id), source: .command) }
        #expect(await runtime.submit(command).disposition == .unknown)
        SessionRuntimeActor.sync {
            _ = runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing, trackURI: "spotify:track:requested",
                        timing: PlaybackTiming(duration: 180, anchoredAt: HarnessDates.fixed))),
                source: .enginePlayback, revision: 1)
        }
        #expect(await runtime.submit(command).disposition == .unknown)
        #expect(engine.operations.count == 1)
        SessionRuntimeActor.sync { _ = runtime.effects.cancelAccountScoped() }
    }

    private func makeRuntime(_ engine: HarnessEngine) -> PlaybackSessionRuntime {
        let environment = HarnessEnvironment.make(engine: engine)
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

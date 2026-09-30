import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

private enum QueuePrerequisiteFailure: Error { case injected }

@Suite("Queue response script lifetime")
@MainActor
struct QueueResponseScriptTests {
    @Test
    func earlySuccessAnd429RetainTheirExactOutcomes() async throws {
        let script = QueueResponseScript()
        defer { script.close() }
        let track = CatalogTrack(
            id: "spotify:track:early", uri: "spotify:track:early", title: "Early", artist: "Artist",
            album: "Album", duration: 180, artworkURL: nil, addedAt: nil)
        script.complete(1, with: [track])
        script.fail429(2)
        #expect(try await script.next() == [track])
        do {
            _ = try await script.next()
            Issue.record("The early 429 must remain a Web queue failure")
        } catch let failure as WebQueueFailure {
            #expect(failure.statusCode == 429)
        }
        #expect(script.pendingRequestIDs.isEmpty)
    }

    @Test
    func anUnexpectedThirdRequestFailsImmediatelyWithItsNumber() async throws {
        let script = QueueResponseScript()
        defer { script.close() }
        script.complete(1, with: [])
        script.complete(2, with: [])
        _ = try await script.next()
        _ = try await script.next()
        do {
            _ = try await script.next()
            Issue.record("Request 3 must not wait or silently succeed")
        } catch let failure as QueueResponseScript.Failure {
            #expect(failure == .unexpectedRequest(3))
        }
        #expect(script.pendingRequestIDs.isEmpty)
    }

    @Test
    func closeReleasesCurrentAndFutureRequestsAndCannotBeReopened() async throws {
        let script = QueueResponseScript()
        let callers = (0..<2).map { _ in Task { try await script.next() } }
        do {
            try await requireEventually { script.pendingRequestIDs == [1, 2] }
        } catch {
            script.close()
            for caller in callers { _ = await caller.result }
            throw error
        }
        script.close()
        for caller in callers {
            switch await caller.result {
            case .success: Issue.record("Terminal close must cancel pending requests")
            case let .failure(error): #expect(error is CancellationError)
            }
        }
        script.close()
        script.complete(1, with: [])
        script.fail429(2)
        do {
            _ = try await script.next()
            Issue.record("Terminal close must cancel future requests")
        } catch is CancellationError {}
        #expect(script.pendingRequestIDs.isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func aFailedPrerequisiteClosesAndJoinsEveryAcceptedWorker(admittedRequests: Int) async throws {
        let fixture = QueueResponseFixture()
        do {
            try await fixture.run { fixture in
                await fixture.service.reset(accountEpoch: 1)
                _ = fixture.start()
                if admittedRequests > 0 { _ = try await fixture.requireRequest(1) }
                if admittedRequests > 1 {
                    await fixture.service.reset(accountEpoch: 2)
                    _ = fixture.start(accountEpoch: 2)
                    _ = try await fixture.requireRequest(2)
                }
                throw QueuePrerequisiteFailure.injected
            }
            Issue.record("The injected prerequisite must throw")
        } catch QueuePrerequisiteFailure.injected {}
        #expect(fixture.script.pendingRequestIDs.isEmpty)
        #expect(await fixture.service.refreshSubscriberCount == 0)
        #expect(await fixture.service.refreshWorkerTask == nil)
        do {
            _ = try await fixture.script.next()
            Issue.record("Cleanup must close requests that arrive after the prerequisite failed")
        } catch is CancellationError {}
    }
}

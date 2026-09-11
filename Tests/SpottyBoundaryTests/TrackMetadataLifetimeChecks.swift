import Foundation
import Testing
@testable import SpottyCore

/// Gates `HarnessRemote.onMetadata` so a check can track multiple concurrent metadata requests
/// for the same URI independently and complete or fail each by its own request id, mirroring the
/// pre-harness `LateMetadataRemote` actor. `HarnessRemote`'s built-in `.park` behavior keeps only
/// one continuation per URI, which cannot express "an old-account request outlives the request
/// that replaced it" — the exact scenario this suite checks — so this gate keeps one continuation
/// per request instead.
private actor LateMetadataGate {
    private var continuations: [Int: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>] = [:]
    private var nextRequestID = 0

    func request(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        nextRequestID += 1
        let requestID = nextRequestID
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func complete(_ requestID: Int, uri: String, title: String) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: HarnessFixtures.metadata(uri: uri, title: title)
        )
    }

    func fail(_ requestID: Int) {
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }
}

private func makeLateMetadataRemote() -> (remote: HarnessRemote, gate: LateMetadataGate) {
    let gate = LateMetadataGate()
    let remote = HarnessRemote()
    remote.onMetadata = { [gate] uri in try await gate.request(for: uri) }
    return (remote, gate)
}

@Suite("Track metadata lifetime")
struct TrackMetadataLifetimeTests {
    @Test
    @MainActor
    func lateSuccessCannotOverwriteReplacementAccountCacheOrFlight() async throws {
        let (remote, gate) = makeLateMetadataRemote()
        let service = TrackMetadataService(remote: remote)
        let uri = "spotify:track:replaced"

        let old = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { remote.requestedURIs.count == 1 })
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { remote.requestedURIs.count == 2 })

        await gate.complete(2, uri: uri, title: "Replacement")
        #expect((await replacement.value)?.title == "Replacement")
        await gate.complete(1, uri: uri, title: "Late old account")
        #expect((await old.value)?.title == "Late old account")
        #expect((try await service.metadata(for: uri)).title == "Replacement")
    }

    @Test
    @MainActor
    func lateErrorCannotClearReplacementAccountFlight() async throws {
        let (remote, gate) = makeLateMetadataRemote()
        let service = TrackMetadataService(remote: remote)
        let uri = "spotify:track:replaced-error"

        let old = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { remote.requestedURIs.count == 1 })
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { remote.requestedURIs.count == 2 })

        await gate.fail(1)
        #expect((await old.value) == nil)
        await gate.complete(2, uri: uri, title: "Replacement")
        #expect((await replacement.value)?.title == "Replacement")
        #expect((try await service.metadata(for: uri)).title == "Replacement")
    }
}

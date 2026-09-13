import Foundation
import Testing
@testable import SpottyCore
import SpottyRuntimeContracts
@testable import SpottySessionRuntime

/// Gates `HarnessRemote.onMetadata` so a check can track multiple concurrent metadata requests
/// for the same URI independently and complete or fail each by its own request id, mirroring the
/// pre-harness `LateMetadataRemote` actor. `HarnessRemote`'s built-in `.park` behavior keeps only
/// one continuation per URI, which cannot express "an old-account request outlives the request
/// that replaced it" — the exact scenario this suite checks — so this gate keeps one continuation
/// per request instead.
private actor LateMetadataGate {
    private var continuations: [Int: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>] = [:]
    private var nextRequestID = 0
    private var cancelledBeforeRegistration: Set<Int> = []

    var parkedRequestIDs: Set<Int> { Set(continuations.keys) }

    func request(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        nextRequestID += 1
        let requestID = nextRequestID
        if cancelledBeforeRegistration.remove(requestID) != nil {
            throw CancellationError()
        }
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
        guard let continuation = continuations.removeValue(forKey: requestID) else {
            cancelledBeforeRegistration.insert(requestID)
            return
        }
        continuation.resume(throwing: CancellationError())
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
        defer { old.cancel(); replacementCleanup(gate, ids: [1, 2]) }
        try await requireEventually { await gate.parkedRequestIDs.contains(1) }
        #expect(remote.requestedURIs.count == 1)
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        defer { replacement.cancel() }
        try await requireEventually { await gate.parkedRequestIDs.contains(2) }
        #expect(remote.requestedURIs.count == 2)

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
        defer { old.cancel(); replacementCleanup(gate, ids: [1, 2]) }
        try await requireEventually { await gate.parkedRequestIDs.contains(1) }
        #expect(remote.requestedURIs.count == 1)
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        defer { replacement.cancel() }
        try await requireEventually { await gate.parkedRequestIDs.contains(2) }
        #expect(remote.requestedURIs.count == 2)

        await gate.fail(1)
        #expect((await old.value) == nil)
        await gate.complete(2, uri: uri, title: "Replacement")
        #expect((await replacement.value)?.title == "Replacement")
        #expect((try await service.metadata(for: uri)).title == "Replacement")
    }
}

private func replacementCleanup(_ gate: LateMetadataGate, ids: [Int]) {
    Task {
        for id in ids { await gate.fail(id) }
    }
}

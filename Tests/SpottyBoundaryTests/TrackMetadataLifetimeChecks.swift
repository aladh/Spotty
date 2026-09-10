import Foundation
import Testing
@testable import SpottyCore

private actor LateMetadataRemote: RemotePlaybackClient {
    private var continuations: [Int: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>] = [:]
    private var nextRequestID = 0
    private(set) var requestCount = 0

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        nextRequestID += 1
        let requestID = nextRequestID
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func complete(_ requestID: Int, uri: String, title: String) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: SpotifyConnectTrackMetadata(
                uri: uri,
                title: title,
                artist: "Artist",
                artworkURL: nil,
                duration: 180
            )
        )
    }

    func fail(_ requestID: Int) {
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }
}

@Suite("Track metadata lifetime")
struct TrackMetadataLifetimeTests {
    @Test
    @MainActor
    func lateSuccessCannotOverwriteReplacementAccountCacheOrFlight() async throws {
        let remote = LateMetadataRemote()
        let service = TrackMetadataService(remote: remote)
        let uri = "spotify:track:replaced"

        let old = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { await remote.requestCount == 1 })
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { await remote.requestCount == 2 })

        await remote.complete(2, uri: uri, title: "Replacement")
        #expect((await replacement.value)?.title == "Replacement")
        await remote.complete(1, uri: uri, title: "Late old account")
        #expect((await old.value)?.title == "Late old account")
        #expect((try await service.metadata(for: uri)).title == "Replacement")
    }

    @Test
    @MainActor
    func lateErrorCannotClearReplacementAccountFlight() async throws {
        let remote = LateMetadataRemote()
        let service = TrackMetadataService(remote: remote)
        let uri = "spotify:track:replaced-error"

        let old = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { await remote.requestCount == 1 })
        await service.reset()
        let replacement = Task { try? await service.metadata(for: uri) }
        #expect(await waitUntil { await remote.requestCount == 2 })

        await remote.fail(1)
        #expect((await old.value) == nil)
        await remote.complete(2, uri: uri, title: "Replacement")
        #expect((await replacement.value)?.title == "Replacement")
        #expect((try await service.metadata(for: uri)).title == "Replacement")
    }
}

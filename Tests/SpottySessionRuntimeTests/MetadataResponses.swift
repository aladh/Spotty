import SpottyRuntimeContracts
import Testing

// Uses shared response gates without importing the desktop harness into runtime checks.
struct MetadataResponses: RemotePlaybackClient {
    let fetch: @Sendable (String) async throws -> SpotifyConnectTrackMetadata
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata { try await fetch(uri) }
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        Issue.record("Metadata lookup must not dispatch playback commands")
    }
}

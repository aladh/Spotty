import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@Test("Queue cooldown preserves the Connect fallback")
@MainActor
func queueCooldownAndFallback() async {
    let clock = HarnessClock.advancing(from: HarnessDates.fixed)
    let fallback = [
        QueueEntry(uri: "spotify:track:alpha", provider: "connect", occurrence: 0, uid: "uid-alpha"),
        QueueEntry(uri: "spotify:track:beta", provider: "connect", occurrence: 1, uid: "uid-beta"),
    ]
    let cached = [
        queueCheckTrack("spotify:track:alpha"),
        queueCheckTrack("spotify:track:beta"),
    ]
    let webQueue = RateLimitedThenAvailableWebQueue(tracks: [queueCheckTrack("spotify:track:web")])
    let limitedService = QueueService(
        webQueue: webQueue,
        metadata: TrackMetadataService(remote: UnusedQueueRemote()),
        clock: clock
    )
    await limitedService.reset(accountEpoch: 11)

    let first = await limitedService.refresh(
        fallbackEntries: fallback,
        cachedTracks: cached,
        currentTrackURI: "spotify:track:now",
        accountEpoch: 11
    )
    #expect((await webQueue.callCount) == (1), "first 429 performs one Web queue call")
    #expect((first?.source) == (.connect), "first 429 falls back to Connect")
    #expect((first?.completeness) == (.complete), "first 429 Connect fallback is complete")
    #expect(
        (first?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
        "first 429 preserves Connect order")
    #expect(
        (first?.entries.map(\.uid)) == (["uid-alpha", "uid-beta"]),
        "first 429 preserves Connect occurrence uids")

    let second = await limitedService.refresh(
        fallbackEntries: fallback,
        cachedTracks: cached,
        currentTrackURI: "spotify:track:now",
        accountEpoch: 11
    )
    #expect((await webQueue.callCount) == (1), "cooldown refresh makes no second Web request")
    #expect((second?.source) == (.connect), "cooldown refresh still uses Connect")
    #expect((second?.completeness) == (.complete), "cooldown refresh stays complete")
    #expect(
        (second?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
        "cooldown refresh keeps Connect order")
    clock.advance(seconds: 5 * 60 + 1)
    let recovered = await limitedService.refresh(
        fallbackEntries: fallback,
        cachedTracks: cached,
        currentTrackURI: "spotify:track:now",
        accountEpoch: 11
    )
    #expect((await webQueue.callCount) == (2), "expired cooldown retries the Web queue once")
    #expect((recovered?.source) == (.connect), "expired cooldown keeps authoritative Connect order")
    #expect(
        (recovered?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
        "expired cooldown does not let Web reorder Connect entries")
    #expect(
        (recovered?.entries.map(\.uid)) == (["uid-alpha", "uid-beta"]),
        "expired cooldown preserves Connect occurrence uids")
}

private func queueCheckTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private struct UnusedQueueRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri, title: "Unused", artist: "Unused", artworkURL: nil, duration: 1
        )
    }
}

private actor RateLimitedThenAvailableWebQueue: WebQueueClient {
    private let tracks: [CatalogTrack]
    private(set) var callCount = 0

    init(tracks: [CatalogTrack]) {
        self.tracks = tracks
    }

    func queue() async throws -> [CatalogTrack] {
        callCount += 1
        if callCount == 1 {
            throw WebQueueFailure.requestFailed(429)
        }
        return tracks
    }
}

import Foundation
import SpottyDomain
import SpottyEngineAdapter
import Testing
@testable import SpottyBrowsingSupport

@Suite("Synthetic playback selections", .serialized)
@MainActor
struct SyntheticPlaybackSelectionChecks {
    @Test(arguments: [false, true])
    func collectionStartsPublishTheirOwnTrackAndContext(local: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottySelection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let playback = try world(at: root).playback
        var events = playback.events().makeAsyncIterator()
        let index = local ? 0 : 2
        for (uri, trackPrefix) in [
            ("spotify:playlist:synthetic1", "spotify:track:synthetic1x"),
            ("spotify:album:syntheticAlbum0", "spotify:track:syntheticAlbum0x"),
            ("spotify:artist:syntheticArtist0", "spotify:track:syntheticArtist0x"),
            ("spotify:album:syntheticArtistRelease0x1", "spotify:track:syntheticArtistRelease0x1x"),
        ] {
            if local {
                #expect(playback.execute(.playURI(uri)).isOK)
            } else {
                try playback.send(.play(uri: uri, trackIndex: index), to: SyntheticPlayback.remoteID)
            }
            let observed = try await observation(&events)
            #expect(observed.contextURI == uri)
            #expect(observed.trackURI == "\(trackPrefix)\(index)")
            #expect(observed.isPlaying && observed.positionMS == 0)
            #expect(playback.queueSnapshot().track?.uri == observed.trackURI)
        }
    }

    @Test(arguments: [false, true])
    func standaloneTrackAndTrackListClearThePreviousCollection(local: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyStandalone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let playback = try world(at: root).playback
        var events = playback.events().makeAsyncIterator()
        for list in [false, true] {
            try playback.send(.play(uri: "spotify:playlist:synthetic1"), to: SyntheticPlayback.remoteID)
            _ = try await observation(&events)
            let tracks = ["spotify:track:synthetic0x5", "spotify:track:synthetic0x6"]
            if local {
                #expect(playback.execute(list ? .playTracks(tracks) : .playURI(tracks[0])).isOK)
            } else {
                try playback.send(
                    list ? .play(trackURIs: tracks) : .play(uri: tracks[0]),
                    to: SyntheticPlayback.remoteID)
            }
            let observed = try await observation(&events)
            #expect(observed.contextURI == "", "an explicit empty context clears the runtime's old collection")
            #expect(observed.trackURI == tracks[0] && observed.isPlaying)
        }
    }

    @Test func transportAndDeviceChangesKeepTheSelectedContextAndPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyContextResume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let playback = try world(at: root).playback
        var events = playback.events().makeAsyncIterator()
        let context = "spotify:album:syntheticAlbum0"
        let track = "spotify:track:syntheticAlbum0x0"
        try playback.send(.play(uri: context), to: SyntheticPlayback.remoteID)
        _ = try await observation(&events)
        try playback.send(.seek(to: 42_000), to: SyntheticPlayback.remoteID)
        _ = try await observation(&events)
        try playback.send(.pause, to: SyntheticPlayback.remoteID)
        let paused = try await observation(&events)
        #expect(paused.contextURI == context && paused.trackURI == track && paused.positionMS == 42_000)
        #expect(paused.isPaused && !paused.isPlaying)
        try playback.send(.resume, to: SyntheticPlayback.remoteID)
        let resumed = try await observation(&events)
        #expect(resumed.contextURI == context && resumed.trackURI == track && resumed.positionMS == 42_000)
        #expect(resumed.isPlaying)
        playback.handoff(to: SyntheticPlayback.localID)
        let moved = try await observation(&events)
        #expect(moved.isActiveDevice && moved.contextURI == context && moved.positionMS == 42_000)
        #expect(playback.execute(.pause).isOK)
        _ = try await observation(&events)
        #expect(
            playback.execute(
                .resumeObserved(
                    PlaybackResumeTarget(
                        trackURI: track, contextURI: context, positionMS: 42_000, engineGeneration: 1))
            ).isOK)
        let localResume = try await observation(&events)
        #expect(localResume.contextURI == context && localResume.trackURI == track && localResume.positionMS == 42_000)
        #expect(localResume.isPlaying)
        playback.replaceSession(preservingPlayback: true)
        let reconnected = try await observation(&events)
        #expect(reconnected.contextURI == context && reconnected.trackURI == track && reconnected.positionMS == 42_000)
    }

    @Test(arguments: [false, true])
    func emptyAndUnknownCollectionsCannotPretendTheOldTrackStarted(local: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyEmptySelection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let playback = try world(at: root).playback
        var events = playback.events().makeAsyncIterator()
        for uri in [
            "spotify:album:syntheticAlbum4", "spotify:artist:syntheticArtist4",
            "spotify:playlist:missing", "spotify:album:missing", "spotify:show:missing",
        ] {
            if local {
                #expect(!playback.execute(.playURI(uri)).isOK)
            } else {
                #expect(throws: (any Error).self) {
                    try playback.send(.play(uri: uri), to: SyntheticPlayback.remoteID)
                }
            }
            playback.publish()
            let observed = try await observation(&events)
            #expect(observed.isPaused && !observed.isPlaying && observed.positionMS == 0)
            #expect(observed.trackURI == "spotify:track:synthetic0x0")
            #expect(observed.contextURI == "spotify:playlist:synthetic0")
        }
        #expect(playback.snapshot().rejectedCount == 5)
    }

    private func world(at root: URL) throws -> BrowsingWorld {
        var input = BrowsingScenario(trackCount: 30, artworkCount: 1, artworkPixels: 64, cycles: 1)
        input.version = 2
        input.mode = .playback
        return try BrowsingWorld(scenario: input, artworkDirectory: root)
    }

    private func observation(_ events: inout AsyncStream<RustPlaybackEventEnvelope>.Iterator) async throws
        -> RustPlaybackState
    {
        let envelope = try #require(await events.next(isolation: #isolation))
        guard case let .cluster(cluster) = envelope.event else {
            throw BrowsingFailure.checkpoint("selection observation")
        }
        return try #require(cluster.playback)
    }
}

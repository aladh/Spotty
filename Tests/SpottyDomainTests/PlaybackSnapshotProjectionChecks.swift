import Testing
import SpottyDomain
import Foundation

@Suite("Playback Snapshot Projection")
struct PlaybackSnapshotProjectionTests {
    @Test
    func testPlaybackSnapshotProjection() {
        let receivedAt = Date(timeIntervalSince1970: 1_010)

        do {
            #expect((PlaybackSnapshotProjection.resolvedTrackURI("")) == nil, "an empty wire URI is missing")
            #expect(
                (PlaybackSnapshotProjection.resolvedTrackURI("spotify:track:now")) == ("spotify:track:now"),
                "a nonempty wire URI is kept")
            #expect(
                (PlaybackSnapshotProjection.isAudible(isPlaying: true, isPaused: false)) == true,
                "playing and not paused is audible")
            #expect(
                (!PlaybackSnapshotProjection.isAudible(isPlaying: true, isPaused: true)) == true,
                "playing and paused is not audible")
            #expect(
                (!PlaybackSnapshotProjection.isAudible(isPlaying: false, isPaused: false)) == true,
                "not playing is not audible")

            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: true,
                    isPaused: false,
                    trackURI: "spotify:track:now",
                    isInitialSnapshot: false,
                    isActiveDevice: true
                )) == (.playing), "audible playback with a track is playing")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: true,
                    isPaused: false,
                    trackURI: "spotify:track:now",
                    isInitialSnapshot: true,
                    isActiveDevice: true
                )) == (.paused), "the first local snapshot does not present playing")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: true,
                    isPaused: false,
                    trackURI: "spotify:track:now",
                    isInitialSnapshot: true,
                    isActiveDevice: false
                )) == (.playing), "the first remote snapshot may present playing")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: true,
                    isPaused: true,
                    trackURI: "spotify:track:now",
                    isInitialSnapshot: false,
                    isActiveDevice: false
                )) == (.paused), "playing and paused together is paused when a track is present")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: false,
                    isPaused: false,
                    trackURI: "",
                    isInitialSnapshot: false,
                    isActiveDevice: false
                )) == (.stopped), "no track and no audible playback is stopped")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: true,
                    isPaused: false,
                    trackURI: "",
                    isInitialSnapshot: false,
                    isActiveDevice: false
                )) == (.playing), "audible playback with an empty URI stays playing")
            let emptyURIPlaying = PlaybackSnapshotProjection.snapshot(
                isPlaying: true,
                isPaused: false,
                trackURI: "",
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                shuffle: false,
                repeatContext: false,
                repeatTrack: false,
                isInitialSnapshot: false,
                isActiveDevice: false,
                receivedAt: receivedAt
            )
            #expect((emptyURIPlaying.transport) == (.playing), "empty-URI audible snapshot stays playing")
            #expect((emptyURIPlaying.trackURI) == nil, "empty-URI audible snapshot has no track identity")
            #expect(
                (PlaybackSnapshotProjection.transport(
                    isPlaying: false,
                    isPaused: true,
                    trackURI: "spotify:track:now",
                    isInitialSnapshot: false,
                    isActiveDevice: true
                )) == (.paused), "a paused track is paused")

            let snapshot = PlaybackSnapshotProjection.snapshot(
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:now",
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                shuffle: true,
                repeatContext: true,
                repeatTrack: false,
                isInitialSnapshot: false,
                isActiveDevice: false,
                receivedAt: receivedAt
            )
            #expect((snapshot.transport) == (.playing), "a live remote snapshot presents playing")
            #expect((snapshot.trackURI) == ("spotify:track:now"), "snapshot track identity drops empty URIs")
            #expect((snapshot.timing.position) == (45), "playing snapshots compensate for their timestamp")
            #expect((snapshot.timing.duration) == (200), "snapshot duration is seconds")
            #expect((snapshot.shuffle) == (true), "snapshot shuffle is forwarded")
            #expect((snapshot.repeatMode) == (.context), "snapshot repeat mode follows the wire flags")
            #expect(
                (snapshot.repeatFlags) == (RepeatFlags(context: true, track: false)),
                "snapshot repeat flags follow the wire")

            let firstLocal = PlaybackSnapshotProjection.snapshot(
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:now",
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                shuffle: false,
                repeatContext: false,
                repeatTrack: false,
                isInitialSnapshot: true,
                isActiveDevice: true,
                receivedAt: receivedAt
            )
            #expect((firstLocal.transport) == (.paused), "first-local snapshot() presents paused")
            #expect((firstLocal.timing.position) == (40), "first-local snapshot() does not interpolate position")

            let localUnavailable = PlaybackSnapshotProjection.snapshot(
                isPlaying: false,
                isPaused: true,
                trackURI: "spotify:track:unavailable",
                positionMilliseconds: 0,
                durationMilliseconds: 200_000,
                timestampMilliseconds: nil,
                shuffle: false,
                repeatContext: false,
                repeatTrack: false,
                trackUnavailable: true,
                isInitialSnapshot: false,
                isActiveDevice: true,
                receivedAt: receivedAt
            )
            #expect((localUnavailable.trackUnavailable) == true, "an active track failure crosses projection")

            let remoteUnavailable = PlaybackSnapshotProjection.snapshot(
                isPlaying: false,
                isPaused: true,
                trackURI: "spotify:track:unavailable",
                positionMilliseconds: 0,
                durationMilliseconds: 200_000,
                timestampMilliseconds: nil,
                shuffle: false,
                repeatContext: false,
                repeatTrack: false,
                trackUnavailable: true,
                isInitialSnapshot: false,
                isActiveDevice: false,
                receivedAt: receivedAt
            )
            #expect((remoteUnavailable.trackUnavailable) == false, "a remote track failure stays out of notices")

            let emptyUnavailable = PlaybackSnapshotProjection.snapshot(
                isPlaying: false,
                isPaused: true,
                trackURI: "",
                positionMilliseconds: 0,
                durationMilliseconds: 0,
                timestampMilliseconds: nil,
                shuffle: false,
                repeatContext: false,
                repeatTrack: false,
                trackUnavailable: true,
                isInitialSnapshot: false,
                isActiveDevice: true,
                receivedAt: receivedAt
            )
            #expect((emptyUnavailable.trackUnavailable) == false, "an empty URI cannot become a failure notice")
        }
    }
    @Test func preservesExplicitContextForBothDeviceRoles() {
        for active in [true, false] {
            for context: String? in [nil, "", "spotify:playlist:one"] {
                let snapshot = PlaybackSnapshotProjection.snapshot(
                    isPlaying: true, isPaused: false, trackURI: "spotify:track:one",
                    positionMilliseconds: 0, durationMilliseconds: 120000,
                    timestampMilliseconds: nil, shuffle: false, repeatContext: false,
                    repeatTrack: false, isInitialSnapshot: false, isActiveDevice: active,
                    receivedAt: Date(timeIntervalSince1970: 0), contextURI: context)
                #expect(snapshot.contextURI == context)
            }
        }
    }

}

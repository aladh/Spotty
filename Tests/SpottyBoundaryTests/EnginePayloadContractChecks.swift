import Testing
import Foundation
import SpottyPlaybackCore
@testable import SpottyCore

@Suite("Engine Payload Contract")
struct EnginePayloadContractTests {
    @Test
    @MainActor
    func testPlaybackSnapshotCopiesBorrowedFields() {
        let track = allocatedCString(capacity: 64)
        defer {
            track.deallocate()
        }
        writeCString("spotify:track:before", to: track)

        var snapshot = SpottyPlaybackSnapshot()
        snapshot.revision = 7
        snapshot.session_generation = 11
        snapshot.position_ms = 1_234
        snapshot.duration_ms = 56_789
        snapshot.timestamp_ms = 1_800_000_123
        snapshot.is_playing = 2
        snapshot.is_paused = 0
        snapshot.shuffle = 2
        snapshot.repeat_track = 0
        snapshot.repeat_context = 2
        snapshot.is_active_device = 2
        snapshot.track_unavailable = 2
        snapshot.track_uri = UnsafePointer(track)

        let state = withUnsafePointer(to: &snapshot) { PlaybackCore.playbackState(from: $0) }

        writeCString("spotify:track:after", to: track)

        #expect((state?.revision) == (7), "playback revision crosses the C boundary")
        #expect((state?.sessionGeneration) == (11), "playback session generation crosses the C boundary")
        #expect((state?.positionMS) == (1_234), "playback position crosses the C boundary")
        #expect((state?.durationMS) == (56_789), "playback duration crosses the C boundary")
        #expect((state?.timestampMS) == (1_800_000_123), "playback timestamp crosses the C boundary")
        #expect((state?.isPlaying) == (true), "playing flag is decoded")
        #expect((state?.isPaused) == (false), "paused flag is decoded")
        #expect((state?.shuffle) == (true), "shuffle flag is decoded")
        #expect((state?.repeatTrack) == (false), "track repeat flag is decoded")
        #expect((state?.repeatContext) == (true), "context repeat flag is decoded")
        #expect((state?.isActiveDevice) == (true), "active-device fact is decoded")
        #expect((state?.trackUnavailable) == (true), "track-unavailable flag is decoded")
        #expect((state?.trackURI) == ("spotify:track:before"), "track URI is copied before callback return")

        snapshot.track_uri = nil
        snapshot.track_unavailable = 0
        let missing = withUnsafePointer(to: &snapshot) { PlaybackCore.playbackState(from: $0) }
        #expect((missing?.trackURI) == (""), "a missing playback track maps to an empty identity")
        #expect((missing?.trackUnavailable) == (false), "an ordinary playback snapshot is not unavailable")
        #expect(missing?.contextURI == nil, "a null context pointer omits context")
        writeCString("", to: track)
        snapshot.context_uri = UnsafePointer(track)
        let cleared = withUnsafePointer(to: &snapshot) { PlaybackCore.playbackState(from: $0) }
        #expect(cleared?.contextURI == "", "an empty C string remains an explicit context clear")

    }

    @Test
    @MainActor
    func testConnectionSnapshotCopiesBorrowedFieldsAndPreservesMissingValues() {
        let device = allocatedCString(capacity: 64)
        let error = allocatedCString(capacity: 64)
        defer {
            device.deallocate()
            error.deallocate()
        }
        writeCString("device-before", to: device)
        writeCString("error-before", to: error)

        var snapshot = SpottyConnectionSnapshot()
        snapshot.revision = 13
        snapshot.session_generation = 17
        snapshot.session_connected = 2
        snapshot.spirc_ready = 0
        snapshot.is_active_device = 2
        snapshot.resume_pending = 2
        snapshot.credentials_rejected = 2
        snapshot.device_id = UnsafePointer(device)
        snapshot.last_error = UnsafePointer(error)

        let state = withUnsafePointer(to: &snapshot) { PlaybackCore.connectionState(from: $0) }

        writeCString("device-after", to: device)
        writeCString("error-after", to: error)

        #expect((state?.revision) == (13), "connection revision crosses the C boundary")
        #expect((state?.sessionGeneration) == (17), "connection session generation crosses the C boundary")
        #expect((state?.sessionConnected) == (true), "connected flag is decoded")
        #expect((state?.spircReady) == (false), "Spirc readiness flag is decoded")
        #expect((state?.isActiveDevice) == (true), "connection active-device fact is decoded")
        #expect((state?.resumePending) == (true), "resume window flag is decoded")
        #expect((state?.credentialsRejected) == (true), "credential rejection flag is decoded")
        #expect((state?.deviceID) == ("device-before"), "device ID is copied before callback return")
        #expect((state?.lastError) == ("error-before"), "last error is copied before callback return")

        snapshot.device_id = nil
        snapshot.last_error = nil
        let missing = withUnsafePointer(to: &snapshot) { PlaybackCore.connectionState(from: $0) }
        #expect((missing?.deviceID) == nil, "missing device IDs remain missing")
        #expect((missing?.lastError) == nil, "missing errors remain missing")
        #expect((PlaybackCore.connectionState(from: nil)) == nil, "a missing connection snapshot is ignored")
        #expect((PlaybackCore.playbackState(from: nil)) == nil, "a missing playback snapshot is ignored")
    }
}

private func allocatedCString(capacity: Int) -> UnsafeMutablePointer<CChar> {
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    pointer.initialize(repeating: 0, count: capacity)
    return pointer
}

private func writeCString(_ value: String, to pointer: UnsafeMutablePointer<CChar>) {
    value.withCString { source in
        pointer.update(from: source, count: value.utf8.count + 1)
    }
}

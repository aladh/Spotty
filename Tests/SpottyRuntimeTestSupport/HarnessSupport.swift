import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyGateway
import SpottyRuntimeContracts

/// The single failure boundary fakes throw when a dependency is deliberately unavailable.
enum HarnessFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Small value builders reused by fakes and by checks that need a realistic payload.
enum HarnessFixtures {
    static func queueState(
        revision: UInt64,
        generation: UInt64 = 1,
        trackURI: String? = nil,
        next: [QueueProtocolTrack] = [],
        prev: [QueueProtocolTrack] = [],
        queueRevision: String = "",
        disallowSetQueue: Bool = false,
        disallowRemovingFromNextTracks: Bool = false
    ) -> RustQueueState {
        RustQueueState(
            revision: revision, sessionGeneration: generation,
            track: trackURI.map { RustQueueState.Item(uri: $0, provider: "context", uid: "current") },
            protocolNextTracks: next, protocolPrevTracks: prev, queueRevision: queueRevision,
            disallowSetQueue: disallowSetQueue, disallowRemovingFromNextTracks: disallowRemovingFromNextTracks)
    }

    /// Build matching protocol input for checks that already name their expected visible rows.
    static func queueTracks(_ entries: [QueueEntry]) -> [QueueProtocolTrack] {
        entries.map { QueueProtocolTrack(uri: $0.uri, uid: $0.uid, provider: $0.provider) }
    }

    static func home(sectionIDs: [Int], itemsPerSection: Int = 1) -> CatalogHomeSnapshot {
        CatalogHomeSnapshot(
            greeting: "",
            sections: sectionIDs.map { section in
                CatalogSection(
                    id: "section:\(section)", title: "",
                    items: (0..<itemsPerSection).map { index in
                        let id = "mix\(section)-\(index)"
                        return CatalogItem(
                            id: id, uri: "spotify:playlist:\(id)", title: "Mix \(section)", subtitle: "",
                            artworkURL: nil, kind: .playlist)
                    })
            })
    }

    static func metadata(
        uri: String,
        title: String = "Metadata",
        artist: String = "Artist",
        artworkURL: URL? = nil,
        duration: TimeInterval = 180
    ) -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            duration: duration
        )
    }

    static func track(
        uri: String,
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        duration: TimeInterval = 180
    ) -> CatalogTrack {
        CatalogTrack(
            id: uri,
            uri: uri,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: nil,
            addedAt: nil
        )
    }

    static func tokens(
        accessToken: String = "fixture-access",
        refreshToken: String = "fixture-refresh",
        expiresAt: Date = .distantFuture,
        username: String = "fixture-user"
    ) -> KeymasterTokens {
        KeymasterTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            username: username
        )
    }

    static func connectCluster(
        revision: UInt64,
        activeID: String,
        trackURI: String,
        devicesRevision: UInt64? = nil,
        isPlaying: Bool = false,
        playbackRevision: UInt64? = nil
    ) -> RustConnectClusterState {
        RustConnectClusterState(
            revision: revision,
            sessionGeneration: 1,
            source: 2,
            localDeviceID: "local",
            devices: RustDevicesState(
                revision: devicesRevision ?? revision,
                sessionGeneration: 1,
                activeDeviceID: activeID,
                devices: [
                    ConnectProtocolDevice(id: "local", name: "Spotty", type: "computer"),
                    ConnectProtocolDevice(id: "phone", name: "Phone", type: "smartphone"),
                    ConnectProtocolDevice(id: "tablet", name: "Tablet", type: "tablet"),
                ]
            ),
            connection: RustConnectionState(
                revision: revision, sessionGeneration: 1, sessionConnected: true, spircReady: true,
                isActiveDevice: activeID == "local", resumePending: false, lastError: nil, deviceID: "local"
            ),
            playback: RustPlaybackState(
                revision: playbackRevision ?? revision, sessionGeneration: 1, isPlaying: isPlaying,
                isPaused: !isPlaying,
                trackURI: trackURI, positionMS: 0, durationMS: 180_000, timestampMS: 0,
                shuffle: false, repeatTrack: false, repeatContext: false,
                isActiveDevice: activeID == "local"
            ),
            queue: nil
        )
    }
}

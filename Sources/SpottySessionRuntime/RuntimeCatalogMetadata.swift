import SpottyDomain
import SpottyRuntimeContracts

/// Owns browsing input and bounded playback retention. The complete immutable browsing lookup
/// remains available for newly observed URIs; only current/queue labels enter publications.
@SessionRuntimeActor
package final class RuntimeCatalogMetadata {
    package enum Source: CaseIterable { case nowPlaying, queue }
    private var tracks: [Source: [String: CatalogTrackMetadata]] = [:]
    private var retained: [Source: Set<String>] = [:]
    private var browsing: BrowsingMetadataSnapshot?
    package var changed: (() -> Void)?
    package private(set) var playbackTracks: [CatalogTrack] = []

    /// Account admission belongs to the runtime entrance. This owner rejects reordered snapshots
    /// and keeps their lookup directly, without copying or renormalizing an entire library.
    @discardableResult
    package func acceptBrowsing(_ snapshot: BrowsingMetadataSnapshot) -> Bool {
        if let browsing {
            guard snapshot.accountEpoch == browsing.accountEpoch, snapshot.revision >= browsing.revision else {
                return false
            }
            if snapshot.revision == browsing.revision { return true }
        }
        browsing = snapshot
        for target in Source.allCases {
            let wanted = retained[target] ?? Set(tracks[target]?.keys.map { $0 } ?? [])
            for uri in wanted {
                guard let entity = snapshot.tracks[uri] else { continue }
                tracks[target, default: [:]][uri] = entity.fillingMissingLinks(from: tracks[target]?[uri])
            }
        }
        refreshPublication()
        return true
    }

    package func knownTrack(for uri: String) -> CatalogTrack? { knownMetadata(for: uri)?.playbackTrack }

    package func displayInfo(for uri: String) -> (title: String, artist: String) {
        if let entity = knownMetadata(for: uri) { return (entity.title, entity.artist) }
        return ("Unknown track", uri.split(separator: ":").last.map(String.init) ?? uri)
    }

    package func replaceTracks(_ values: [CatalogTrack], from source: Source) {
        var replacement = Dictionary(
            values.map { track in
                (
                    track.uri,
                    CatalogTrackMetadata(track: track, requestedURI: track.uri)
                        .fillingMissingLinks(from: tracks[source]?[track.uri])
                )
            }, uniquingKeysWith: { _, latest in latest })
        for uri in retained[source] ?? [] where replacement[uri] == nil {
            replacement[uri] = tracks[source]?[uri]
        }
        guard tracks[source] != replacement else { return }
        tracks[source] = replacement
        refreshPublication()
    }

    package func retainTracks(from source: Source, for uris: Set<String>) {
        retained[source] = uris
        let replacement = Dictionary(
            uris.compactMap { uri in knownMetadata(for: uri).map { (uri, $0) } },
            uniquingKeysWith: { _, latest in latest })
        guard tracks[source] != replacement else { return }
        tracks[source] = replacement
        refreshPublication()
    }

    package func reset() {
        tracks = [:]
        retained = [:]
        browsing = nil
        refreshPublication()
    }

    private func knownMetadata(for uri: String) -> CatalogTrackMetadata? {
        var result: CatalogTrackMetadata?
        for source in Source.allCases {
            if let entity = tracks[source]?[uri] { result = entity.fillingMissingLinks(from: result) }
        }
        return browsing?.tracks[uri]?.fillingMissingLinks(from: result) ?? result
    }

    private func refreshPublication() {
        let uris = Set((tracks[.nowPlaying] ?? [:]).keys).union((tracks[.queue] ?? [:]).keys)
        let next = uris.sorted().compactMap { knownTrack(for: $0) }
        guard next != playbackTracks else { return }
        playbackTracks = next
        changed?()
    }
}

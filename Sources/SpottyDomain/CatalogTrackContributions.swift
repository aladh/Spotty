/// Source precedence and compatible link learning for one catalog's track contributions.
/// Preparing a replacement leaves the original readable until its owner commits the next value.
package struct CatalogTrackContributions: Sendable {
    package enum Source: Int, CaseIterable, Sendable {
        case playback
        case search
        case playlist
        case discography
        case album
        case library
    }

    package struct Replacement: Sendable {
        package let next: CatalogTrackContributions
        package let displayChangedURIs: [String]
        /// If browsing changed, invalidate the entire source delta, including hidden entries.
        package let browsingInvalidatedURIs: Set<String>
    }

    private typealias Lookup = [String: CatalogTrackMetadata]
    private static let browsingSources: [Source] = [.search, .playlist, .discography, .album, .library]
    private var bySource: [Source: Lookup] = [:]

    package init() {}

    package func replacing(_ tracks: [CatalogTrack], from source: Source) -> Replacement {
        let previous = bySource[source] ?? [:]
        // Duplicates keep the last row; each row borrows only from the previous source snapshot.
        let replacement = Dictionary(
            tracks.lazy.map {
                (
                    $0.uri,
                    CatalogTrackMetadata(track: $0, requestedURI: $0.uri)
                        .fillingMissingLinks(from: previous[$0.uri])
                )
            }, uniquingKeysWith: { _, latest in latest })
        var affected = Set<String>()
        for (uri, value) in replacement where previous[uri] != value { affected.insert(uri) }
        for uri in previous.keys where replacement[uri] == nil { affected.insert(uri) }
        var updated = self
        updated.bySource[source] = replacement
        return preparing(updated, affected: affected)
    }

    package func clearing() -> Replacement {
        preparing(Self(), affected: Set(bySource.values.flatMap(\.keys)))
    }

    package func displayTrack(for uri: String) -> CatalogTrackMetadata? {
        Self.track(for: uri, in: Source.allCases.lazy.compactMap { bySource[$0] })
    }

    package func browsingTrack(for uri: String) -> CatalogTrackMetadata? {
        Self.track(for: uri, in: Self.browsingSources.lazy.compactMap { bySource[$0] })
    }

    private func preparing(_ updated: Self, affected: Set<String>) -> Replacement {
        guard !affected.isEmpty else {
            return Replacement(next: self, displayChangedURIs: [], browsingInvalidatedURIs: [])
        }
        // Resolve the small source list once per batch; dictionary values share their storage.
        let oldDisplay = views(for: Source.allCases)
        let newDisplay = updated.views(for: Source.allCases)
        let displayChanged = affected.compactMap { uri in
            Self.track(for: uri, in: oldDisplay) != Self.track(for: uri, in: newDisplay) ? uri : nil
        }
        let oldBrowsing = views(for: Self.browsingSources)
        let newBrowsing = updated.views(for: Self.browsingSources)
        let browsingChanged = affected.contains { uri in
            Self.track(for: uri, in: oldBrowsing) != Self.track(for: uri, in: newBrowsing)
        }
        return Replacement(
            next: updated, displayChangedURIs: displayChanged,
            browsingInvalidatedURIs: browsingChanged ? affected : [])
    }

    private func views(for sources: [Source]) -> [Lookup] {
        sources.compactMap { source in
            guard let tracks = bySource[source], !tracks.isEmpty else { return nil }
            return tracks
        }
    }

    private static func track<Lookups: Sequence>(for uri: String, in lookups: Lookups) -> CatalogTrackMetadata?
    where Lookups.Element == Lookup {
        var result: CatalogTrackMetadata?
        for lookup in lookups {
            if let track = lookup[uri] { result = track.fillingMissingLinks(from: result) }
        }
        return result
    }
}

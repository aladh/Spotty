import Foundation
import SpottyDomain
import SpottyRuntimeContracts

package enum RuntimeFeedbackKind: Equatable, Sendable { case success, informational, failure, dismiss }

package struct RuntimeFeedbackMessage: Equatable, Sendable {
    package let revision: UInt64
    package let kind: RuntimeFeedbackKind
    package let text: String
}

/// A value publication. Nothing here lets a client dispatch directly into the engine or account.
package struct RuntimePresentation: Equatable, Sendable {
    package let revision: UInt64
    package let state: PlaybackState
    package let accountEpoch: UInt64
    package let engineGeneration: UInt64
    package let queueInspectorOrderingVersion: UInt64
    package let requiresReauthentication: Bool
    package let isTearingDown: Bool
    package let allowsCommands: Bool
    package let catalogAvailable: Bool
    package let history: [HistoryEntry]
    package let metadata: [CatalogTrack]
    package let feedback: RuntimeFeedbackMessage?
}

@SessionRuntimeActor
package final class RuntimeFeedback {
    package private(set) var message: RuntimeFeedbackMessage?
    private var revision: UInt64 = 0
    package var changed: (() -> Void)?

    package func success(_ text: String) { present(.success, text) }
    package func informational(_ text: String) { present(.informational, text) }
    package func failure(_ text: String) { present(.failure, text) }
    package func dismiss() { present(.dismiss, "") }

    private func present(_ kind: RuntimeFeedbackKind, _ text: String) {
        revision &+= 1
        message = RuntimeFeedbackMessage(revision: revision, kind: kind, text: text)
        changed?()
    }
}

@SessionRuntimeActor
package final class RuntimeHistory {
    package private(set) var entries: [HistoryEntry] = []
    package var changed: (() -> Void)?

    package func notePlayed(uri: String, title: String, artist: String, artworkURL: URL?, playedAt: Date) {
        guard uri.hasPrefix("spotify:track:") else { return }
        entries = PlaybackHistory.updated(
            entries, afterPlaying: uri,
            title: title.isEmpty ? uri.split(separator: ":").last.map(String.init) ?? uri : title,
            artist: artist, artworkURLString: artworkURL?.absoluteString, playedAt: playedAt)
        changed?()
    }

    package func applyMetadata(uri: String, title: String, artist: String, artworkURL: URL?) {
        entries = PlaybackHistory.withMetadata(
            entries, for: uri, title: title, artist: artist, artworkURLString: artworkURL?.absoluteString)
        changed?()
    }

    package func reset() { entries = []; changed?() }
}

/// Only the bounded entity labels relevant to playback live here. Browsing collection ordering,
/// ownership and mutations are never inferred from this metadata input.
@SessionRuntimeActor
package final class RuntimeCatalogMetadata {
    package enum Source: Int, CaseIterable { case nowPlaying, queue, browsing }
    private var tracks: [Source: [String: CatalogTrack]] = [:]
    private var retained: [Source: Set<String>] = [:]
    package var changed: (() -> Void)?

    package private(set) var playbackTracks: [CatalogTrack] = []

    private func refreshPublication() {
        let uris = Set((tracks[.nowPlaying] ?? [:]).keys).union((tracks[.queue] ?? [:]).keys)
        let next = uris.sorted().compactMap { knownTrack(for: $0) }
        guard next != playbackTracks else { return }
        playbackTracks = next
        changed?()
    }

    package func knownTrack(for uri: String) -> CatalogTrack? {
        for source in Source.allCases.reversed() {
            if let track = tracks[source]?[uri] { return track }
        }
        return nil
    }

    package func displayInfo(for uri: String) -> (title: String, artist: String) {
        if let track = knownTrack(for: uri) { return (track.title, track.artist) }
        return ("Unknown track", uri.split(separator: ":").last.map(String.init) ?? uri)
    }

    package func replaceTracks(_ values: [CatalogTrack], from source: Source) {
        // Occurrence identity and date belong to the browsing collection. Playback retains only
        // entity metadata, so identical labels from another occurrence do not cause publication.
        var replacement = Dictionary(
            values.map { track in
                let entity = CatalogTrack(
                    id: track.uri, uri: track.uri, title: track.title, artist: track.artist,
                    album: track.album, duration: track.duration, artworkURL: track.artworkURL,
                    addedAt: nil, artists: track.artists, albumItem: track.albumItem)
                return (track.uri, entity)
            }, uniquingKeysWith: { _, latest in latest })
        for uri in retained[source] ?? [] where replacement[uri] == nil {
            replacement[uri] = tracks[source]?[uri]
        }
        guard tracks[source] != replacement else { return }
        tracks[source] = replacement
        if source == .browsing {
            // A loaded page can improve labels for the retained queue/current track. Preserve
            // those labels after navigation replaces the page, without retaining its ordering
            // or treating its membership as playback authority.
            for target in [Source.queue, .nowPlaying] {
                let wanted = retained[target] ?? Set(tracks[target]?.keys.map { $0 } ?? [])
                for (uri, track) in replacement where wanted.contains(uri) {
                    tracks[target, default: [:]][uri] = track
                }
            }
        }
        refreshPublication()
    }

    package func retainTracks(from source: Source, for uris: Set<String>) {
        retained[source] = uris
        let replacement = Dictionary(
            uris.compactMap { uri in knownTrack(for: uri).map { (uri, $0) } },
            uniquingKeysWith: { _, latest in latest })
        guard tracks[source] != replacement else { return }
        tracks[source] = replacement
        refreshPublication()
    }

    package func reset() { tracks = [:]; retained = [:]; refreshPublication() }
}

@SessionRuntimeActor
package final class RuntimeCatalogState {
    package let metadata = RuntimeCatalogMetadata()
    package func reset() { metadata.reset() }
}

@SessionRuntimeActor
package final class RuntimeCatalogSession {
    package private(set) var accountEpoch: UInt64
    package private(set) var isAvailable: Bool

    package init(accountEpoch: UInt64, isAvailable: Bool) {
        self.accountEpoch = accountEpoch
        self.isAvailable = isAvailable
    }

    package func update(accountEpoch: UInt64, isAvailable: Bool) {
        self.accountEpoch = accountEpoch
        self.isAvailable = isAvailable
    }
}

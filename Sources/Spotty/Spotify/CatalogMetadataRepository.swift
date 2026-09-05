//
//  CatalogMetadataRepository.swift
//  Spotty
//
//  Session-scoped catalog lookup and track-attribute enrichment.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class CatalogMetadataRepository {
    enum TrackSource: Int, CaseIterable {
        case nowPlaying
        case queue
        case search
        case playlist
        case album
        case library
    }

    enum ItemSource: Int, CaseIterable {
        case library
        case home
        case search
    }

    private(set) var trackAttributes: [String: TrackAttributes] = [:]
    private(set) var trackAttributesRevision: UInt64 = 0
    private(set) var contentRevision: UInt64 = 0

    @ObservationIgnored private let attributesProvider: any TrackAttributesProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var tracksBySource: [TrackSource: [String: CatalogTrack]] = [:]
    @ObservationIgnored private var retainedTrackURIsBySource: [TrackSource: Set<String>] = [:]
    @ObservationIgnored private var itemsBySource: [ItemSource: [String: CatalogItem]] = [:]
    @ObservationIgnored private var requestsInFlight: Set<String> = []
    @ObservationIgnored private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestScope: UInt64 = 0
    @ObservationIgnored private var requestSessionRevision: UInt64 = 0
    @ObservationIgnored private var contentEpoch: UInt64 = 0

    init(
        attributesProvider: any TrackAttributesProviding,
        session: CatalogSessionAvailability
    ) {
        self.attributesProvider = attributesProvider
        self.session = session
    }

    func reset() {
        requestScope &+= 1
        enrichmentTasks.values.forEach { $0.cancel() }
        enrichmentTasks.removeAll(keepingCapacity: false)
        requestsInFlight.removeAll(keepingCapacity: false)
        requestSessionRevision = session.snapshot.revision
        tracksBySource.removeAll(keepingCapacity: false)
        retainedTrackURIsBySource.removeAll(keepingCapacity: false)
        itemsBySource.removeAll(keepingCapacity: false)
        trackAttributes.removeAll(keepingCapacity: false)
        trackAttributesRevision &+= 1
        contentEpoch = session.accountEpoch
        contentRevision &+= 1
    }

    func replaceTracks(_ tracks: [CatalogTrack], from source: TrackSource) {
        guard acceptCurrentSessionWrite() else { return }
        var replacement = Dictionary(
            tracks.lazy.map { ($0.uri, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        // Queue metadata is deliberately retained only for the current ordering. Preserve those
        // bounded entries when an ordering-only snapshot arrives, and let any catalog page that
        // knows one of the queued uris enrich it before that page is replaced.
        if let retainedURIs = retainedTrackURIsBySource[source] {
            for (uri, track) in tracksBySource[source] ?? [:]
            where retainedURIs.contains(uri) && replacement[uri] == nil {
                replacement[uri] = track
            }
        }
        tracksBySource[source] = replacement
        if source != .nowPlaying { promoteRetainedTracks(replacement.values, excluding: source) }
        contentRevision &+= 1
    }

    func cacheTracks(_ tracks: [CatalogTrack], from source: TrackSource) {
        guard !tracks.isEmpty, acceptCurrentSessionWrite() else { return }
        var updated = tracksBySource[source] ?? [:]
        for track in tracks where !track.uri.isEmpty {
            updated[track.uri] = track
        }
        tracksBySource[source] = updated
        if source != .nowPlaying { promoteRetainedTracks(tracks, excluding: source) }
        contentRevision &+= 1
    }

    func retainTracks(from source: TrackSource, for uris: Set<String>) {
        guard acceptCurrentSessionWrite() else { return }
        retainedTrackURIsBySource[source] = uris
        var retained = (tracksBySource[source] ?? [:]).filter { uris.contains($0.key) }
        for uri in uris where retained[uri] == nil {
            retained[uri] = knownTrack(for: uri, excluding: source)
        }
        tracksBySource[source] = retained
        contentRevision &+= 1
    }

    func replaceItems(_ items: [CatalogItem], from source: ItemSource) {
        guard acceptCurrentSessionWrite() else { return }
        itemsBySource[source] = Dictionary(
            items.lazy.map { ($0.uri, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        contentRevision &+= 1
    }

    func cacheItems(_ items: [CatalogItem], from source: ItemSource) {
        guard !items.isEmpty, acceptCurrentSessionWrite() else { return }
        var updated = itemsBySource[source] ?? [:]
        for item in items where !item.uri.isEmpty {
            updated[item.uri] = item
        }
        itemsBySource[source] = updated
        contentRevision &+= 1
    }

    /// Higher-value catalog sources win over provisional queue metadata.
    func knownTrack(for uri: String) -> CatalogTrack? {
        _ = contentRevision
        guard contentEpoch == session.accountEpoch else { return nil }
        return TrackSource.allCases
            .sorted { $0.rawValue > $1.rawValue }
            .lazy
            .compactMap { self.tracksBySource[$0]?[uri] }
            .first
    }

    func knownItem(for uri: String) -> CatalogItem? {
        _ = contentRevision
        guard contentEpoch == session.accountEpoch else { return nil }
        return ItemSource.allCases
            .sorted { $0.rawValue > $1.rawValue }
            .lazy
            .compactMap { self.itemsBySource[$0]?[uri] }
            .first
    }

    func displayInfo(for uri: String) -> (title: String, artist: String) {
        if let track = knownTrack(for: uri) {
            return (track.title, track.artist)
        }
        if let item = knownItem(for: uri) {
            return (item.title, item.subtitle)
        }
        let id = uri.split(separator: ":").last.map(String.init) ?? uri
        return ("Unknown track", id)
    }

    // MARK: - Track attribute enrichment

    private static let batchSize = 100
    private static let requestLimit = 1_000
    private static let cacheLimit = 20_000

    func loadTrackAttributes(for tracks: [CatalogTrack]) {
        let sessionSnapshot = session.snapshot
        guard sessionSnapshot.isAvailable else { return }
        if requestSessionRevision != sessionSnapshot.revision {
            requestScope &+= 1
            enrichmentTasks.values.forEach { $0.cancel() }
            enrichmentTasks.removeAll(keepingCapacity: false)
            requestsInFlight.removeAll(keepingCapacity: false)
            requestSessionRevision = sessionSnapshot.revision
        }
        let scope = requestScope
        let excluded = Set(trackAttributes.keys).union(requestsInFlight)
        let uris = Self.attributeURIsToRequest(
            from: tracks,
            excluding: excluded,
            limit: Self.requestLimit
        )
        requestsInFlight.formUnion(uris)

        for offset in stride(from: 0, to: uris.count, by: Self.batchSize) {
            let batch = Array(uris[offset..<min(offset + Self.batchSize, uris.count)])
            let taskID = UUID()
            enrichmentTasks[taskID] = Task { [weak self] in
                guard let self else { return }
                await self.fetchTrackAttributes(
                    batch,
                    scope: scope,
                    sessionSnapshot: sessionSnapshot,
                    taskID: taskID
                )
            }
        }
    }

    nonisolated static func attributeURIsToRequest(
        from tracks: [CatalogTrack],
        excluding excluded: Set<String>,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = excluded
        var wanted: [String] = []
        wanted.reserveCapacity(min(tracks.count, limit))

        for track in tracks where track.uri.hasPrefix("spotify:track:") {
            guard wanted.count < limit else { break }
            if seen.insert(track.uri).inserted {
                wanted.append(track.uri)
            }
        }
        return wanted
    }

    private func fetchTrackAttributes(
        _ uris: [String],
        scope: UInt64,
        sessionSnapshot: CatalogSessionSnapshot,
        taskID: UUID
    ) async {
        defer {
            enrichmentTasks[taskID] = nil
            if scope == requestScope {
                requestsInFlight.subtract(uris)
            }
        }

        do {
            let fetched = try await attributesProvider.attributes(for: uris)
            guard isCurrent(scope, sessionSnapshot: sessionSnapshot) else { return }
            let addedAttributes = fetched.keys.contains { trackAttributes[$0] == nil }
            trackAttributes.merge(fetched) { current, _ in current }
            trimAttributeCache(preserving: Set(fetched.keys))
            if addedAttributes {
                trackAttributesRevision &+= 1
            }
        } catch {
            guard !isCancellation(error), isCurrent(scope, sessionSnapshot: sessionSnapshot) else { return }
            debugLog(
                "CatalogMetadataRepository",
                "Track attributes failed; error=\(String(describing: type(of: error)))"
            )
        }
    }

    private func isCurrent(
        _ scope: UInt64,
        sessionSnapshot: CatalogSessionSnapshot
    ) -> Bool {
        scope == requestScope && session.snapshot == sessionSnapshot && sessionSnapshot.isAvailable
    }

    private func acceptCurrentSessionWrite() -> Bool {
        let snapshot = session.snapshot
        guard snapshot.isAvailable else { return false }
        if contentEpoch != snapshot.accountEpoch {
            tracksBySource.removeAll(keepingCapacity: false)
            retainedTrackURIsBySource.removeAll(keepingCapacity: false)
            itemsBySource.removeAll(keepingCapacity: false)
            trackAttributes.removeAll(keepingCapacity: false)
            trackAttributesRevision &+= 1
            contentEpoch = snapshot.accountEpoch
        }
        return true
    }

    private func promoteRetainedTracks(
        _ tracks: some Sequence<CatalogTrack>,
        excluding source: TrackSource
    ) {
        let candidates = Array(tracks)
        for retainedSource in TrackSource.allCases where retainedSource != source {
            guard let wanted = retainedTrackURIsBySource[retainedSource], !wanted.isEmpty else { continue }
            var retained = tracksBySource[retainedSource] ?? [:]
            for track in candidates where wanted.contains(track.uri) {
                retained[track.uri] = track
            }
            tracksBySource[retainedSource] = retained
        }
    }

    private func knownTrack(
        for uri: String,
        excluding source: TrackSource
    ) -> CatalogTrack? {
        TrackSource.allCases
            .filter { $0 != source }
            .sorted { $0.rawValue > $1.rawValue }
            .lazy
            .compactMap { self.tracksBySource[$0]?[uri] }
            .first
    }

    private func trimAttributeCache(preserving preserved: Set<String>) {
        guard trackAttributes.count > Self.cacheLimit else { return }
        let excess = trackAttributes.count - Self.cacheLimit
        let victims = trackAttributes.keys.lazy
            .filter { !preserved.contains($0) }
            .prefix(excess)
        for uri in Array(victims) {
            trackAttributes.removeValue(forKey: uri)
        }
    }
}

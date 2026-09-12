//
//  CatalogMetadataRepository.swift
//  Spotty
//
//  Session-scoped catalog lookup and track-attribute enrichment.
//

import SpottyDomain
import Foundation
import Observation

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
    /// Changes only when the effective genuine browsing labels exported to the runtime change.
    /// Playback publications must not feed themselves back as higher-priority browsing input.
    @ObservationIgnored private(set) var runtimeTracksRevision: UInt64 = 0

    private static let runtimeTrackSources: [TrackSource] = [.search, .playlist, .album, .library]

    @ObservationIgnored private let contentObservation = ObservationRegistrar()
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
        clearContent(for: session.accountEpoch)
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
        let affectedURIs = Set(tracksBySource[source]?.keys.map { $0 } ?? []).union(replacement.keys)
        var updated = tracksBySource
        updated[source] = replacement
        if source != .nowPlaying {
            promoteRetainedTracks(replacement.values, excluding: source, in: &updated)
        }
        publishTracks(updated, affectedURIs: affectedURIs)
    }

    func cacheTracks(_ tracks: [CatalogTrack], from source: TrackSource) {
        guard !tracks.isEmpty, acceptCurrentSessionWrite() else { return }
        var updated = tracksBySource
        for track in tracks where !track.uri.isEmpty {
            updated[source, default: [:]][track.uri] = track
        }
        if source != .nowPlaying { promoteRetainedTracks(tracks, excluding: source, in: &updated) }
        publishTracks(updated, affectedURIs: Set(tracks.map(\.uri)))
    }

    func retainTracks(from source: TrackSource, for uris: Set<String>) {
        guard acceptCurrentSessionWrite() else { return }
        retainedTrackURIsBySource[source] = uris
        var retained = (tracksBySource[source] ?? [:]).filter { uris.contains($0.key) }
        for uri in uris where retained[uri] == nil {
            retained[uri] = Self.track(for: uri, in: tracksBySource, excluding: source)
        }
        let affectedURIs = Set(tracksBySource[source]?.keys.map { $0 } ?? []).union(uris)
        var updated = tracksBySource
        updated[source] = retained
        publishTracks(updated, affectedURIs: affectedURIs)
    }

    func replaceItems(_ items: [CatalogItem], from source: ItemSource) {
        guard acceptCurrentSessionWrite() else { return }
        var updated = itemsBySource
        updated[source] = Dictionary(
            items.lazy.map { ($0.uri, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let affectedURIs = Set(itemsBySource[source]?.keys.map { $0 } ?? []).union(items.map(\.uri))
        publishItems(updated, affectedURIs: affectedURIs)
    }

    func cacheItems(_ items: [CatalogItem], from source: ItemSource) {
        guard !items.isEmpty, acceptCurrentSessionWrite() else { return }
        var updated = itemsBySource
        for item in items where !item.uri.isEmpty {
            updated[source, default: [:]][item.uri] = item
        }
        publishItems(updated, affectedURIs: Set(items.map(\.uri)))
    }

    /// Genuine browsing input only. Runtime-owned queue and Now Playing publications are never
    /// re-exported as browsing authority. Callers use runtimeTracksRevision to avoid rebuilding an
    /// unchanged library during playback timing updates.
    var runtimeTracks: [String: CatalogTrack] {
        guard contentEpoch == session.accountEpoch else { return [:] }
        var result: [String: CatalogTrack] = [:]
        for source in Self.runtimeTrackSources {
            result.merge(tracksBySource[source] ?? [:]) { _, higherPriority in higherPriority }
        }
        return result
    }

    func knownTrack(for uri: String) -> CatalogTrack? {
        self[track: uri]
    }

    func knownItem(for uri: String) -> CatalogItem? {
        self[item: uri]
    }

    // Subscript key paths carry the URI, including misses, without storing per-URI observer boxes
    // or a second metadata cache. Track and item readers subscribe independently.
    private subscript(track uri: String) -> CatalogTrack? {
        contentObservation.access(self, keyPath: \.[track: uri])
        guard contentEpoch == session.accountEpoch else { return nil }
        return Self.track(for: uri, in: tracksBySource)
    }

    private subscript(item uri: String) -> CatalogItem? {
        contentObservation.access(self, keyPath: \.[item: uri])
        guard contentEpoch == session.accountEpoch else { return nil }
        return Self.item(for: uri, in: itemsBySource)
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
            clearContent(for: snapshot.accountEpoch)
        }
        return true
    }

    private func clearContent(for epoch: UInt64) {
        publishTracks([:], affectedURIs: Set(tracksBySource.values.flatMap(\.keys)))
        publishItems([:], affectedURIs: Set(itemsBySource.values.flatMap(\.keys)))
        retainedTrackURIsBySource.removeAll(keepingCapacity: false)
        trackAttributes.removeAll(keepingCapacity: false)
        trackAttributesRevision &+= 1
        contentEpoch = epoch
    }

    private func publishTracks(
        _ updated: [TrackSource: [String: CatalogTrack]],
        affectedURIs: Set<String>
    ) {
        let changedURIs = affectedURIs.filter {
            Self.track(for: $0, in: tracksBySource) != Self.track(for: $0, in: updated)
        }
        let changedRuntimeTracks = affectedURIs.contains {
            Self.runtimeTrack(for: $0, in: tracksBySource) != Self.runtimeTrack(for: $0, in: updated)
        }
        // Announce changes before committing the whole source snapshot so each batch remains
        // atomic to readers. Hidden source updates still commit, but do not wake unchanged lookups.
        for uri in changedURIs { contentObservation.willSet(self, keyPath: \.[track: uri]) }
        tracksBySource = updated
        if changedRuntimeTracks { runtimeTracksRevision &+= 1 }
        for uri in changedURIs { contentObservation.didSet(self, keyPath: \.[track: uri]) }
    }

    private func publishItems(
        _ updated: [ItemSource: [String: CatalogItem]],
        affectedURIs: Set<String>
    ) {
        let changedURIs = affectedURIs.filter {
            Self.item(for: $0, in: itemsBySource) != Self.item(for: $0, in: updated)
        }
        for uri in changedURIs { contentObservation.willSet(self, keyPath: \.[item: uri]) }
        itemsBySource = updated
        for uri in changedURIs { contentObservation.didSet(self, keyPath: \.[item: uri]) }
    }

    private func promoteRetainedTracks(
        _ tracks: some Sequence<CatalogTrack>,
        excluding source: TrackSource,
        in updated: inout [TrackSource: [String: CatalogTrack]]
    ) {
        let candidates = Array(tracks)
        for retainedSource in TrackSource.allCases where retainedSource != source {
            guard let wanted = retainedTrackURIsBySource[retainedSource], !wanted.isEmpty else { continue }
            var retained = updated[retainedSource] ?? [:]
            for track in candidates where wanted.contains(track.uri) {
                retained[track.uri] = track
            }
            updated[retainedSource] = retained
        }
    }

    private static func track(
        for uri: String,
        in tracks: [TrackSource: [String: CatalogTrack]],
        excluding source: TrackSource? = nil
    ) -> CatalogTrack? {
        for candidate in TrackSource.allCases.reversed() where candidate != source {
            if let track = tracks[candidate]?[uri] { return track }
        }
        return nil
    }

    private static func runtimeTrack(
        for uri: String,
        in tracks: [TrackSource: [String: CatalogTrack]]
    ) -> CatalogTrack? {
        for source in runtimeTrackSources.reversed() {
            if let track = tracks[source]?[uri] { return track }
        }
        return nil
    }

    private static func item(
        for uri: String,
        in items: [ItemSource: [String: CatalogItem]]
    ) -> CatalogItem? {
        for source in ItemSource.allCases.reversed() {
            if let item = items[source]?[uri] { return item }
        }
        return nil
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

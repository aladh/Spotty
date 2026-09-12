//
//  PlaylistStore.swift
//  Spotty
//
//  Selected-playlist detail state.
//

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

@MainActor
@Observable
final class PlaylistStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    private struct Snapshot {
        let item: CatalogItem?
        let collection: CatalogTrackCollection
        let duration: TimeInterval
        let description: String
        let ownerURI: String?
        let error: String?
        let freshness: CatalogFreshness
    }

    private(set) var item: CatalogItem?
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var totalDuration: TimeInterval = 0
    var description = ""
    private(set) var loadedURI: String?
    private(set) var ownerURI: String?
    var isLoading = false
    var error: String?
    private(set) var isShowingCachedContent = false
    private(set) var freshness: CatalogFreshness = .current
    var canEditLoadedContent: Bool {
        loadedSessionSnapshot == session.snapshot && session.isAvailable
            && freshness.isCurrent && error == nil && !isLoading
    }

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation
    @ObservationIgnored private var contentEpoch: UInt64
    @ObservationIgnored private var hasLoadedContent = false
    @ObservationIgnored private var loadedSessionSnapshot: CatalogSessionSnapshot?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        contentEpoch = session.accountEpoch
        retained = RetainedCatalogRoutes(session: session)
        entityObservation = CatalogEntityObservation(provider: provider, session: session)
        flight = Flight(session: session, join: .joinMatchingKey, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        flight.reset()
        retained.reset()
        entityObservation.reset()
        contentEpoch = session.accountEpoch
        isShowingCachedContent = false
        freshness = .current
        loadedSessionSnapshot = nil
        hasLoadedContent = false
        replaceTracks([])
        description = ""
        loadedURI = nil
        item = nil
        ownerURI = nil
        isLoading = false
        error = nil
        metadata.replaceTracks([], from: .playlist)
    }

    /// Keeps `loadedURI` and `tracks` paired. Production loading still goes through `load(_:)`.
    func replaceLoadedPlaylist(uri: String, tracks: [CatalogTrack]) {
        if loadedURI != uri {
            loadedSessionSnapshot = nil
        }
        loadedURI = uri
        hasLoadedContent = true
        replaceTracks(tracks)
        // Optimistic/test replacement is not a freshly validated server snapshot.
        retained.remove(uri)
        updateEntityObservation()
    }

    func invalidateRetainedPlaylist(_ uri: String) {
        retained.remove(uri)
        updateEntityObservation()
        guard loadedURI == uri else { return }
        loadedSessionSnapshot = nil
        isShowingCachedContent = hasLoadedContent
    }

    func prepare(_ item: CatalogItem) {
        guard item.kind == .playlist else { return }
        if contentEpoch != session.accountEpoch { reset() }
        if loadedURI != item.uri { restore(item) }
        updateEntityObservation()
    }

    func load(_ item: CatalogItem, force: Bool = false) async {
        let currentSession = session.snapshot
        guard item.kind == .playlist else { return }
        prepare(item)
        guard currentSession.isAvailable else {
            isShowingCachedContent = hasLoadedContent
            return
        }
        if loadedURI == item.uri,
            loadedSessionSnapshot == currentSession,
            error == nil,
            freshness.isCurrent,
            !force
        {
            return
        }
        let handle: Flight.Handle
        switch flight.admit(item.uri, force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
            return
        case let .start(started):
            handle = started
        }

        // A retry keeps prior refresh failure visible until a current read succeeds.
        if !hasLoadedContent { error = nil }
        isLoading = true
        isShowingCachedContent = hasLoadedContent
        defer {
            if flight.owns(handle) {
                isLoading = false
                isShowingCachedContent =
                    hasLoadedContent
                    && (loadedSessionSnapshot != session.snapshot || error != nil || !freshness.isCurrent)
            }
        }

        guard let id = SpotifyURI.id(from: item.uri, kind: "playlist") else {
            error = "Spotify returned an invalid playlist address."
            flight.abandonUnstarted(handle)
            return
        }

        await flight.run(handle) { [weak self] in
            guard let self else { return }
            await self.performLoad(item, id: id, handle: handle)
        }
    }

    private func performLoad(
        _ item: CatalogItem,
        id: String,
        handle: Flight.Handle
    ) async {
        do {
            let playlist = try await provider.playlist(id: id)
            guard isCurrent(handle) else { return }
            // A page from the previous query may already have returned before a newer full
            // result completed. Retire that publication scope before replacing its rows.
            entityObservation.reset()
            error = nil
            self.item = playlist.item?.uri == item.uri ? (playlist.item ?? item) : item
            description = playlist.description
            ownerURI = playlist.ownerURI ?? item.ownerURI
            replaceTracks(playlist.tracks)
            loadedSessionSnapshot = session.snapshot
            hasLoadedContent = true
            freshness = playlist.freshness
            isShowingCachedContent = !freshness.isCurrent
            retainCurrent()
            metadata.replaceTracks(tracks, from: .playlist)
            metadata.loadTrackAttributes(for: tracks)
        } catch {
            guard flight.shouldReport(error, for: handle), loadedURI == handle.key else { return }
            self.error = CatalogErrorPresentation.message(for: error)
            isShowingCachedContent = hasLoadedContent
            // A failed refresh must not become a fresh successful cache hit on revisit.
            retained.markStale(item.uri)
        }
    }

    private func restore(_ item: CatalogItem) {
        flight.reset()
        loadedURI = item.uri
        self.item = item
        error = nil
        isLoading = false
        if let entry = retained.entry(for: item.uri) {
            self.item = entry.value.item ?? item
            trackCollection = entry.value.collection
            totalDuration = entry.value.duration
            description = entry.value.description
            ownerURI = entry.value.ownerURI
            error = entry.value.error
            freshness = entry.value.freshness
            loadedSessionSnapshot = entry.needsRefresh ? nil : entry.session
            hasLoadedContent = true
            isShowingCachedContent =
                entry.needsRefresh || entry.session != session.snapshot
                || error != nil || !freshness.isCurrent
            metadata.replaceTracks(tracks, from: .playlist)
        } else {
            loadedSessionSnapshot = nil
            hasLoadedContent = false
            replaceTracks([])
            description = ""
            ownerURI = item.ownerURI
            freshness = .current
            isShowingCachedContent = false
            metadata.replaceTracks([], from: .playlist)
        }
    }

    private func retainCurrent() {
        guard let loadedURI, let loadedSessionSnapshot else { return }
        retained.store(
            Snapshot(
                item: item, collection: trackCollection, duration: totalDuration, description: description,
                ownerURI: ownerURI, error: error, freshness: freshness),
            for: loadedURI, cost: tracks.count, snapshot: loadedSessionSnapshot
        )
        updateEntityObservation()
    }

    private func updateEntityObservation() {
        let uris = Set(tracks.map(\.uri)).union(retained.values.flatMap { $0.collection.tracks.map(\.uri) })
        entityObservation.update(uris: uris) { [weak self] entities in
            self?.applyEntityMetadata(entities)
        }
    }

    private func applyEntityMetadata(_ entities: [String: CatalogTrack]) {
        guard !entities.isEmpty else { return }
        let currentVersion = trackCollection.version
        let currentUpdate = CatalogTrackMetadata.applying(entities, to: trackCollection)
        retained.updateValues { snapshot in
            let updated =
                snapshot.collection.version == currentVersion
                ? currentUpdate : CatalogTrackMetadata.applying(entities, to: snapshot.collection)
            guard let updated else { return snapshot }
            return Snapshot(
                item: snapshot.item, collection: updated,
                duration: Self.duration(of: updated.tracks), description: snapshot.description,
                ownerURI: snapshot.ownerURI, error: snapshot.error, freshness: snapshot.freshness)
        }
        guard let currentUpdate else { return }
        trackCollection = currentUpdate
        totalDuration = Self.duration(of: currentUpdate.tracks)
        metadata.replaceTracks(tracks, from: .playlist)
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        loadedURI == handle.key && flight.isCurrent(handle)
    }

    private func replaceTracks(_ tracks: [CatalogTrack]) {
        trackCollection.replace(tracks)
        totalDuration = Self.duration(of: tracks)
    }

    private static func duration(of tracks: [CatalogTrack]) -> TimeInterval {
        tracks.reduce(0) { total, track in
            total + TimeInterval(roundedCatalogDurationSeconds(track.duration))
        }
    }
}

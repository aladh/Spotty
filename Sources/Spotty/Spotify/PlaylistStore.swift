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
    var playbackContents: CatalogPlaylistContents? {
        CatalogPlaylistContents(uri: loadedURI, accountEpoch: contentEpoch, collection: trackCollection)
    }
    private(set) var totalDuration: TimeInterval = 0
    private(set) var description = ""
    private(set) var loadedURI: String?
    private(set) var ownerURI: String?
    private var loadState = CatalogLoadState()
    var isLoading: Bool { loadState.isLoading }
    var isLoadingInitialContent: Bool { isLoading && !hasLoadedContent }
    var error: String? { loadState.error }
    var isShowingCachedContent: Bool { loadState.isShowingSavedContent(in: session.snapshot) }
    var freshness: CatalogFreshness { loadState.freshness }
    var canEditLoadedContent: Bool {
        loadState.isCurrent(in: session.snapshot)
    }

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation
    @ObservationIgnored private var contentEpoch: UInt64
    var hasLoadedContent: Bool { loadState.hasContent }

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
        loadState = CatalogLoadState()
        replaceTracks([])
        description = ""
        loadedURI = nil
        item = nil
        ownerURI = nil
        metadata.replaceTracks([], from: .playlist)
    }

    /// Keeps `loadedURI` and `tracks` paired. Production loading still goes through `load(_:)`.
    func replaceLoadedPlaylist(uri: String, tracks: [CatalogTrack]) {
        loadedURI = uri
        loadState.receive(session: nil)
        replaceTracks(tracks)
        // Optimistic/test replacement is not a freshly validated server snapshot.
        retained.remove(uri)
        updateEntityObservation()
    }

    func invalidateRetainedPlaylist(_ uri: String) {
        retained.remove(uri)
        updateEntityObservation()
        guard loadedURI == uri else { return }
        loadState.markStale()
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
            loadState.markStale()
            return
        }
        if loadedURI == item.uri, loadState.isCurrent(in: currentSession), !force {
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
        loadState.begin()
        retained.markStale(item.uri)
        defer { if flight.owns(handle) { loadState.finish() } }

        guard let id = SpotifyURI.id(from: item.uri, kind: "playlist") else {
            loadState.fail(message: "Spotify returned an invalid playlist address.")
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
            if !hasLoadedContent, let cached = try await provider.cachedPlaylist(id: id) {
                guard isCurrent(handle) else { return }
                apply(cached, selected: item)
            }
            guard isCurrent(handle) else { return }
            let playlist = try await provider.playlist(id: id)
            guard isCurrent(handle) else { return }
            apply(playlist, selected: item)
        } catch {
            guard flight.shouldReport(error, for: handle), loadedURI == handle.key else { return }
            if loadState.fail(error) {
                let refusal = loadState
                reset()
                prepare(item)
                loadState = refusal
            }
            // A failed refresh must not become a fresh successful cache hit on revisit.
            retained.markStale(item.uri)
        }
    }

    private func apply(_ playlist: CatalogPlaylistSnapshot, selected: CatalogItem) {
        // Retire any page from the previous collection before publishing its replacement.
        entityObservation.reset()
        item = playlist.item?.uri == selected.uri ? (playlist.item ?? selected) : selected
        description = playlist.description
        loadState.receive(session: session.snapshot, freshness: playlist.freshness)
        ownerURI = freshness.isCurrent ? (playlist.ownerURI ?? selected.ownerURI) : nil
        replaceTracks(playlist.tracks)
        retainCurrent()
        metadata.replaceTracks(tracks, from: .playlist)
    }

    private func restore(_ item: CatalogItem) {
        flight.reset()
        loadedURI = item.uri
        self.item = item
        loadState = CatalogLoadState()
        if let entry = retained.entry(for: item.uri) {
            self.item = entry.value.item ?? item
            trackCollection = entry.value.collection
            totalDuration = entry.value.duration
            description = entry.value.description
            ownerURI = entry.value.ownerURI
            loadState.restore(
                session: entry.session, freshness: entry.value.freshness,
                needsRefresh: entry.needsRefresh, error: entry.value.error)
            metadata.replaceTracks(tracks, from: .playlist)
        } else {
            replaceTracks([])
            description = ""
            ownerURI = item.ownerURI
            metadata.replaceTracks([], from: .playlist)
        }
    }

    private func retainCurrent() {
        guard let loadedURI, let loadedSessionSnapshot = loadState.session else { return }
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

    private func applyEntityMetadata(_ entities: [String: CatalogTrackMetadata]) {
        guard !entities.isEmpty else { return }
        let currentVersion = trackCollection.version
        let currentUpdate = trackCollection.applyingMetadata(entities)
        retained.updateValues { snapshot in
            let updated =
                snapshot.collection.version == currentVersion
                ? currentUpdate : snapshot.collection.applyingMetadata(entities)
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

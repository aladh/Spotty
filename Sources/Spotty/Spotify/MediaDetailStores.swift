// Account- and selection-scoped album and artist browsing state.

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

@MainActor
@Observable
final class AlbumDetailStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    private struct Snapshot {
        let item: CatalogItem
        let collection: CatalogTrackCollection
        let releaseDate: String
        let playCounts: [String: Int64]
        let artists: [CatalogItem]
        let freshness: CatalogFreshness
    }

    private(set) var item: CatalogItem?
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var releaseDate = ""
    private(set) var playCounts: [String: Int64] = [:]
    private(set) var artists: [CatalogItem] = []
    private var loadState = CatalogLoadState()
    var isLoading: Bool { loadState.isLoading }
    var isLoadingInitialContent: Bool { isLoading && !hasLoadedContent }
    var error: String? { loadState.error }
    var isShowingCachedContent: Bool { loadState.isShowingSavedContent(in: session.snapshot) }
    var freshness: CatalogFreshness { loadState.freshness }

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation
    @ObservationIgnored private var contentEpoch: UInt64
    var hasLoadedContent: Bool { loadState.hasContent }

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
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
        item = nil
        trackCollection.replace([])
        releaseDate = ""
        playCounts = [:]
        artists = []
    }

    func prepare(_ selected: CatalogItem) {
        guard selected.kind == .album else { return }
        if contentEpoch != session.accountEpoch { reset() }
        if item?.uri != selected.uri { restore(selected) }
        updateEntityObservation()
    }

    func load(_ selected: CatalogItem, force: Bool = false) async {
        guard selected.kind == .album else { return }
        prepare(selected)
        guard session.isAvailable else {
            loadState.markStale()
            return
        }
        if loadState.isCurrent(in: session.snapshot), !force { return }
        switch flight.admit(selected.uri, force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            loadState.begin()
            retained.markStale(selected.uri)
            defer { if flight.owns(handle) { loadState.finish() } }
            guard let id = SpotifyURI.id(from: selected.uri, kind: "album") else {
                loadState.fail(message: "Spotify returned an invalid album address.")
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                do {
                    if !hasLoadedContent, let cached = try await provider.cachedAlbum(id: id) {
                        guard self.isCurrent(handle) else { return }
                        apply(cached, selected: selected, handle: handle)
                    }
                    guard self.isCurrent(handle) else { return }
                    let album = try await provider.album(id: id)
                    guard self.isCurrent(handle) else { return }
                    apply(album, selected: selected, handle: handle)
                } catch {
                    guard self.flight.shouldReport(error, for: handle), item?.uri == handle.key else { return }
                    if loadState.fail(error) {
                        let refusal = loadState
                        reset()
                        prepare(selected)
                        loadState = refusal
                    }
                    retained.markStale(selected.uri)
                }
            }
        }
    }

    private func apply(_ album: CatalogAlbumSnapshot, selected: CatalogItem, handle: Flight.Handle) {
        entityObservation.reset()
        item = album.item?.uri == selected.uri ? (album.item ?? selected) : selected
        trackCollection.replace(album.tracks)
        releaseDate = album.releaseDate
        playCounts = album.playCounts ?? [:]
        artists = album.artists ?? []
        loadState.receive(session: session.snapshot, freshness: album.freshness)
        retained.store(
            Snapshot(
                item: item ?? selected, collection: trackCollection, releaseDate: releaseDate,
                playCounts: playCounts, artists: artists, freshness: freshness),
            for: selected.uri, cost: tracks.count, snapshot: handle.sessionSnapshot)
        updateEntityObservation()
        metadata.replaceTracks(tracks, from: .album)
    }

    private func restore(_ selected: CatalogItem) {
        flight.reset()
        item = selected
        loadState = CatalogLoadState()
        if let cached = retained.entry(for: selected.uri) {
            item = cached.value.item
            trackCollection = cached.value.collection
            releaseDate = cached.value.releaseDate
            playCounts = cached.value.playCounts
            artists = cached.value.artists
            loadState.restore(
                session: cached.session, freshness: cached.value.freshness, needsRefresh: cached.needsRefresh)
            metadata.replaceTracks(tracks, from: .album)
        } else {
            trackCollection.replace([])
            releaseDate = ""
            playCounts = [:]
            artists = []

            metadata.replaceTracks([], from: .album)
        }
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
                item: snapshot.item, collection: updated, releaseDate: snapshot.releaseDate,
                playCounts: snapshot.playCounts, artists: snapshot.artists,
                freshness: snapshot.freshness)
        }
        guard let currentUpdate else { return }
        trackCollection = currentUpdate
        metadata.replaceTracks(tracks, from: .album)
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        item?.uri == handle.key && flight.isCurrent(handle)
    }
}

@MainActor
@Observable
final class ArtistDetailStore {
    /// Separate instances retain the overview and complete discography independently.
    enum Content: CaseIterable, Sendable { case overview, discography }

    private typealias Flight = AccountScopedSingleFlight<String>

    private struct Snapshot {
        let item: CatalogItem
        let releases: [CatalogItem]
        let freshness: CatalogFreshness
        let overview: CatalogArtistOverview?
        let releaseKinds: [String: CatalogArtistReleaseKind]
        let releaseDates: [String: String]
        let popularTracks: CatalogTrackCollection
        let popularPreview: CatalogTrackCollection
    }

    private(set) var item: CatalogItem?
    private(set) var releases: [CatalogItem] = []
    private(set) var overview: CatalogArtistOverview?
    private(set) var releaseKinds: [String: CatalogArtistReleaseKind] = [:]
    private(set) var releaseDates: [String: String] = [:]
    private(set) var popularTracks = CatalogTrackCollection()
    private(set) var popularPreview = CatalogTrackCollection()
    private(set) var artistTracks: [String: CatalogArtistPopularTrack] = [:]
    private var loadState = CatalogLoadState()
    var isLoading: Bool { loadState.isLoading }
    var error: String? { loadState.error }
    var isShowingCachedContent: Bool { loadState.isShowingSavedContent(in: session.snapshot) }
    var freshness: CatalogFreshness { loadState.freshness }

    @ObservationIgnored private let content: Content
    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private var contentEpoch: UInt64
    private var hasLoadedContent: Bool { loadState.hasContent }

    init(provider: any CatalogProviding, session: CatalogSessionAvailability, content: Content = .overview) {
        self.content = content
        self.provider = provider
        self.session = session
        contentEpoch = session.accountEpoch
        retained = RetainedCatalogRoutes(session: session)
        flight = Flight(session: session, join: .joinMatchingKey, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        flight.reset()
        retained.reset()
        contentEpoch = session.accountEpoch
        loadState = CatalogLoadState()
        item = nil
        releases = []
        clearOverview()
    }

    func prepare(_ selected: CatalogItem) {
        guard selected.kind == .artist else { return }
        if contentEpoch != session.accountEpoch { reset() }
        if item?.uri != selected.uri { restore(selected) }
    }

    func load(_ selected: CatalogItem, force: Bool = false) async {
        guard selected.kind == .artist else { return }
        prepare(selected)
        guard session.isAvailable else {
            loadState.markStale()
            return
        }
        if loadState.isCurrent(in: session.snapshot), !force { return }
        switch flight.admit(selected.uri, force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            loadState.begin()
            retained.markStale(selected.uri)
            defer { if flight.owns(handle) { loadState.finish() } }
            guard let id = SpotifyURI.id(from: selected.uri, kind: "artist") else {
                loadState.fail(message: "Spotify returned an invalid artist address.")
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                do {
                    let result: CatalogArtistSnapshot
                    switch content {
                    case .overview: result = try await provider.artist(id: id)
                    case .discography: result = try await provider.artistDiscography(id: id)
                    }
                    guard self.isCurrent(handle) else { return }
                    item =
                        result.item?.uri == selected.uri && result.name != nil ? (result.item ?? selected) : selected
                    releases = result.releases.map { release in
                        guard release.subtitle.isEmpty else { return release }
                        return CatalogItem(
                            id: release.id, uri: release.uri, title: release.title,
                            subtitle: result.name ?? selected.title, artworkURL: release.artworkURL,
                            kind: release.kind, ownerURI: release.ownerURI)
                    }
                    overview = result.overview
                    releaseKinds = result.releaseKinds ?? [:]
                    releaseDates = result.releaseDates ?? [:]
                    popularTracks.replace(overview?.popularTracks.map(\.track) ?? [])
                    popularPreview.replace(Array(popularTracks.tracks.prefix(5)))
                    updateArtistTracks()
                    loadState.receive(session: session.snapshot, freshness: result.freshness)
                    retained.store(
                        Snapshot(
                            item: item ?? selected, releases: releases, freshness: freshness,
                            overview: overview, releaseKinds: releaseKinds, releaseDates: releaseDates,
                            popularTracks: popularTracks, popularPreview: popularPreview), for: selected.uri,
                        cost: releases.count + popularTracks.tracks.count, snapshot: handle.sessionSnapshot
                    )
                } catch {
                    guard self.flight.shouldReport(error, for: handle), item?.uri == handle.key else { return }
                    if loadState.fail(error) {
                        let refusal = loadState
                        reset()
                        prepare(selected)
                        loadState = refusal
                    }
                    retained.markStale(selected.uri)
                }
            }
        }
    }

    private func restore(_ selected: CatalogItem) {
        flight.reset()
        item = selected
        loadState = CatalogLoadState()
        if let cached = retained.entry(for: selected.uri) {
            item = cached.value.item
            releases = cached.value.releases
            overview = cached.value.overview
            releaseKinds = cached.value.releaseKinds
            releaseDates = cached.value.releaseDates
            popularTracks = cached.value.popularTracks
            popularPreview = cached.value.popularPreview
            updateArtistTracks()
            loadState.restore(
                session: cached.session, freshness: cached.value.freshness, needsRefresh: cached.needsRefresh)
        } else {
            releases = []
            clearOverview()

        }
    }

    private func clearOverview() {
        overview = nil
        releaseKinds = [:]
        releaseDates = [:]
        popularTracks.replace([])
        popularPreview.replace([])
        artistTracks = [:]
    }

    private func updateArtistTracks() {
        artistTracks = Dictionary(
            (overview?.popularTracks ?? []).map { ($0.track.uri, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        item?.uri == handle.key && flight.isCurrent(handle)
    }
}

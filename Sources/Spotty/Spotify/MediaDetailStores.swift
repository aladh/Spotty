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
        let freshness: CatalogFreshness
    }

    private(set) var item: CatalogItem?
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var releaseDate = ""
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isShowingCachedContent = false
    private(set) var freshness: CatalogFreshness = .current

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation
    @ObservationIgnored private var loadedSession: CatalogSessionSnapshot?
    @ObservationIgnored private var contentEpoch: UInt64
    @ObservationIgnored private var hasLoadedContent = false

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
        loadedSession = nil
        hasLoadedContent = false
        item = nil
        trackCollection.replace([])
        releaseDate = ""
        isLoading = false
        error = nil
        isShowingCachedContent = false
        freshness = .current
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
            isShowingCachedContent = hasLoadedContent
            return
        }
        if loadedSession == session.snapshot, error == nil, freshness.isCurrent, !force { return }
        switch flight.admit(selected.uri, force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            if !hasLoadedContent { error = nil }
            isLoading = true
            isShowingCachedContent = hasLoadedContent
            guard let id = SpotifyURI.id(from: selected.uri, kind: "album") else {
                error = "Spotify returned an invalid album address."
                isLoading = false
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.flight.owns(handle) {
                        isLoading = false
                        isShowingCachedContent =
                            hasLoadedContent
                            && (loadedSession != session.snapshot || error != nil || !freshness.isCurrent)
                    }
                }
                do {
                    let album = try await provider.album(id: id)
                    guard self.isCurrent(handle) else { return }
                    // A full result supersedes even a previously returned entity-query page.
                    entityObservation.reset()
                    item = album.item?.uri == selected.uri ? (album.item ?? selected) : selected
                    trackCollection.replace(album.tracks)
                    releaseDate = album.releaseDate
                    loadedSession = session.snapshot
                    hasLoadedContent = true
                    error = nil
                    freshness = album.freshness
                    isShowingCachedContent = !freshness.isCurrent
                    if freshness.isCurrent { self.flight.markLoaded(handle) }
                    retained.store(
                        Snapshot(
                            item: item ?? selected, collection: trackCollection, releaseDate: releaseDate,
                            freshness: freshness),
                        for: selected.uri, cost: tracks.count, snapshot: handle.sessionSnapshot
                    )
                    updateEntityObservation()
                    metadata.replaceTracks(tracks, from: .album)
                    metadata.loadTrackAttributes(for: tracks)
                } catch {
                    guard self.flight.shouldReport(error, for: handle), item?.uri == handle.key else { return }
                    self.error = CatalogErrorPresentation.message(for: error)
                    isShowingCachedContent = hasLoadedContent
                    retained.markStale(selected.uri)
                }
            }
        }
    }

    private func restore(_ selected: CatalogItem) {
        flight.reset()
        item = selected
        error = nil
        isLoading = false
        if let cached = retained.entry(for: selected.uri) {
            item = cached.value.item
            trackCollection = cached.value.collection
            releaseDate = cached.value.releaseDate
            loadedSession = cached.needsRefresh ? nil : cached.session
            hasLoadedContent = true
            freshness = cached.value.freshness
            isShowingCachedContent = cached.needsRefresh || cached.session != session.snapshot || !freshness.isCurrent
            metadata.replaceTracks(tracks, from: .album)
        } else {
            trackCollection.replace([])
            releaseDate = ""
            loadedSession = nil
            hasLoadedContent = false
            freshness = .current
            isShowingCachedContent = false
            metadata.replaceTracks([], from: .album)
        }
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
                item: snapshot.item, collection: updated, releaseDate: snapshot.releaseDate,
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
    private typealias Flight = AccountScopedSingleFlight<String>

    private struct Snapshot {
        let item: CatalogItem
        let releases: [CatalogItem]
        let freshness: CatalogFreshness
    }

    private(set) var item: CatalogItem?
    private(set) var releases: [CatalogItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isShowingCachedContent = false
    private(set) var freshness: CatalogFreshness = .current

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Snapshot>
    @ObservationIgnored private var loadedSession: CatalogSessionSnapshot?
    @ObservationIgnored private var contentEpoch: UInt64
    @ObservationIgnored private var hasLoadedContent = false

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
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
        loadedSession = nil
        hasLoadedContent = false
        item = nil
        releases = []
        isLoading = false
        error = nil
        isShowingCachedContent = false
        freshness = .current
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
            isShowingCachedContent = hasLoadedContent
            return
        }
        if loadedSession == session.snapshot, error == nil, freshness.isCurrent, !force { return }
        switch flight.admit(selected.uri, force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            if !hasLoadedContent { error = nil }
            isLoading = true
            isShowingCachedContent = hasLoadedContent
            guard let id = SpotifyURI.id(from: selected.uri, kind: "artist") else {
                error = "Spotify returned an invalid artist address."
                isLoading = false
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.flight.owns(handle) {
                        isLoading = false
                        isShowingCachedContent =
                            hasLoadedContent
                            && (loadedSession != session.snapshot || error != nil || !freshness.isCurrent)
                    }
                }
                do {
                    async let overview = provider.artist(id: id)
                    async let discography = provider.artistDiscography(id: id)
                    let (profile, allReleases) = try await (overview, discography)
                    guard self.isCurrent(handle) else { return }
                    item = profile.item?.uri == selected.uri ? (profile.item ?? selected) : selected
                    let artistName = profile.name ?? selected.title
                    releases = allReleases.releases.map { release in
                        CatalogItem(
                            id: release.id, uri: release.uri, title: release.title, subtitle: artistName,
                            artworkURL: release.artworkURL, kind: release.kind, ownerURI: release.ownerURI)
                    }
                    loadedSession = session.snapshot
                    hasLoadedContent = true
                    error = nil
                    freshness = profile.freshness.isCurrent ? allReleases.freshness : profile.freshness
                    isShowingCachedContent = !freshness.isCurrent
                    if freshness.isCurrent { self.flight.markLoaded(handle) }
                    retained.store(
                        Snapshot(item: item ?? selected, releases: releases, freshness: freshness), for: selected.uri,
                        cost: releases.count, snapshot: handle.sessionSnapshot
                    )
                } catch {
                    guard self.flight.shouldReport(error, for: handle), item?.uri == handle.key else { return }
                    self.error = CatalogErrorPresentation.message(for: error)
                    isShowingCachedContent = hasLoadedContent
                    retained.markStale(selected.uri)
                }
            }
        }
    }

    private func restore(_ selected: CatalogItem) {
        flight.reset()
        item = selected
        error = nil
        isLoading = false
        if let cached = retained.entry(for: selected.uri) {
            item = cached.value.item
            releases = cached.value.releases
            loadedSession = cached.needsRefresh ? nil : cached.session
            hasLoadedContent = true
            freshness = cached.value.freshness
            isShowingCachedContent = cached.needsRefresh || cached.session != session.snapshot || !freshness.isCurrent
        } else {
            releases = []
            loadedSession = nil
            hasLoadedContent = false
            freshness = .current
            isShowingCachedContent = false
        }
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        item?.uri == handle.key && flight.isCurrent(handle)
    }
}

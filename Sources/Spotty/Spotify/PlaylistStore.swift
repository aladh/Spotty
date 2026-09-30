// Controlled CI measurement input for #587; no runtime behavior changes.
import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts

/// Owns playlist queries and prepared playback evidence. Callers select a route and consume
/// content; saved/live reads, retained authority, and entity acknowledgement stay here.
@MainActor
@Observable
final class PlaylistStore {
    private typealias Flight = CatalogReadFlights<String>

    private struct Retained {
        var content: PlaylistDetailContent
        let freshness: CatalogFreshness
        let error: String?
    }

    private var selection: CatalogItem?
    private var contentEpoch: UInt64
    private var content = PlaylistDetailContent()
    private var loadState = CatalogLoadState()
    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Retained>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation

    var item: CatalogItem? { content.item }
    var loadedURI: String? { selection?.uri }
    var trackCollection: CatalogTrackCollection { content.collection }
    var tracks: [CatalogTrack] { trackCollection.tracks }
    var playbackContents: CatalogPlaylistContents? {
        CatalogPlaylistContents(uri: loadedURI, accountEpoch: contentEpoch, collection: trackCollection)
    }
    var totalDuration: TimeInterval { content.totalDuration }
    var description: String { content.description }
    var ownerURI: String? { content.ownerURI }
    var isLoading: Bool { loadState.isLoading }
    var isLoadingInitialContent: Bool { isLoading && !hasLoadedContent }
    var error: String? { loadState.error }
    var isShowingCachedContent: Bool { loadState.isShowingSavedContent(in: session.snapshot) }
    var freshness: CatalogFreshness { loadState.freshness }
    private var isCurrentContent: Bool { loadState.isCurrent(in: session.snapshot) }
    var canEditLoadedContent: Bool { isCurrentContent }
    var hasLoadedContent: Bool { loadState.hasContent }

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        contentEpoch = session.accountEpoch
        flight = Flight(session: session)
        retained = RetainedCatalogRoutes(session: session)
        entityObservation = CatalogEntityObservation(provider: provider, session: session)
    }

    func reset() {
        flight.reset()
        retained.reset()
        entityObservation.reset()
        contentEpoch = session.accountEpoch
        selection = nil
        content = PlaylistDetailContent()
        loadState = CatalogLoadState()
        publishMetadata()
    }

    func invalidateRetainedPlaylist(_ uri: String) {
        retained.remove(uri)
        updateEntityObservation()
        if selection?.uri == uri { loadState.markStale() }
    }

    func prepare(_ selected: CatalogItem) {
        guard selected.kind == .playlist else { return }
        if contentEpoch != session.accountEpoch { reset() }
        if selection?.uri != selected.uri {
            flight.reset()
            selection = selected
            loadState = CatalogLoadState()
            if let saved = retained.entry(for: selected.uri) {
                content = saved.value.content
                loadState.restore(
                    session: saved.session, freshness: saved.value.freshness,
                    needsRefresh: saved.needsRefresh, error: saved.value.error)
            } else {
                content = PlaylistDetailContent(item: selected)
            }
            publishMetadata()
        }
        updateEntityObservation()
    }

    func load(_ selected: CatalogItem, force: Bool = false) async {
        guard !Task.isCancelled, selected.kind == .playlist else { return }
        prepare(selected)
        guard session.isAvailable else {
            loadState.markStale()
            return
        }
        if isCurrentContent, !force { return }
        await flight.read(
            selected.uri, force: force,
            started: { [weak self] _ in
                self?.loadState.begin()
                self?.retained.markStale(selected.uri)
            },
            settled: { [weak self] in self?.loadState.finish() }
        ) { [weak self, provider] handle in
            guard let id = SpotifyURI.id(from: selected.uri, kind: "playlist") else {
                self?.loadState.fail(message: "Spotify returned an invalid playlist address.")
                return
            }
            do {
                if self?.hasLoadedContent == false,
                    let saved = try await provider.cachedPlaylist(id: id)
                {
                    guard let self, isCurrent(handle) else { return }
                    apply(saved, selected: selected, handle: handle)
                }
                guard self?.isCurrent(handle) == true else { return }
                let result = try await provider.playlist(id: id)
                guard let self, isCurrent(handle) else { return }
                apply(result, selected: selected, handle: handle)
            } catch {
                guard let self, flight.shouldReport(error, for: handle), selection?.uri == handle.key else { return }
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

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        selection?.uri == handle.key && flight.isCurrent(handle)
    }

    private func apply(_ result: CatalogPlaylistSnapshot, selected: CatalogItem, handle: Flight.Handle) {
        // Whole collection replacement fences entity reads, even when URI membership is unchanged.
        entityObservation.reset()
        content = PlaylistDetailContent(result, selected: selected)
        loadState.receive(session: handle.sessionSnapshot, freshness: result.freshness)
        retained.store(
            Retained(content: content, freshness: freshness, error: error),
            for: handle.key, cost: tracks.count, snapshot: handle.sessionSnapshot)
        updateEntityObservation()
        publishMetadata()
    }

    private func updateEntityObservation() {
        entityObservation.update(collections: [content.collection] + retained.values.map(\.content.collection)) {
            [weak self] entities in self?.applyEntityMetadata(entities)
        }
    }

    private func applyEntityMetadata(_ entities: [String: CatalogTrackMetadata]) {
        guard !entities.isEmpty else { return }
        let currentUpdate = content.collection.applyingMetadata(entities)
        retained.updateValues { saved in
            var saved = saved
            let update =
                saved.content.collection.version == content.collection.version
                ? currentUpdate : saved.content.collection.applyingMetadata(entities)
            if let update {
                saved.content.collection = update
                saved.content.totalDuration = PlaylistDetailContent.duration(of: update)
            }
            return saved
        }
        guard let currentUpdate else { return }
        content.collection = currentUpdate
        content.totalDuration = PlaylistDetailContent.duration(of: currentUpdate)
        publishMetadata()
    }

    private func publishMetadata() {
        metadata.replaceTracks(tracks, from: .playlist)
    }
}

/// One content value serves visible and retained routes; freshness evidence stays with the query.
private struct PlaylistDetailContent {
    var item: CatalogItem?
    var collection: CatalogTrackCollection
    var totalDuration: TimeInterval = 0
    var description = ""
    var ownerURI: String?

    init(item: CatalogItem? = nil) {
        self.item = item
        collection = CatalogTrackCollection()
    }

    init(_ result: CatalogPlaylistSnapshot, selected: CatalogItem) {
        item = result.item?.uri == selected.uri ? (result.item ?? selected) : selected
        collection = CatalogTrackCollection(tracks: result.tracks)
        totalDuration = Self.duration(of: collection)
        description = result.description
        ownerURI = result.freshness.isCurrent ? result.ownerURI : nil
    }

    static func duration(of collection: CatalogTrackCollection) -> TimeInterval {
        collection.tracks.reduce(0) { $0 + TimeInterval(roundedCatalogDurationSeconds($1.duration)) }
    }
}

/// Account-scoped composition keeps reads and writes on separate ports. The controller retains
/// its query for admitted offscreen settlement; the query never retains the controller.
@MainActor
final class PlaylistFeature {
    let query: PlaylistStore
    let mutations: PlaylistMutationController

    init(
        provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability,
        mutations: any PlaylistMutating, homeLibrary: HomeLibraryStore, feedback: TransientFeedbackPresenter
    ) {
        query = PlaylistStore(provider: provider, metadata: metadata, session: session)
        self.mutations = PlaylistMutationController(
            mutations: mutations, session: session, feedback: feedback,
            playlistStore: query, homeLibrary: homeLibrary)
    }

    func reset() {
        query.reset()
        mutations.reset()
    }
}

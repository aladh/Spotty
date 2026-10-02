import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts

/// Owns one detail selection scope, including saved/live reads, retained content, and entity
/// enrichment. Feature projections never operate request handles or coordinate these lifetimes.
@MainActor
@Observable
final class CatalogDetailCoordinator {
    private typealias Flight = CatalogReadFlights<String>

    private enum Publication {
        case independent(CatalogMetadataRepository?)
        case discography(@MainActor () -> Void)
    }

    private enum Loaded {
        case album(CatalogAlbumSnapshot)
        case artist(CatalogArtistSnapshot)

        var freshness: CatalogFreshness {
            switch self {
            case let .album(value): value.freshness
            case let .artist(value): value.freshness
            }
        }

        func content(for selected: CatalogItem) -> CatalogDetailPayload {
            switch self {
            case let .album(value): .album(AlbumDetailContent(value, selected: selected))
            case let .artist(value): .artist(ArtistDetailContent(value, selected: selected))
            }
        }
    }

    private struct Retained {
        var payload: CatalogDetailPayload
        let freshness: CatalogFreshness
        let error: String?
        let acceptedAt: Date
    }

    private(set) var selection: CatalogItem?
    private(set) var contentEpoch: UInt64
    private var payload: CatalogDetailPayload
    private var loadState = CatalogLoadState()
    private var acceptedAt: Date?
    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let kind: CatalogDetailKind
    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let publication: Publication
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let retained: RetainedCatalogRoutes<Retained>
    @ObservationIgnored private let entityObservation: CatalogEntityObservation?

    convenience init(
        kind: CatalogDetailKind, provider: any CatalogProviding,
        metadata: CatalogMetadataRepository? = nil, session: CatalogSessionAvailability,
        clock: any PlaybackClock
    ) {
        self.init(kind: kind, provider: provider, session: session, clock: clock, publication: .independent(metadata))
    }

    static func discographyAlbum(
        provider: any CatalogProviding, session: CatalogSessionAvailability,
        clock: any PlaybackClock, onReplacement: @escaping @MainActor () -> Void
    ) -> CatalogDetailCoordinator {
        CatalogDetailCoordinator(
            kind: .album, provider: provider, session: session, clock: clock, publication: .discography(onReplacement))
    }

    private init(
        kind: CatalogDetailKind, provider: any CatalogProviding, session: CatalogSessionAvailability,
        clock: any PlaybackClock, publication: Publication
    ) {
        self.kind = kind
        self.provider = provider
        self.publication = publication
        self.session = session
        self.clock = clock
        contentEpoch = session.accountEpoch
        payload = kind.emptyContent()
        flight = Flight(session: session)
        retained = RetainedCatalogRoutes(session: session)
        switch (kind, publication) {
        case (.album, .independent):
            entityObservation = CatalogEntityObservation(provider: provider, session: session)
        default:
            entityObservation = nil
        }
    }

    var item: CatalogItem? { payload.item }
    var isLoading: Bool { loadState.isLoading }
    var hasLoadedContent: Bool { loadState.hasContent }
    var error: String? { loadState.error }
    var freshness: CatalogFreshness { loadState.freshness }
    var isCurrentContent: Bool { loadState.isCurrent(in: session.snapshot) }
    var isShowingCachedContent: Bool { loadState.isShowingSavedContent(in: session.snapshot) }

    // Each concrete projection fixes its kind at construction. A mismatch is a programming
    // error; never synthesize a fresh empty collection (and version) from a presentation read.
    var albumContent: AlbumDetailContent {
        guard case let .album(value) = payload else { preconditionFailure("Expected album detail") }
        return value
    }

    var artistContent: ArtistDetailContent {
        guard case let .artist(value) = payload else { preconditionFailure("Expected artist detail") }
        return value
    }

    #if DEBUG
        /// Retain admitted worker handles before cancellation/reset for bounded lifetime checks.
        func workerSettlements() -> [Task<Void, Never>] { flight.workerSettlements() }
    #endif

    func reset() {
        flight.reset()
        retained.reset()
        entityObservation?.reset()
        contentEpoch = session.accountEpoch
        selection = nil
        payload = kind.emptyContent()
        loadState = CatalogLoadState()
        acceptedAt = nil
        publishReplacement()
    }

    func prepare(_ selected: CatalogItem) {
        guard selected.kind == kind.itemKind else { return }
        if contentEpoch != session.accountEpoch { reset() }
        if selection?.uri != selected.uri {
            flight.reset()
            selection = selected
            loadState = CatalogLoadState()
            acceptedAt = nil
            if let saved = retained.entry(for: selected.uri) {
                payload = saved.value.payload
                acceptedAt = saved.value.acceptedAt
                loadState.restore(
                    session: saved.session, freshness: saved.value.freshness,
                    needsRefresh: saved.needsRefresh || isExpired(saved.value.acceptedAt), error: saved.value.error)
            } else {
                payload = kind.emptyContent(item: selected)
            }
            publishReplacement()
        }
        if hasLoadedContent, isExpired(acceptedAt) { loadState.markStale() }
        updateEntityObservation()
    }

    /// Successful details are reused for five minutes; metadata and failed reads never renew them.
    /// Expired rows remain visible while the existing session-gated read refreshes them.
    private func isExpired(_ acceptedAt: Date?) -> Bool {
        guard let acceptedAt else { return true }
        let elapsed = clock.now().timeIntervalSince(acceptedAt)
        return !(elapsed >= 0 && elapsed < 300)
    }

    func load(_ selected: CatalogItem, force: Bool = false) async {
        guard !Task.isCancelled, selected.kind == kind.itemKind else { return }
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
        ) { [weak self, provider, kind] handle in
            guard let id = SpotifyURI.id(from: selected.uri, kind: kind.uriKind) else {
                self?.loadState.fail(message: "Spotify returned an invalid \(kind.uriKind) address.")
                return
            }
            do {
                if self?.hasLoadedContent == false,
                    let saved = try await Self.cachedDetail(provider, kind: kind, id: id)
                {
                    guard let self, isCurrent(handle) else { return }
                    apply(saved, selected: selected, handle: handle)
                }
                guard self?.isCurrent(handle) == true else { return }
                let result = try await Self.liveDetail(provider, kind: kind, id: id)
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

    func invalidate(_ uri: String) {
        retained.remove(uri)
        updateEntityObservation()
        if selection?.uri == uri { loadState.markStale() }
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        selection?.uri == handle.key && flight.isCurrent(handle)
    }

    private static func cachedDetail(
        _ provider: any CatalogProviding, kind: CatalogDetailKind, id: String
    ) async throws -> Loaded? {
        switch kind {
        case .album:
            return try await provider.cachedAlbum(id: id).map(Loaded.album)
        case .artistOverview, .artistDiscography:
            return nil
        }
    }

    private static func liveDetail(
        _ provider: any CatalogProviding, kind: CatalogDetailKind, id: String
    ) async throws -> Loaded {
        switch kind {
        case .album: return .album(try await provider.album(id: id))
        case .artistOverview: return .artist(try await provider.artist(id: id))
        case .artistDiscography: return .artist(try await provider.artistDiscography(id: id))
        }
    }

    private func apply(_ result: Loaded, selected: CatalogItem, handle: Flight.Handle) {
        // A pending page from the previous collection cannot enrich its replacement.
        entityObservation?.reset()
        // Map and normalize rows only after the request has passed its publication gate.
        payload = result.content(for: selected)
        loadState.receive(session: handle.sessionSnapshot, freshness: result.freshness)
        let acceptedAt = clock.now()
        self.acceptedAt = acceptedAt
        retained.store(
            Retained(payload: payload, freshness: freshness, error: error, acceptedAt: acceptedAt),
            for: handle.key, cost: payload.retentionCost, snapshot: handle.sessionSnapshot)
        updateEntityObservation()
        publishReplacement()
    }

    private func updateEntityObservation() {
        guard let entityObservation else { return }
        let collections =
            [payload.observedCollection].compactMap { $0 }
            + retained.values.compactMap { $0.payload.observedCollection }
        entityObservation.update(collections: collections) { [weak self] entities in
            self?.applyEntityMetadata(entities)
        }
    }

    @discardableResult
    func applyEntityMetadata(_ entities: [String: CatalogTrackMetadata]) -> Bool {
        guard !entities.isEmpty else { return false }
        let currentCollection = payload.observedCollection
        let currentUpdate = currentCollection?.applyingMetadata(entities)
        retained.updateValues { saved in
            var saved = saved
            let collection = saved.payload.observedCollection
            let update =
                collection?.version == currentCollection?.version
                ? currentUpdate : collection?.applyingMetadata(entities)
            if let update { saved.payload = saved.payload.replacingCollection(update) }
            return saved
        }
        guard let currentUpdate else { return false }
        payload = payload.replacingCollection(currentUpdate)
        publishMetadata()
        return true
    }

    private func publishReplacement() {
        switch publication {
        case .independent: publishMetadata()
        case let .discography(onReplacement): onReplacement()
        }
    }

    private func publishMetadata() {
        guard case let .independent(metadata?) = publication else { return }
        switch kind {
        case .album: metadata.replaceTracks(albumContent.collection.tracks, from: .album)
        case .artistOverview, .artistDiscography: break
        }
    }
}

//
//  SearchStore.swift
//  Spotty
//
//  Query-scoped, independently published catalog search state.
//

import SpottyDomain
import Foundation
import SpottyRuntimeContracts

@MainActor
@Observable
final class SearchStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    enum Section: String, CaseIterable, Sendable {
        case tracks, albums, artists, playlists
    }

    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var albums: [CatalogItem] = []
    private(set) var artists: [CatalogItem] = []
    private(set) var playlists: [CatalogItem] = []
    private(set) var errors: [Section: String] = [:]
    private(set) var isSearching = false

    // Compatibility projections retained for the small boundary-check executable.
    var error: String? {
        Section.allCases.lazy.compactMap { self.errors[$0] }.first
    }
    var failedSections: [Section] {
        Section.allCases.filter { self.errors[$0] != nil }
    }
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    /// Delay before a view-driven query is admitted. Try Again calls `search`
    /// directly and must not wait this interval again.
    static let queryAdmissionDelay: TimeInterval = 0.3

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private var debounceGeneration: UInt64 = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability,
        clock: any PlaybackClock
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        self.clock = clock
        // A newer query always replaces the one in flight; there is nothing to join.
        flight = Flight(session: session, join: .alwaysSupersede, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        invalidatePendingAdmission()
        flight.reset()
        clearResults()
        isSearching = false
    }

    /// Immediate admission for Try Again. Invalidates a pending debounce so a
    /// later timer cannot start a second fetch for a superseded query.
    func search(_ term: String) async {
        invalidatePendingAdmission()
        await performSearch(term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// View-driven query path. Cancelled or superseded before the delay leaves
    /// committed results and `isSearching` unchanged.
    func scheduleSearch(_ term: String) async {
        invalidatePendingAdmission()
        let token = debounceGeneration
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduled = session.snapshot
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(seconds: Self.queryAdmissionDelay)
            } catch {
                return
            }
            guard token == self.debounceGeneration, !Task.isCancelled else { return }
            guard self.session.snapshot == scheduled else { return }
            await self.performSearch(query)
        }
        debounceTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if token == debounceGeneration {
            debounceTask = nil
        }
    }

    private func invalidatePendingAdmission() {
        debounceGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func performSearch(_ query: String) async {
        let handle = flight.begin(query)
        guard session.isAvailable, !query.isEmpty else {
            clearResults()
            isSearching = false
            return
        }

        clearResults()
        isSearching = true
        await flight.run(handle) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadTracks(query, handle: handle) }
                group.addTask { await self.loadAlbums(query, handle: handle) }
                group.addTask { await self.loadArtists(query, handle: handle) }
                group.addTask { await self.loadPlaylists(query, handle: handle) }
            }
        }
        if flight.owns(handle) {
            isSearching = false
        }
    }

    private func loadTracks(_ query: String, handle: Flight.Handle) async {
        await load(.tracks, handle: handle) {
            let values = try await provider.searchTracks(query, limit: 50)
            guard flight.isCurrent(handle) else { return }
            trackCollection.replace(values)
            metadata.replaceTracks(values, from: .search)
            metadata.loadTrackAttributes(for: values)
        }
    }

    private func loadAlbums(_ query: String, handle: Flight.Handle) async {
        await load(.albums, handle: handle) {
            let values = try await provider.searchAlbums(query, limit: 30)
            guard flight.isCurrent(handle) else { return }
            albums = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func loadArtists(_ query: String, handle: Flight.Handle) async {
        await load(.artists, handle: handle) {
            let values = try await provider.searchArtists(query, limit: 30)
            guard flight.isCurrent(handle) else { return }
            artists = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func loadPlaylists(_ query: String, handle: Flight.Handle) async {
        await load(.playlists, handle: handle) {
            let values = try await provider.searchPlaylists(query, limit: 30)
            guard flight.isCurrent(handle) else { return }
            playlists = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func load(
        _ section: Section,
        handle: Flight.Handle,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch CatalogProviderCapabilityError.unsupported {
        } catch {
            guard flight.shouldReport(error, for: handle) else { return }
            errors[section] = CatalogErrorPresentation.message(for: error)
        }
    }

    private func clearResults() {
        trackCollection.replace([])
        albums = []
        artists = []
        playlists = []
        errors = [:]
        metadata.replaceTracks([], from: .search)
        metadata.replaceItems([], from: .search)
    }
}

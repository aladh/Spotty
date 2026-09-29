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
    private typealias Flight = CatalogReadFlights<String>

    enum Section: String, CaseIterable, Sendable {
        case tracks, albums, artists, playlists
    }

    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var albums: [CatalogItem] = []
    private(set) var artists: [CatalogItem] = []
    private(set) var playlists: [CatalogItem] = []
    private(set) var errors: [Section: String] = [:]
    private var loadState = CatalogLoadState()
    var isSearching: Bool { loadState.isLoading }
    private var admittedQuery: String?
    private var admittedSession: CatalogSessionSnapshot?

    // Compatibility projections retained for the small boundary-check executable.
    var error: String? {
        Section.allCases.lazy.compactMap { self.errors[$0] }.first
    }
    var failedSections: [Section] {
        Section.allCases.filter { self.errors[$0] != nil }
    }
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    /// Empty results are meaningful only after this query has completed. Debounce still
    /// preserves existing rows, but must not briefly label an unrequested query "No results".
    func isAwaitingResults(for term: String) -> Bool {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isAvailable && !query.isEmpty
            && (!loadState.hasSettled || admittedQuery != query || admittedSession != session.snapshot)
    }

    /// Delay before a view-driven query is admitted. Try Again calls `search`
    /// directly and must not wait this interval again.
    static let queryAdmissionDelay: TimeInterval = 0.3

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private let admission: Flight

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
        flight = Flight(session: session)
        admission = Flight(session: session)
    }

    func reset() {
        admission.reset()
        flight.reset()
        clearResults()
        loadState = CatalogLoadState()
    }

    /// Immediate admission for Try Again. Invalidates a pending debounce so a
    /// later timer cannot start a second fetch for a superseded query.
    func search(_ term: String) async {
        guard !Task.isCancelled else { return }
        admission.reset()
        await performSearch(term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// View-driven query path. Cancelled or superseded before the delay leaves
    /// committed results and `isSearching` unchanged.
    func scheduleSearch(_ term: String) async {
        guard !Task.isCancelled else { return }
        admission.reset()
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        // The connected view owns delayed admission. Direct offline calls clear state without
        // starting a timer that cannot acquire current account authority.
        guard session.isAvailable else {
            await performSearch(query)
            return
        }
        // Returning from details should restore the current result set and its native position.
        if admittedQuery == query, loadState.isCurrent(in: session.snapshot), errors.isEmpty { return }
        // This scope spans both delay and fetch, while immediate searches own only `flight`.
        // Capturing the clock separately lets a cancelled caller release the store during sleep.
        await admission.read(query, force: true) { [weak self, clock] handle in
            do {
                try await clock.sleep(seconds: Self.queryAdmissionDelay)
            } catch {
                return
            }
            guard let self, admission.isCurrent(handle) else { return }
            await performSearch(query)
        }
    }

    private func performSearch(_ query: String) async {
        guard !Task.isCancelled else { return }
        guard session.isAvailable, !query.isEmpty else {
            flight.reset()
            clearResults()
            return
        }
        await flight.read(
            query, force: true,
            started: { [weak self] handle in
                guard let self else { return }
                // A retry keeps usable rows; a different query or session replaces them.
                if admittedQuery != query || admittedSession != handle.sessionSnapshot {
                    clearResults()
                } else {
                    errors = [:]
                }
                admittedQuery = query
                admittedSession = handle.sessionSnapshot
                loadState.begin(keepPreviousError: false)
            },
            settled: { [weak self] in self?.loadState.finish() }
        ) { [weak self, provider] handle in
            await withTaskGroup(of: (Section, Result<SectionPayload, any Error>).self) { group in
                for section in Section.allCases {
                    group.addTask { (section, await Self.fetch(section, query: query, provider: provider)) }
                }
                for await (section, result) in group {
                    guard let self, self.flight.isCurrent(handle) else {
                        group.cancelAll()
                        return
                    }
                    switch result {
                    case let .success(payload): self.apply(payload)
                    case let .failure(error): self.record(error, section: section, handle: handle)
                    }
                }
            }
            if self?.flight.isCurrent(handle) == true {
                self?.loadState.receive(session: handle.sessionSnapshot)
            }
        }
    }

    private enum SectionPayload: Sendable {
        case tracks([CatalogTrack])
        case albums([CatalogItem])
        case artists([CatalogItem])
        case playlists([CatalogItem])
    }

    private nonisolated static func fetch(
        _ section: Section, query: String, provider: any CatalogProviding
    ) async -> Result<SectionPayload, any Error> {
        do {
            switch section {
            case .tracks: return .success(.tracks(try await provider.searchTracks(query, limit: 50)))
            case .albums: return .success(.albums(try await provider.searchAlbums(query, limit: 30)))
            case .artists: return .success(.artists(try await provider.searchArtists(query, limit: 30)))
            case .playlists: return .success(.playlists(try await provider.searchPlaylists(query, limit: 30)))
            }
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ payload: SectionPayload) {
        switch payload {
        case let .tracks(values):
            trackCollection.replace(values)
            metadata.replaceTracks(values, from: .search)
        case let .albums(values):
            albums = values
            replaceItemMetadata()
        case let .artists(values):
            artists = values
            replaceItemMetadata()
        case let .playlists(values):
            playlists = values
            replaceItemMetadata()
        }
    }

    private func replaceItemMetadata() {
        // Retire this section's old labels while preserving pending or failed siblings.
        metadata.replaceItems(albums + artists + playlists, from: .search)
    }

    private func record(_ error: any Error, section: Section, handle: Flight.Handle) {
        if error as? CatalogProviderCapabilityError == .unsupported { return }
        guard flight.shouldReport(error, for: handle) else { return }
        let message = CatalogErrorPresentation.message(for: error)
        var outcome = loadState
        if outcome.fail(error) {
            // A refusal fences sibling results without discarding a newer pending debounce.
            flight.reset()
            clearResults()
            loadState = outcome
            admittedQuery = handle.key
            admittedSession = handle.sessionSnapshot
            errors = Dictionary(uniqueKeysWithValues: Section.allCases.map { ($0, message) })
        } else {
            errors[section] = message
        }
    }

    private func clearResults() {
        loadState = CatalogLoadState()
        admittedQuery = nil
        admittedSession = nil
        trackCollection.replace([])
        albums = []
        artists = []
        playlists = []
        errors = [:]
        metadata.replaceTracks([], from: .search)
        metadata.replaceItems([], from: .search)
    }
}

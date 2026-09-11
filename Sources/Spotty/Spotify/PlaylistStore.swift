//
//  PlaylistStore.swift
//  Spotty
//
//  Selected-playlist detail state.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class PlaylistStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var totalDuration: TimeInterval = 0
    var description = ""
    private(set) var loadedURI: String?
    private(set) var ownerURI: String?
    var isLoading = false
    var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight
    @ObservationIgnored private var loadedSessionSnapshot: CatalogSessionSnapshot?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        flight = Flight(session: session, join: .joinMatchingKey, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        flight.reset()
        loadedSessionSnapshot = nil
        replaceTracks([])
        description = ""
        loadedURI = nil
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
        replaceTracks(tracks)
    }

    func load(_ item: CatalogItem, force: Bool = false) async {
        let currentSession = session.snapshot
        guard currentSession.isAvailable, item.kind == .playlist else { return }
        if loadedURI == item.uri,
            loadedSessionSnapshot == currentSession,
            error == nil,
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

        let isNewPlaylist = loadedURI != item.uri
        loadedURI = item.uri
        if isNewPlaylist {
            loadedSessionSnapshot = nil
            replaceTracks([])
            description = ""
            ownerURI = item.ownerURI
            metadata.replaceTracks([], from: .playlist)
            error = nil
        } else if !force {
            error = nil
        }
        // Same-playlist force reloads keep `error` until a current load succeeds so a
        // cancelled or superseded retry cannot hide stale rows.
        isLoading = true
        defer {
            if flight.owns(handle) {
                isLoading = false
            }
        }

        guard let id = SpotifyURI.id(from: item.uri, kind: "playlist") else {
            error = "Spotify returned an invalid playlist address."
            flight.abandonUnstarted(handle)
            return
        }

        await flight.run(handle) { [weak self] in
            guard let self else { return }
            await self.performLoad(
                item,
                id: id,
                handle: handle,
                isNewPlaylist: isNewPlaylist
            )
        }
    }

    private func performLoad(
        _ item: CatalogItem,
        id: String,
        handle: Flight.Handle,
        isNewPlaylist: Bool
    ) async {
        do {
            let playlist = try await provider.playlist(id: id)
            guard isCurrent(handle) else { return }
            error = nil
            description = PlaylistDescription.plainText(from: playlist.description ?? "")
            ownerURI = CatalogMapping.ownerURI(from: playlist) ?? item.ownerURI
            let entries = playlist.content.flatMap(\.items) ?? []
            replaceTracks(entries.compactMap(CatalogMapping.playlistTrack(from:)))
            loadedSessionSnapshot = session.snapshot
            metadata.replaceTracks(tracks, from: .playlist)
            metadata.loadTrackAttributes(for: tracks)
        } catch {
            guard flight.shouldReport(error, for: handle), loadedURI == handle.key else { return }
            self.error = error.localizedDescription
        }
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        loadedURI == handle.key && flight.isCurrent(handle)
    }

    private func replaceTracks(_ tracks: [CatalogTrack]) {
        trackCollection.replace(tracks)
        totalDuration = tracks.reduce(0) { total, track in
            total + TimeInterval(roundedCatalogDurationSeconds(track.duration))
        }
    }
}

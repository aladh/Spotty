//
//  PlaylistMutationController.swift
//  Spotty
//
//  Account-scoped playlist add/remove. Reads stay on CatalogProviding; this type
//  is the only catalog write owner for playlist occurrences.
//

import SpottyDomain
import Foundation
import SpottyRuntimeContracts

@MainActor
@Observable
final class PlaylistMutationController {
    private typealias Flight = PlaylistMutationRuns

    @ObservationIgnored private let mutations: any PlaylistMutating
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let feedback: TransientFeedbackPresenter
    @ObservationIgnored private let playlistStore: PlaylistStore
    @ObservationIgnored private let homeLibrary: HomeLibraryStore
    @ObservationIgnored private let flight: Flight

    init(
        mutations: any PlaylistMutating,
        session: CatalogSessionAvailability,
        feedback: TransientFeedbackPresenter,
        playlistStore: PlaylistStore,
        homeLibrary: HomeLibraryStore
    ) {
        self.mutations = mutations
        self.session = session
        self.feedback = feedback
        self.playlistStore = playlistStore
        self.homeLibrary = homeLibrary
        flight = Flight(session: session)
    }

    var editableLibraryPlaylists: [CatalogItem] {
        PlaylistEditability.editablePlaylists(homeLibrary.currentPlaylists, profileURI: homeLibrary.currentProfileURI)
    }

    func reset() {
        flight.reset()
    }

    func isLibraryPlaylistEditable(_ item: CatalogItem) -> Bool {
        guard let current = homeLibrary.currentPlaylists.first(where: { $0.uri == item.uri }) else { return false }
        return PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: current.ownerURI,
            profileURI: homeLibrary.currentProfileURI
        )
    }

    func isOpenPlaylistEditable(_ item: CatalogItem) -> Bool {
        guard playlistStore.loadedURI == item.uri, playlistStore.canEditLoadedContent else { return false }
        return PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: playlistStore.ownerURI,
            profileURI: homeLibrary.currentProfileURI
        )
    }

    func addTracks(_ tracks: [CatalogTrack], to playlist: CatalogItem, accountEpoch: UInt64? = nil) {
        guard accountEpoch == nil || accountEpoch == session.accountEpoch else { return }
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        let uris = PlaylistMutationSelection.addURIs(from: tracks)
        guard
            PlaylistMutationSelection.canAdd(
                isTargetEditable: isLibraryPlaylistEditable(playlist),
                uris: uris
            )
        else { return }
        guard let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist") else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation(playlist: playlist) { handle in
            try await self.mutations.addToPlaylist(
                playlistId: playlistID, trackUris: uris,
                context: PlaylistMutationContext(session: handle.sessionSnapshot))
            await self.finishSuccessfulWrite(
                handle,
                playlist: playlist,
                message: Self.addedMessage(count: uris.count, playlistTitle: playlist.title)
            )
        }
    }

    func removeOccurrences(selectedIDs: Set<String>, from playlist: CatalogItem, accountEpoch: UInt64? = nil) {
        guard accountEpoch == nil || accountEpoch == session.accountEpoch else { return }
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        guard isOpenPlaylistEditable(playlist) else { return }
        let selected = PlaylistMutationSelection.orderedTracks(
            selectedIDs: selectedIDs,
            in: playlistStore.tracks
        )
        let uids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: selected)
        guard
            PlaylistMutationSelection.canRemove(
                isPlaylistEditable: true,
                occurrenceIDs: uids
            )
        else { return }
        guard playlistStore.loadedURI == playlist.uri,
            let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist")
        else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation(playlist: playlist) { handle in
            try await self.mutations.removeFromPlaylist(
                playlistId: playlistID, uids: uids,
                context: PlaylistMutationContext(session: handle.sessionSnapshot))
            await self.finishSuccessfulWrite(
                handle,
                playlist: playlist,
                message: Self.removedMessage(count: uids.count, playlistTitle: playlist.title)
            )
        }
    }

    private func startMutation(
        playlist: CatalogItem, _ work: @escaping @MainActor (Flight.Handle) async throws -> Void
    ) {
        flight.start { [weak self] handle in
            guard let self else { return }
            do {
                try await work(handle)
            } catch {
                // A lost response or cancellation can follow a committed write. Retire the
                // previous route authority even when a newer intent owns error presentation.
                if error as? PlaylistMutationFailure != .rejected,
                    self.flight.sessionIsCurrent(handle)
                {
                    self.playlistStore.invalidateRetainedPlaylist(playlist.uri)
                }
                // Reporting a failure is a latest-intent decision, so it uses the strict gate.
                guard self.flight.isLatest(handle) else { return }
                self.reportFailure(error)
            }
        }
    }

    private func finishSuccessfulWrite(
        _ handle: Flight.Handle,
        playlist: CatalogItem,
        message: String
    ) async {
        // A superseded or cancelled task may still observe a completed server write.
        // Refresh once for that write whenever the captured account/session is current.
        // Latest intent and cancellation do not establish whether an admitted write committed.
        guard flight.sessionIsCurrent(handle) else { return }
        playlistStore.invalidateRetainedPlaylist(playlist.uri)
        await reconcileIfOpen(playlist, for: handle)
        guard flight.sessionIsCurrent(handle) else { return }
        feedback.success(message)
    }

    private func reconcileIfOpen(_ playlist: CatalogItem, for handle: Flight.Handle) async {
        // A sent write can finish after its caller is cancelled. Its reconciling read has a
        // fresh task lifetime; recheck the captured account and route before read admission.
        await Task {
            guard flight.sessionIsCurrent(handle), playlistStore.loadedURI == playlist.uri else {
                return
            }
            await playlistStore.load(playlist, force: true)
        }.value
    }

    private func reportFailure(_ error: Error) {
        if isCancellation(error) { return }
        if error as? PlaylistMutationFailure == .rejected {
            feedback.failure("Spotify couldn’t change that playlist.")
            return
        }
        feedback.failure("Couldn’t update that playlist.")
    }

    private static func addedMessage(count: Int, playlistTitle: String) -> String {
        if count == 1 {
            return "Added to \(playlistTitle)"
        }
        return "Added \(count) songs to \(playlistTitle)"
    }

    private static func removedMessage(count: Int, playlistTitle: String) -> String {
        if count == 1 {
            return "Removed from \(playlistTitle)"
        }
        return "Removed \(count) songs from \(playlistTitle)"
    }
}

/// Writes never join readers. Session-valid outcomes reconcile even after a newer intent wins;
/// only the latest uncancelled intent may present an error.
@MainActor
private final class PlaylistMutationRuns {
    struct Handle {
        let id: UInt64
        let sessionSnapshot: CatalogSessionSnapshot
    }

    private let session: CatalogSessionAvailability
    private var nextID: UInt64 = 0
    private var task: Task<Void, Never>?

    init(session: CatalogSessionAvailability) { self.session = session }
    deinit { task?.cancel() }

    func reset() {
        nextID &+= 1
        task?.cancel()
        task = nil
    }

    func start(_ operation: @escaping @MainActor (Handle) async -> Void) {
        guard !Task.isCancelled, session.isAvailable else { return }
        reset()
        let handle = Handle(id: nextID, sessionSnapshot: session.snapshot)
        task = Task { [weak self] in
            defer { self?.complete(handle) }
            guard self?.isLatest(handle) == true else { return }
            await operation(handle)
        }
    }

    func sessionIsCurrent(_ handle: Handle) -> Bool {
        session.isAvailable && session.snapshot == handle.sessionSnapshot
    }

    func isLatest(_ handle: Handle) -> Bool {
        handle.id == nextID && !Task.isCancelled && sessionIsCurrent(handle)
    }

    private func complete(_ handle: Handle) {
        if handle.id == nextID { task = nil }
    }
}

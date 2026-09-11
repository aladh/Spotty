//
//  PlaylistMutationController.swift
//  Spotty
//
//  Account-scoped playlist add/remove. Reads stay on CatalogProviding; this type
//  is the only catalog write owner for playlist occurrences.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class PlaylistMutationController {
    private typealias Flight = AccountScopedSingleFlight<SingleFlightUnitKey>

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
        // A superseded or cancelled write may still have completed on the server, so the default
        // publish gate is session validity; the failure path opts into the strict gate.
        flight = Flight(session: session, join: .alwaysSupersede, scope: .singleSelection, publish: .sessionOnly)
    }

    var editableLibraryPlaylists: [CatalogItem] {
        PlaylistEditability.editablePlaylists(homeLibrary.playlists, profileURI: homeLibrary.profileURI)
    }

    func reset() {
        flight.reset()
    }

    func isLibraryPlaylistEditable(_ item: CatalogItem) -> Bool {
        PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: item.ownerURI,
            profileURI: homeLibrary.profileURI
        )
    }

    func isOpenPlaylistEditable(_ item: CatalogItem) -> Bool {
        let ownerURI =
            playlistStore.loadedURI == item.uri
            ? (playlistStore.ownerURI ?? item.ownerURI)
            : item.ownerURI
        return PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: ownerURI,
            profileURI: homeLibrary.profileURI
        )
    }

    func addTracks(_ tracks: [CatalogTrack], to playlist: CatalogItem) {
        let uris = PlaylistMutationSelection.addURIs(from: tracks)
        guard
            PlaylistMutationSelection.canAdd(
                isTargetEditable: isLibraryPlaylistEditable(playlist),
                uris: uris
            )
        else { return }
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        guard let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist") else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation { handle in
            try await self.mutations.addToPlaylist(playlistId: playlistID, trackUris: uris)
            await self.finishSuccessfulWrite(
                handle,
                playlist: playlist,
                message: Self.addedMessage(count: uris.count, playlistTitle: playlist.title)
            )
        }
    }

    func removeOccurrences(selectedIDs: Set<String>, from playlist: CatalogItem) {
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
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        guard playlistStore.loadedURI == playlist.uri,
            let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist")
        else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation { handle in
            try await self.mutations.removeFromPlaylist(playlistId: playlistID, uids: uids)
            await self.finishSuccessfulWrite(
                handle,
                playlist: playlist,
                message: Self.removedMessage(count: uids.count, playlistTitle: playlist.title)
            )
        }
    }

    private func startMutation(_ work: @escaping @MainActor (Flight.Handle) async throws -> Void) {
        let handle = flight.begin(.unit)
        flight.start(handle) { [weak self] in
            guard let self else { return }
            do {
                try await work(handle)
            } catch {
                // Reporting a failure is a latest-intent decision, so it uses the strict gate.
                guard self.flight.isCurrent(handle, policy: .strict) else { return }
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
        // requestID and Task.isCancelled are latest-intent gates, not session validity, so this
        // uses the flight's `.sessionOnly` publish policy.
        guard flight.isCurrent(handle) else { return }
        await reconcileIfOpen(playlist)
        guard flight.isCurrent(handle) else { return }
        feedback.success(message)
    }

    private func reconcileIfOpen(_ playlist: CatalogItem) async {
        guard playlistStore.loadedURI == playlist.uri else { return }
        await playlistStore.load(playlist, force: true)
    }

    private func reportFailure(_ error: Error) {
        if isCancellation(error) { return }
        if let apiError = error as? PartnerAPIError, case .mutationRejected = apiError {
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

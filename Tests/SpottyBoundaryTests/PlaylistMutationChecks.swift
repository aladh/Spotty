@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import Observation
import SpottyDomain
import Foundation
@testable import SpottyCore
import SpottyRuntimeContracts

private enum PlaylistMutationCheckFailure: Error {
    case unavailable
}

private actor ScriptedPlaylistServices: CatalogProviding, PlaylistMutating {
    // Bespoke on purpose: a check exercises reads and writes through a single collaborator, so it
    // must conform to both protocols at once, which the shared harness fakes do not do.
    var profile = CatalogProfileSnapshot(name: "Me", uri: "spotify:user:me")
    var library: [PlaylistLibraryNode] = []
    var playlistsByID: [String: CatalogPlaylistSnapshot] = [:]
    var playlistLoadCount = 0
    var libraryLoadCount = 0
    var addCalls: [(playlistId: String, uris: [String])] = []
    var removeCalls: [(playlistId: String, uids: [String])] = []
    var addError: (any Error)?
    var removeError: (any Error)?
    var playlistError: (any Error)?
    var parkPlaylistLoads = false
    private nonisolated let writes = HarnessResponseGate<Void>(cancellation: .ignored)
    private nonisolated let playlistReads = HarnessResponseGate<Void>(cancellation: .ignored)

    var isParked: Bool { writes.waiterCount > 0 }
    var parkedCount: Int { writes.waiterCount }
    var isPlaylistLoadParked: Bool { playlistReads.waiterCount > 0 }

    func hasParkedAdds(_ count: Int) -> Bool {
        addCalls.count == count && writes.waiterCount == count
    }

    func searchTracks(_: String, limit _: Int) async throws -> [CatalogTrack] {
        throw PlaylistMutationCheckFailure.unavailable
    }
    func home() async throws -> CatalogHomeSnapshot { throw PlaylistMutationCheckFailure.unavailable }
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        libraryLoadCount += 1
        return library
    }
    func libraryAlbums() async throws -> [CatalogItem] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryArtists() async throws -> [CatalogItem] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryTracks() async throws -> [CatalogTrack] { throw PlaylistMutationCheckFailure.unavailable }
    func profile() async throws -> CatalogProfileSnapshot { profile }
    func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        playlistLoadCount += 1
        if parkPlaylistLoads {
            try await playlistReads.wait()
        }
        if let playlistError { throw playlistError }
        guard let playlist = playlistsByID[id] else { throw PlaylistMutationCheckFailure.unavailable }
        return playlist
    }

    func addToPlaylist(playlistId: String, trackUris: [String], context _: PlaylistMutationContext) async throws {
        addCalls.append((playlistId, trackUris))
        if let addError { throw addError }
        try await writes.wait()
    }

    func removeFromPlaylist(playlistId: String, uids: [String], context _: PlaylistMutationContext) async throws {
        removeCalls.append((playlistId, uids))
        if let removeError { throw removeError }
        try await writes.wait()
    }

    func completePark() { writes.finish(()) }
    func failPark(_ error: any Error = CancellationError()) { writes.resolve(.failure(error)) }
    func completePlaylistPark() { playlistReads.finish(()) }
    func failPlaylistPark() { playlistReads.resolve(.failure(CancellationError())) }

    nonisolated func cancelPending() {
        writes.close()
        playlistReads.close()
    }

    func setAddError(_ error: (any Error)?) { addError = error }
    func setRemoveError(_ error: (any Error)?) { removeError = error }
    func setPlaylistError(_ error: (any Error)?) { playlistError = error }
    func setParkPlaylistLoads(_ enabled: Bool) { parkPlaylistLoads = enabled }
    func setLibrary(_ items: [PlaylistLibraryNode]) { library = items }
    func setPlaylist(_ playlist: CatalogPlaylistSnapshot, id: String) {
        playlistsByID[id] = playlist
    }

}

private func libraryItem(_ id: String, title: String, owner: String) -> CatalogItem {
    CatalogItem(
        id: id, uri: "spotify:playlist:\(id)", title: title, subtitle: owner == "me" ? "Me" : "Them",
        artworkURL: nil, kind: .playlist, ownerURI: "spotify:user:\(owner)")
}

private let ownedItem = libraryItem("owned", title: "Owned Mix", owner: "me")
private let foreignItem = libraryItem("foreign", title: "Foreign Mix", owner: "them")
private let ownedLibrary = PlaylistLibraryNode(playlist: ownedItem)
private let foreignLibrary = PlaylistLibraryNode(playlist: foreignItem)

private func occurrence(_ uid: String, track: String) -> CatalogTrack {
    CatalogTrack(
        id: uid, uri: "spotify:track:\(track)", title: track, artist: "", album: "", duration: 1,
        artworkURL: nil, addedAt: nil, occurrenceUID: uid)
}

private let ownedContents = CatalogPlaylistSnapshot(
    description: "", ownerURI: "spotify:user:me",
    tracks: [occurrence("uid-a", track: "dup"), occurrence("uid-b", track: "dup")], item: ownedItem)
private let ownedAfterRemoval = CatalogPlaylistSnapshot(
    description: "", ownerURI: "spotify:user:me", tracks: [occurrence("uid-b", track: "dup")], item: ownedItem)
private let ownedAfterAdd = CatalogPlaylistSnapshot(
    description: "", ownerURI: "spotify:user:me",
    tracks: ownedContents.tracks + [occurrence("uid-c", track: "new")], item: ownedItem)
private let foreignContents = CatalogPlaylistSnapshot(
    description: "", ownerURI: "spotify:user:them", tracks: [occurrence("uid-f", track: "other")], item: foreignItem)

@MainActor
private func makeCatalog(
    services: ScriptedPlaylistServices,
    session: CatalogSessionAvailability,
    feedback: TransientFeedbackPresenter
) -> CatalogStore {
    CatalogStore(
        provider: services,
        playlistMutations: services,
        session: session,
        clock: SystemPlaybackClock(),
        feedback: feedback
    )
}

@MainActor
private func loadedOwnedPlaylist(includeForeign: Bool = false) async throws -> (
    services: ScriptedPlaylistServices, session: CatalogSessionAvailability,
    feedback: TransientFeedbackPresenter, catalog: CatalogStore, item: CatalogItem
) {
    let services = ScriptedPlaylistServices()
    var library = [ownedLibrary]
    if includeForeign { library.append(foreignLibrary) }
    await services.setLibrary(library)
    await services.setPlaylist(ownedContents, id: "owned")
    let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
    let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .parked), duration: 4)
    let catalog = makeCatalog(services: services, session: session, feedback: feedback)
    await catalog.homeLibrary.loadProfile()
    await catalog.homeLibrary.loadPlaylists()
    let item = try #require(catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" })
    await catalog.playlistStore.load(item)
    return (services, session, feedback, catalog, item)
}

@MainActor
private func yieldPasses(_ count: Int = 200) async {
    for _ in 0..<count {
        await Task.yield()
    }
}

private func fixtureTrack(id: String, uri: String, duration: TimeInterval = 1) -> CatalogTrack {
    CatalogTrack(
        id: id,
        uri: uri,
        title: id,
        artist: "Artist",
        album: "Album",
        duration: duration,
        artworkURL: nil,
        addedAt: nil
    )
}

@Suite("Playlist Mutation")
struct PlaylistMutationTests {
    @Test
    @MainActor
    func productionCompositionReleasesItsQueryAndMutationOwners() {
        let services = ScriptedPlaylistServices()
        let session = CatalogSessionAvailability(isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked())
        defer { feedback.dismiss(); services.cancelPending() }
        var catalog: CatalogStore? = makeCatalog(services: services, session: session, feedback: feedback)
        weak let query = catalog?.playlistStore
        weak let mutations = catalog?.playlistMutations
        #expect(query != nil && mutations != nil)

        catalog = nil

        #expect(query == nil, "playlist composition must not retain a query/controller cycle")
        #expect(mutations == nil)
    }

    @Test(arguments: [false, true])
    @MainActor
    func admittedDuplicateRemovalInvalidatesItsRetainedRouteAfterNavigation(uncertain: Bool) async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist(includeForeign: true)
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        await services.setPlaylist(foreignContents, id: "foreign")
        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-b"], from: owned)
        try await requireEventually { await services.isParked }
        let removal = try #require(await services.removeCalls.first)
        #expect(removal.uids == ["uid-b"], "the sent write keeps the selected duplicate's server occurrence")
        await catalog.playlistStore.load(foreignItem)
        let foreignVersion = catalog.playlistStore.trackCollection.version
        let readsBeforeOutcome = await services.playlistLoadCount
        await services.setPlaylist(
            CatalogPlaylistSnapshot(
                description: "", ownerURI: "spotify:user:me",
                tracks: [occurrence("uid-a", track: "dup")], item: ownedItem),
            id: "owned")

        if uncertain {
            await services.failPark(PlaylistMutationFailure.failed)
        } else {
            await services.completePark()
        }
        try await requireEventually { feedback.message?.kind == (uncertain ? .failure : .success) }
        #expect(catalog.playlistStore.loadedURI == foreignItem.uri)
        #expect(catalog.playlistStore.trackCollection.version == foreignVersion)
        #expect(await services.playlistLoadCount == readsBeforeOutcome)
        catalog.playlistStore.prepare(owned)
        #expect(catalog.playlistStore.tracks.isEmpty, "a sent offscreen write invalidates its captured retained route")
        #expect(!catalog.playlistStore.canEditLoadedContent)

        await catalog.playlistStore.load(owned)

        #expect(catalog.playlistStore.tracks.map(\.id) == ["uid-a"])
        #expect(await services.playlistLoadCount == readsBeforeOutcome + 1)
        #expect(await services.removeCalls.count == 1, "returning to the route reconciles by reading")
    }

    @Test
    @MainActor
    func missingFreshOwnerCannotInheritEditAuthorityFromSelection() async throws {
        let services = ScriptedPlaylistServices()
        await services.setLibrary([ownedLibrary])
        let withoutOwner = CatalogPlaylistSnapshot(description: "", ownerURI: nil, tracks: ownedContents.tracks)
        await services.setPlaylist(withoutOwner, id: "owned")
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let catalog = makeCatalog(
            services: services, session: session, feedback: TransientFeedbackPresenter(clock: HarnessClock.sticky()))
        await catalog.homeLibrary.load()
        let selected = try #require(catalog.homeLibrary.playlists.first)
        await catalog.playlistStore.load(selected)
        #expect(catalog.playlistStore.tracks.count == 2)
        #expect(catalog.playlistStore.ownerURI == nil)
        #expect(!catalog.playlistMutations.isOpenPlaylistEditable(selected))
        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: selected)
        await yieldPasses()
        #expect(await services.removeCalls.isEmpty)
        catalog.playlistMutations.reset()
        if await services.isParked { await services.failPark() }
    }

    @Test
    @MainActor
    func reconnectRequiresCurrentLibraryAndProfileBeforeAdvertisingEdits() async throws {
        let services = ScriptedPlaylistServices()
        await services.setLibrary([ownedLibrary])
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let catalog = makeCatalog(
            services: services, session: session, feedback: TransientFeedbackPresenter(clock: HarnessClock.sticky()))
        await catalog.homeLibrary.load()
        let oldItem = try #require(catalog.homeLibrary.playlists.first)
        #expect(catalog.playlistMutations.isLibraryPlaylistEditable(oldItem))
        let observation = HarnessCounters()
        withObservationTracking {
            _ = catalog.playlistMutations.editableLibraryPlaylists
        } onChange: {
            observation.record("changed")
        }

        session.update(accountEpoch: 1, isAvailable: false)
        #expect(observation.count("changed") == 1, "Session changes must invalidate advertised menu capabilities")
        session.update(accountEpoch: 1, isAvailable: true)
        #expect(catalog.playlistMutations.editableLibraryPlaylists.isEmpty)
        #expect(!catalog.playlistMutations.isLibraryPlaylistEditable(oldItem))
        await catalog.homeLibrary.loadProfile()
        #expect(!catalog.playlistMutations.isLibraryPlaylistEditable(oldItem), "The library proof is still old")
        await services.setLibrary([])
        await catalog.homeLibrary.loadPlaylists()
        #expect(
            !catalog.playlistMutations.isLibraryPlaylistEditable(oldItem), "A retained menu cannot supply ownership")
        await services.setLibrary([ownedLibrary])
        await catalog.homeLibrary.loadPlaylists(force: true)
        #expect(catalog.playlistMutations.isLibraryPlaylistEditable(oldItem))
    }

    @Test(arguments: [0, 1, 2])
    @MainActor
    func uncertainWritesRetireRouteAuthorityWithoutReplayingTheMutation(outcome: Int) async throws {
        let services = ScriptedPlaylistServices()
        await services.setLibrary([ownedLibrary, foreignLibrary])
        await services.setPlaylist(ownedContents, id: "owned")
        await services.setPlaylist(foreignContents, id: "foreign")
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock.parked())
        defer { feedback.dismiss() }
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = try #require(catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" })
        let foreign = try #require(catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:foreign" })
        await catalog.playlistStore.load(owned)
        let rows = catalog.playlistStore.tracks
        #expect(catalog.playlistStore.canEditLoadedContent)

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "new", uri: "spotify:track:new")], to: owned, accountEpoch: 0)
        #expect(await services.addCalls.isEmpty, "An old menu cannot reinterpret rows under a new account")
        catalog.playlistMutations.addTracks([fixtureTrack(id: "new", uri: "spotify:track:new")], to: owned)
        await expectEventually { await services.isParked }
        let error: any Error
        switch outcome {
        case 0: error = PlaylistMutationFailure.failed
        case 1: error = CancellationError()
        default: error = PlaylistMutationFailure.rejected
        }
        await services.failPark(error)
        if outcome == 2 {
            await expectEventually { feedback.message?.kind == .failure }
            #expect(catalog.playlistStore.canEditLoadedContent)
        } else {
            await expectEventually { catalog.playlistStore.isShowingCachedContent }
            #expect(!catalog.playlistStore.canEditLoadedContent)
        }
        #expect(catalog.playlistStore.tracks == rows, "Uncertainty preserves useful rows while retiring authority")
        await catalog.playlistStore.load(foreign)
        let readsBeforeReturn = await services.playlistLoadCount
        await catalog.playlistStore.load(owned)
        #expect(await services.playlistLoadCount == readsBeforeReturn + (outcome == 2 ? 0 : 1))
        #expect(await services.addCalls.count == 1, "Reconciliation reads never replay the uncertain mutation")
    }

    @Test
    @MainActor
    func emptyPlaylistReusesCompleteResultsButRetriesFailedRefreshes() async throws {
        let services = ScriptedPlaylistServices()
        let emptyPlaylist = CatalogPlaylistSnapshot(description: "", ownerURI: "spotify:user:me", tracks: [])
        await services.setPlaylist(emptyPlaylist, id: "empty")
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .parked))
        defer { feedback.dismiss() }
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        let item = CatalogItem(
            id: "empty",
            uri: "spotify:playlist:empty",
            title: "Empty Mix",
            subtitle: "Me",
            artworkURL: nil,
            kind: .playlist,
            ownerURI: "spotify:user:me"
        )

        await catalog.playlistStore.load(item)
        await catalog.playlistStore.load(item)

        #expect((catalog.playlistStore.tracks) == ([]), "an empty playlist remains authoritatively empty")
        #expect(
            (await services.playlistLoadCount) == (1),
            "an empty playlist opened twice in one session fetches once"
        )

        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await catalog.playlistStore.load(item, force: true)
        #expect((catalog.playlistStore.error) != nil, "a failed forced refresh keeps the empty cached result stale")
        #expect((await services.playlistLoadCount) == (2), "the forced refresh attempts one playlist read")

        await services.setPlaylistError(nil)
        await catalog.playlistStore.load(item)
        #expect((catalog.playlistStore.error) == nil, "a later non-forced retry clears the refresh error")
        #expect((catalog.playlistStore.tracks) == ([]), "the successful retry remains authoritatively empty")
        #expect(
            (await services.playlistLoadCount) == (3),
            "a refresh error prevents the cached empty result from masking a later retry"
        )

        session.update(accountEpoch: 2, isAvailable: true)
        await catalog.playlistStore.load(item)
        #expect(
            (await services.playlistLoadCount) == (4),
            "an empty result from an earlier account session is fetched again"
        )
    }

    @Test
    @MainActor
    func addingTracksBatchesDuplicatesAndReconcilesOnlyOpenPlaylist() async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist(includeForeign: true)
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        #expect(
            (catalog.homeLibrary.profileURI) == ("spotify:user:me"), "profile URI is retained for write advertising"
        )
        #expect(
            (catalog.playlistMutations.editableLibraryPlaylists.map(\.uri)) == (["spotify:playlist:owned"]),
            "only owned library playlists are editable targets")

        let playlistLoadsBeforeAdd = await services.playlistLoadCount
        let duplicateURI = "spotify:track:dup"
        catalog.playlistMutations.addTracks(
            [
                fixtureTrack(id: "row-1", uri: duplicateURI),
                fixtureTrack(id: "row-2", uri: duplicateURI),
            ],
            to: owned
        )
        await expectEventually { await services.isParked }
        let addCall = await services.addCalls.first
        #expect((addCall?.playlistId) == ("owned"), "add uses the playlist id, not the URI")
        #expect((addCall?.uris) == ([duplicateURI, duplicateURI]), "one mutation carries every selected URI")

        await services.setPlaylist(ownedAfterAdd, id: "owned")
        await services.completePark()
        await expectEventually {
            catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]
                && feedback.message?.kind == .success
                && feedback.message?.text == "Added 2 songs to Owned Mix"
        }
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-b", "uid-c"]),
            "successful add refreshes the open playlist")
        #expect((feedback.message?.kind) == (.success), "successful add reports through the shared presenter")
        #expect((feedback.message?.text) == ("Added 2 songs to Owned Mix"), "successful add names the playlist")
        #expect(
            (await services.playlistLoadCount) == (playlistLoadsBeforeAdd + 1),
            "reconcile reloads only the open playlist")
        #expect((await services.libraryLoadCount) == (1), "library list is not reloaded after add")
    }

    @Test
    @MainActor
    func removingOccurrencePreservesOtherDuplicateAndRefusesForeignPlaylist() async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist()
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-b"]),
            "open playlist loads both duplicate occurrences")
        #expect(
            (catalog.playlistMutations.isOpenPlaylistEditable(owned)) == true,
            "owned open playlist is editable after load")

        let foreignPlaylist = foreignItem
        #expect(
            !catalog.playlistMutations.isLibraryPlaylistEditable(foreignPlaylist),
            "a foreign playlist is not an editable library target")
        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: foreignPlaylist)
        #expect((await services.removeCalls.count) == (0), "read-only playlists do not start a removal")

        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a", "uid-a"], from: owned)
        await expectEventually { await services.isParked }
        let removal = await services.removeCalls.first
        #expect((await services.removeCalls.count) == (1), "removal is one batched request")
        #expect((removal?.uids) == (["uid-a"]), "removal uses the selected Pathfinder UID")
        #expect(
            (removal?.uids.contains("spotify:track:dup") == false) == true,
            "removal does not send the duplicated track URI")

        await services.setPlaylist(ownedAfterRemoval, id: "owned")
        await services.completePark()
        await expectEventually {
            catalog.playlistStore.tracks.map(\.id) == ["uid-b"]
                && feedback.message?.text == "Removed from Owned Mix"
        }
        #expect((catalog.playlistStore.tracks.map(\.id)) == (["uid-b"]), "success refreshes only the open playlist")
        #expect(
            (catalog.playlistStore.tracks.first?.id) == ("uid-b"), "selection-stable remaining occurrence is uid-b")
        #expect(
            (feedback.message?.text) == ("Removed from Owned Mix"),
            "successful remove reports through the presenter")
        #expect((await services.libraryLoadCount) == (1), "library is not fully reloaded after remove")
    }

    @Test
    @MainActor
    func rejectionCancellationAndAccountChangeCannotPublishSuccess() async throws {
        let (services, session, feedback, catalog, owned) = try await loadedOwnedPlaylist()
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        await services.setAddError(PlaylistMutationFailure.rejected)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
        await expectEventually { feedback.message?.kind == .failure }
        #expect(
            (feedback.message?.text) == ("Spotify couldn’t change that playlist."),
            "typed rejection is a privacy-safe failure")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "rejection leaves the open playlist untouched")
        #expect(
            (feedback.message?.text.contains("spotify:") == false) == true,
            "rejection text does not include Spotify identifiers")

        await services.setAddError(nil)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
        await expectEventually { await services.isParked }
        catalog.playlistMutations.reset()
        await services.failPark()
        await yieldPasses()
        #expect(
            (feedback.message?.kind) == (.failure),
            "cancelled mutation does not replace the rejection message with success")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "cancelled mutation leaves tracks unchanged")

        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:stale")], to: owned)
        await expectEventually { await services.isParked }
        session.update(accountEpoch: 2, isAvailable: true)
        await services.completePark()
        await yieldPasses()
        #expect((feedback.message?.kind) == (.failure), "stale-account success does not present mutation feedback")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs),
            "stale-account success does not apply playlist rows")

        session.update(accountEpoch: 2, isAvailable: false)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:offline")], to: owned)
        #expect(
            (feedback.message?.text) == ("Connect Spotify before changing playlists."),
            "unavailable session reports a connect failure")
        #expect((await services.addCalls.count) == (3), "unavailable session does not send another write")
    }

    @Test
    @MainActor
    func overlappingWritesEachReconcileOnce() async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist()
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        let loadsBefore = await services.playlistLoadCount

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row-1", uri: "spotify:track:first")],
            to: owned
        )
        await expectEventually { await services.parkedCount == 1 }
        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row-2", uri: "spotify:track:second")],
            to: owned
        )
        await expectEventually { await services.hasParkedAdds(2) }
        let sentAdds = await services.addCalls
        #expect((sentAdds.count) == (2), "both overlapping writes are sent")
        #expect(
            (sentAdds.map(\.uris)) == ([["spotify:track:first"], ["spotify:track:second"]]),
            "first overlapping write keeps its batch")

        await services.setPlaylist(ownedAfterAdd, id: "owned")
        await services.completePark()
        await expectEventually { await services.playlistLoadCount == loadsBefore + 1 }
        await services.completePark()
        await expectEventually {
            await services.playlistLoadCount == loadsBefore + 2
                && feedback.message?.kind == .success
                && catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]
        }
        #expect(
            (await services.playlistLoadCount) == (loadsBefore + 2),
            "each completed overlapping write reloads the open playlist once")
        #expect((feedback.message?.kind) == (.success), "later overlapping success reports through the presenter")
        #expect(
            (catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]) == true,
            "stale account/session still blocked overlapping apply")
    }

    @Test
    @MainActor
    func committedAddSurvivesFailedReconciliationAndReadOnlyRetry() async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist()
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)
        let loadsBefore = await services.playlistLoadCount
        #expect((loadedIDs) == (["uid-a", "uid-b"]), "open playlist has nonempty rows before add")

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row", uri: "spotify:track:new")],
            to: owned
        )
        await expectEventually { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        await expectEventually {
            catalog.playlistStore.error != nil
                && feedback.message?.kind == .success
                && feedback.message?.text == "Added to Owned Mix"
        }
        #expect((feedback.message?.kind) == (.success), "committed add still reports mutation success")
        #expect((feedback.message?.text) == ("Added to Owned Mix"), "committed add still names the playlist")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs),
            "failed reload keeps the previous nonempty rows")
        #expect((catalog.playlistStore.error) != nil, "failed reload records a refresh error beside those rows")
        #expect((await services.addCalls.count) == (1), "failed reload does not send another add")
        #expect(
            (await services.playlistLoadCount) == (loadsBefore + 1), "forced reconcile attempted one playlist read")

        await catalog.playlistStore.load(owned, force: true)
        #expect((catalog.playlistStore.error) != nil, "retry failure keeps the stale-refresh error")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "retry failure still keeps the previous rows")
        #expect((await services.addCalls.count) == (1), "retry does not repeat the add")
        #expect(
            (await services.playlistLoadCount) == (loadsBefore + 2),
            "retry failure loads the open playlist once more")

        await services.setPlaylistError(nil)
        await services.setPlaylist(ownedAfterAdd, id: "owned")
        await catalog.playlistStore.load(owned, force: true)
        #expect((catalog.playlistStore.error) == nil, "successful retry clears the stale-refresh error")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-b", "uid-c"]),
            "successful retry replaces rows with the authoritative playlist")
        #expect((await services.addCalls.count) == (1), "successful retry still does not repeat the add")
        #expect((feedback.message?.kind) == (.success), "success toast is unchanged by retry")
    }

    @Test
    @MainActor
    func committedRemovalSurvivesFailedReconciliation() async throws {
        let (services, _, feedback, catalog, owned) = try await loadedOwnedPlaylist()
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: owned)
        await expectEventually { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        await expectEventually {
            catalog.playlistStore.error != nil
                && feedback.message?.text == "Removed from Owned Mix"
        }
        #expect((feedback.message?.kind) == (.success), "committed remove still reports mutation success")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs),
            "failed remove reload keeps previous nonempty rows"
        )
        #expect((catalog.playlistStore.error) != nil, "failed remove reload records a refresh error")
        #expect((await services.removeCalls.count) == (1), "failed remove reload does not send another removal")
    }

    @Test
    @MainActor
    func cancelledOrStaleReconciliationKeepsRowsUntilNavigation() async throws {
        let (services, session, feedback, catalog, owned) = try await loadedOwnedPlaylist(includeForeign: true)
        defer {
            catalog.reset()
            feedback.dismiss()
            services.cancelPending()
        }
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row", uri: "spotify:track:new")],
            to: owned
        )
        await expectEventually { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        await expectEventually { catalog.playlistStore.error != nil }
        #expect((catalog.playlistStore.error) != nil, "reconciliation failure plants the stale-refresh error")

        await services.setParkPlaylistLoads(true)
        let cancelledRetry = Task { await catalog.playlistStore.load(owned, force: true) }
        await expectEventually { await services.isPlaylistLoadParked }
        #expect((catalog.playlistStore.error) != nil, "force reload start keeps the stale-refresh error")
        cancelledRetry.cancel()
        await services.failPlaylistPark()
        await cancelledRetry.value
        #expect((catalog.playlistStore.error) != nil, "cancelled retry does not clear the stale-refresh error")
        #expect((catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "cancelled retry keeps previous rows")
        #expect((await services.addCalls.count) == (1), "cancelled retry does not repeat the add")

        await services.setPlaylist(ownedAfterAdd, id: "owned")
        await services.setPlaylistError(nil)
        let staleRetry = Task { await catalog.playlistStore.load(owned, force: true) }
        await expectEventually { await services.isPlaylistLoadParked }
        session.update(accountEpoch: 2, isAvailable: true)
        await services.completePlaylistPark()
        await staleRetry.value
        #expect((catalog.playlistStore.error) != nil, "stale-account retry does not clear the stale-refresh error")
        #expect(
            (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "stale-account retry does not apply newer rows"
        )
        #expect((await services.addCalls.count) == (1), "stale-account retry does not repeat the add")

        await services.setParkPlaylistLoads(false)
        let foreign = try #require(catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:foreign" })
        await services.setPlaylist(foreignContents, id: "foreign")
        await catalog.playlistStore.load(foreign)
        #expect(catalog.playlistStore.error == nil, "switching playlists clears the previous stale-refresh error")
        #expect(catalog.playlistStore.tracks.map(\.id) == ["uid-f"], "switching playlists loads the new playlist rows")
        #expect((await services.addCalls.count) == (1), "playlist switch does not send another add")
    }

    @Test
    @MainActor
    func refreshedPlaylistReplacesOccurrencesAndDurationEvenWhenRowCountMatches() async {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let item = CatalogItem(
            id: "owned", uri: "spotify:playlist:owned", title: "Owned", subtitle: "", artworkURL: nil,
            kind: .playlist)
        let first = fixtureTrack(id: "uid-a", uri: "spotify:track:a", duration: 1.49)
        let second = fixtureTrack(id: "uid-b", uri: "spotify:track:b", duration: 2.5)
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "", ownerURI: nil, tracks: [first, second])
        }
        await store.load(item)
        #expect(store.totalDuration == 4, "playlist store caches rounded track durations")
        let loadedVersion = store.trackCollection.version
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(
                description: "", ownerURI: nil,
                tracks: [first, fixtureTrack(id: "uid-mid", uri: "spotify:track:mid", duration: 3.6)])
        }
        await store.load(item, force: true)
        #expect(provider.playlistRequestCount == 2)
        #expect(store.tracks.count == 2, "replacement keeps the same row count")
        #expect(store.trackCollection.version != loadedVersion, "same-count replacement mints a new version")
        #expect(store.tracks.map(\.id) == ["uid-a", "uid-mid"], "rows follow the replacement identity")
        #expect(store.totalDuration == 5, "replacing rows refreshes the cached duration")
        store.reset()
        #expect(store.totalDuration == 0, "reset clears the cached duration")
    }
}

import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private enum PlaylistMutationCheckFailure: Error {
    case unavailable
}

private actor ScriptedPlaylistServices: CatalogProviding, PlaylistMutating {
    // Bespoke on purpose: a check exercises reads and writes through a single collaborator, so it
    // must conform to both protocols at once, which the shared harness fakes do not do.
    var profile = PathfinderProfile(username: "me", name: "Me", uri: "spotify:user:me", avatar: nil)
    var library: [PathfinderPlaylist] = []
    var playlistsByID: [String: PathfinderPlaylistUnion] = [:]
    var playlistLoadCount = 0
    var libraryLoadCount = 0
    var addCalls: [(playlistId: String, uris: [String])] = []
    var removeCalls: [(playlistId: String, uids: [String])] = []
    var addError: (any Error)?
    var removeError: (any Error)?
    var playlistError: (any Error)?
    var parkPlaylistLoads = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var playlistWaiters: [CheckedContinuation<Void, any Error>] = []

    var isParked: Bool { !waiters.isEmpty }
    var parkedCount: Int { waiters.count }
    var isPlaylistLoadParked: Bool { !playlistWaiters.isEmpty }

    func hasParkedAdds(_ count: Int) -> Bool {
        addCalls.count == count && waiters.count == count
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw PlaylistMutationCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw PlaylistMutationCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        libraryLoadCount += 1
        return library
    }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw PlaylistMutationCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { profile }
    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        playlistLoadCount += 1
        if parkPlaylistLoads {
            try await parkPlaylistLoad()
        }
        if let playlistError { throw playlistError }
        guard let playlist = playlistsByID[id] else { throw PlaylistMutationCheckFailure.unavailable }
        return playlist
    }

    func addToPlaylist(playlistId: String, trackUris: [String]) async throws {
        addCalls.append((playlistId, trackUris))
        if let addError { throw addError }
        try await park()
    }

    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        removeCalls.append((playlistId, uids))
        if let removeError { throw removeError }
        try await park()
    }

    func completePark() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func failPark() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(throwing: CancellationError())
    }

    func completePlaylistPark() {
        guard !playlistWaiters.isEmpty else { return }
        playlistWaiters.removeFirst().resume()
    }

    func failPlaylistPark() {
        guard !playlistWaiters.isEmpty else { return }
        playlistWaiters.removeFirst().resume(throwing: CancellationError())
    }

    func setAddError(_ error: (any Error)?) { addError = error }
    func setRemoveError(_ error: (any Error)?) { removeError = error }
    func setPlaylistError(_ error: (any Error)?) { playlistError = error }
    func setParkPlaylistLoads(_ enabled: Bool) { parkPlaylistLoads = enabled }
    func setLibrary(_ items: [PathfinderPlaylist]) { library = items }
    func setPlaylist(_ playlist: PathfinderPlaylistUnion) {
        if let id = playlist.id {
            playlistsByID[id] = playlist
        }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func parkPlaylistLoad() async throws {
        try await withCheckedThrowingContinuation { continuation in
            playlistWaiters.append(continuation)
        }
    }
}

private func decodePlaylist(_ json: String) throws -> PathfinderPlaylist {
    try JSONDecoder().decode(PathfinderPlaylist.self, from: Data(json.utf8))
}

private func decodePlaylistUnion(_ json: String) throws -> PathfinderPlaylistUnion {
    try JSONDecoder().decode(PathfinderPlaylistUnion.self, from: Data(json.utf8))
}

private let ownedLibraryJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
    """
private let foreignLibraryJSON = """
    {"uri":"spotify:playlist:foreign","name":"Foreign Mix","ownerV2":{"data":{"name":"Them","username":"them","uri":"spotify:user:them"}}}
    """
private let ownedContentsJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":2,"items":[{"uid":"uid-a","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let ownedAfterRemovalJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":1,"items":[{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let ownedAfterAddJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":3,"items":[{"uid":"uid-a","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-c","itemV2":{"data":{"uri":"spotify:track:new","name":"New","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let foreignContentsJSON = """
    {"uri":"spotify:playlist:foreign","name":"Foreign Mix","description":null,"ownerV2":{"data":{"username":"them","name":"Them","uri":"spotify:user:them"}},"content":{"totalCount":1,"items":[{"uid":"uid-f","itemV2":{"data":{"uri":"spotify:track:other","name":"Other","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let emptyContentsJSON = """
    {"uri":"spotify:playlist:empty","name":"Empty Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":0,"items":[]}}
    """

@MainActor
private func makeCatalog(
    services: ScriptedPlaylistServices,
    session: CatalogSessionAvailability,
    feedback: TransientFeedbackPresenter
) -> CatalogStore {
    CatalogStore(
        provider: services,
        attributesProvider: HarnessTrackAttributes(),
        playlistMutations: services,
        session: session,
        clock: SystemPlaybackClock(),
        feedback: feedback
    )
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
    func testPlaylistMutation() async {
        do {
            let services = ScriptedPlaylistServices()
            let emptyPlaylist: PathfinderPlaylistUnion
            do {
                emptyPlaylist = try decodePlaylistUnion(emptyContentsJSON)
                await services.setPlaylist(emptyPlaylist)
            } catch {
                #expect((false) == true, "empty playlist fixture decodes")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)))
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

        do {
            do {
                do {
                    let owned = try decodePlaylist(ownedLibraryJSON)
                    let mapped = CatalogMapping.item(from: owned)
                    #expect((mapped?.ownerURI) == ("spotify:user:me"), "library playlist keeps owner URI")
                    #expect((mapped?.subtitle) == ("Me"), "library playlist keeps the owner subtitle")

                    let foreign = try decodePlaylist(foreignLibraryJSON)
                    #expect(
                        (CatalogMapping.item(from: foreign)?.ownerURI) == ("spotify:user:them"),
                        "foreign playlist owner is preserved")

                    let union = try decodePlaylistUnion(ownedContentsJSON)
                    #expect(
                        (CatalogMapping.ownerURI(from: union)) == ("spotify:user:me"),
                        "open playlist owner URI is mapped from ownerV2")
                    let tracks = union.content?.items?.compactMap(CatalogMapping.playlistTrack(from:)) ?? []
                    #expect(
                        (tracks.map(\.id)) == (["uid-a", "uid-b"]),
                        "playlist rows use occurrence UIDs as CatalogTrack.id")
                    #expect(
                        (tracks.map(\.uri)) == (["spotify:track:dup", "spotify:track:dup"]),
                        "duplicate rows keep the same track URI")

                } catch {
                    Issue.record("\("library and detail playlist JSON decode"): unexpected error \(error)")
                }
            }
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([
                    decodePlaylist(ownedLibraryJSON),
                    decodePlaylist(foreignLibraryJSON),
                ])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "owned library fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)

            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            #expect(
                (catalog.homeLibrary.profileURI) == ("spotify:user:me"), "profile URI is retained for write advertising"
            )
            #expect(
                (catalog.playlistMutations.editableLibraryPlaylists.map(\.uri)) == (["spotify:playlist:owned"]),
                "only owned library playlists are editable targets")

            let owned = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" }
            #expect((owned) != nil, "owned playlist is in the library")
            guard let owned else {
                feedback.dismiss()
                return
            }
            await catalog.playlistStore.load(owned)
            let playlistLoadsBeforeAdd = await services.playlistLoadCount
            let duplicateURI = "spotify:track:dup"
            catalog.playlistMutations.addTracks(
                [
                    fixtureTrack(id: "row-1", uri: duplicateURI),
                    fixtureTrack(id: "row-2", uri: duplicateURI),
                ],
                to: owned
            )
            _ = await waitUntil { await services.isParked }
            let addCall = await services.addCalls.first
            #expect((addCall?.playlistId) == ("owned"), "add uses the playlist id, not the URI")
            #expect((addCall?.uris) == ([duplicateURI, duplicateURI]), "one mutation carries every selected URI")

            do {
                try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
            } catch {
                #expect((false) == true, "post-add playlist fixture decodes")
            }
            await services.completePark()
            _ = await waitUntil {
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
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "removal fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists[0]
            await catalog.playlistStore.load(owned)
            #expect(
                (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-b"]),
                "open playlist loads both duplicate occurrences")
            #expect(
                (catalog.playlistMutations.isOpenPlaylistEditable(owned)) == true,
                "owned open playlist is editable after load")

            let foreignPlaylist: CatalogItem?
            do {
                foreignPlaylist = CatalogMapping.item(from: try decodePlaylist(foreignLibraryJSON))
            } catch {
                foreignPlaylist = nil
                #expect((false) == true, "foreign playlist fixture decodes")
            }
            if let foreignPlaylist {
                #expect(
                    (!catalog.playlistMutations.isLibraryPlaylistEditable(foreignPlaylist)) == true,
                    "a foreign playlist is not an editable library target")
                catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: foreignPlaylist)
            }
            #expect((await services.removeCalls.count) == (0), "read-only playlists do not start a removal")

            catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a", "uid-a"], from: owned)
            _ = await waitUntil { await services.isParked }
            let removal = await services.removeCalls.first
            #expect((await services.removeCalls.count) == (1), "removal is one batched request")
            #expect((removal?.uids) == (["uid-a"]), "removal uses the selected Pathfinder UID")
            #expect(
                (removal?.uids.contains("spotify:track:dup") == false) == true,
                "removal does not send the duplicated track URI")

            do {
                try await services.setPlaylist(decodePlaylistUnion(ownedAfterRemovalJSON))
            } catch {
                #expect((false) == true, "post-remove playlist fixture decodes")
            }
            await services.completePark()
            _ = await waitUntil {
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
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "rejection fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists[0]
            await catalog.playlistStore.load(owned)
            let loadedIDs = catalog.playlistStore.tracks.map(\.id)

            await services.setAddError(PartnerAPIError.mutationRejected("addToPlaylist"))
            catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
            _ = await waitUntil { feedback.message?.kind == .failure }
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
            _ = await waitUntil { await services.isParked }
            catalog.playlistMutations.reset()
            await services.failPark()
            await yieldPasses()
            #expect(
                (feedback.message?.kind) == (.failure),
                "cancelled mutation does not replace the rejection message with success")
            #expect(
                (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "cancelled mutation leaves tracks unchanged")

            catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:stale")], to: owned)
            _ = await waitUntil { await services.isParked }
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
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "overlapping fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists[0]
            await catalog.playlistStore.load(owned)
            let loadsBefore = await services.playlistLoadCount

            catalog.playlistMutations.addTracks(
                [fixtureTrack(id: "row-1", uri: "spotify:track:first")],
                to: owned
            )
            _ = await waitUntil { await services.parkedCount == 1 }
            catalog.playlistMutations.addTracks(
                [fixtureTrack(id: "row-2", uri: "spotify:track:second")],
                to: owned
            )
            _ = await waitUntil { await services.hasParkedAdds(2) }
            let sentAdds = await services.addCalls
            #expect((sentAdds.count) == (2), "both overlapping writes are sent")
            #expect(
                (sentAdds.map(\.uris)) == ([["spotify:track:first"], ["spotify:track:second"]]),
                "first overlapping write keeps its batch")

            do {
                try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
            } catch {
                #expect((false) == true, "overlapping post-add fixture decodes")
            }
            await services.completePark()
            _ = await waitUntil { await services.playlistLoadCount == loadsBefore + 1 }
            await services.completePark()
            _ = await waitUntil {
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
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "add-reload fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists[0]
            await catalog.playlistStore.load(owned)
            let loadedIDs = catalog.playlistStore.tracks.map(\.id)
            let loadsBefore = await services.playlistLoadCount
            #expect((loadedIDs) == (["uid-a", "uid-b"]), "open playlist has nonempty rows before add")

            catalog.playlistMutations.addTracks(
                [fixtureTrack(id: "row", uri: "spotify:track:new")],
                to: owned
            )
            _ = await waitUntil { await services.isParked }
            await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
            await services.completePark()
            _ = await waitUntil {
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
            do {
                try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
            } catch {
                #expect((false) == true, "retry-success playlist fixture decodes")
            }
            await catalog.playlistStore.load(owned, force: true)
            #expect((catalog.playlistStore.error) == nil, "successful retry clears the stale-refresh error")
            #expect(
                (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-b", "uid-c"]),
                "successful retry replaces rows with the authoritative playlist")
            #expect((await services.addCalls.count) == (1), "successful retry still does not repeat the add")
            #expect((feedback.message?.kind) == (.success), "success toast is unchanged by retry")
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "remove-reload fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists[0]
            await catalog.playlistStore.load(owned)
            let loadedIDs = catalog.playlistStore.tracks.map(\.id)

            catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: owned)
            _ = await waitUntil { await services.isParked }
            await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
            await services.completePark()
            _ = await waitUntil {
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
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            do {
                try await services.setLibrary([
                    decodePlaylist(ownedLibraryJSON),
                    decodePlaylist(foreignLibraryJSON),
                ])
                try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
            } catch {
                #expect((false) == true, "stale-refresh fixtures decode")
                return
            }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)), duration: 4)
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            await catalog.homeLibrary.loadProfile()
            await catalog.homeLibrary.loadPlaylists()
            let owned = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" }
            #expect((owned) != nil, "owned playlist is in the library for stale-refresh checks")
            guard let owned else {
                feedback.dismiss()
                return
            }
            await catalog.playlistStore.load(owned)
            let loadedIDs = catalog.playlistStore.tracks.map(\.id)

            catalog.playlistMutations.addTracks(
                [fixtureTrack(id: "row", uri: "spotify:track:new")],
                to: owned
            )
            _ = await waitUntil { await services.isParked }
            await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
            await services.completePark()
            _ = await waitUntil { catalog.playlistStore.error != nil }
            #expect((catalog.playlistStore.error) != nil, "reconciliation failure plants the stale-refresh error")

            await services.setParkPlaylistLoads(true)
            let cancelledRetry = Task { await catalog.playlistStore.load(owned, force: true) }
            _ = await waitUntil { await services.isPlaylistLoadParked }
            #expect((catalog.playlistStore.error) != nil, "force reload start keeps the stale-refresh error")
            cancelledRetry.cancel()
            await services.failPlaylistPark()
            await cancelledRetry.value
            #expect((catalog.playlistStore.error) != nil, "cancelled retry does not clear the stale-refresh error")
            #expect((catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "cancelled retry keeps previous rows")
            #expect((await services.addCalls.count) == (1), "cancelled retry does not repeat the add")

            do {
                try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
            } catch {
                #expect((false) == true, "stale-identity playlist fixture decodes")
            }
            await services.setPlaylistError(nil)
            let staleRetry = Task { await catalog.playlistStore.load(owned, force: true) }
            _ = await waitUntil { await services.isPlaylistLoadParked }
            session.update(accountEpoch: 2, isAvailable: true)
            await services.completePlaylistPark()
            await staleRetry.value
            #expect((catalog.playlistStore.error) != nil, "stale-account retry does not clear the stale-refresh error")
            #expect(
                (catalog.playlistStore.tracks.map(\.id)) == (loadedIDs), "stale-account retry does not apply newer rows"
            )
            #expect((await services.addCalls.count) == (1), "stale-account retry does not repeat the add")

            await services.setParkPlaylistLoads(false)
            let foreign = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:foreign" }
            #expect((foreign) != nil, "foreign playlist is in the library for switch coverage")
            if let foreign {
                do {
                    try await services.setPlaylist(decodePlaylistUnion(foreignContentsJSON))
                } catch {
                    #expect((false) == true, "foreign playlist fixture decodes")
                }
                await catalog.playlistStore.load(foreign)
                #expect(
                    (catalog.playlistStore.error) == nil, "switching playlists clears the previous stale-refresh error")
                #expect(
                    (catalog.playlistStore.tracks.map(\.id)) == (["uid-f"]),
                    "switching playlists loads the new playlist rows")
            }
            #expect((await services.addCalls.count) == (1), "playlist switch does not send another add")
            feedback.dismiss()
        }

        do {
            let services = ScriptedPlaylistServices()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let feedback = TransientFeedbackPresenter(clock: HarnessClock(sleep: .suspend(3_600)))
            let catalog = makeCatalog(services: services, session: session, feedback: feedback)
            let first = fixtureTrack(id: "uid-a", uri: "spotify:track:a", duration: 1.49)
            let second = fixtureTrack(id: "uid-b", uri: "spotify:track:b", duration: 2.5)
            catalog.playlistStore.replaceLoadedPlaylist(uri: "spotify:playlist:owned", tracks: [first, second])
            #expect((catalog.playlistStore.totalDuration) == (4), "playlist store caches rounded track durations")
            let loadedVersion = catalog.playlistStore.trackCollection.version
            catalog.playlistStore.replaceLoadedPlaylist(
                uri: "spotify:playlist:owned",
                tracks: [first, fixtureTrack(id: "uid-mid", uri: "spotify:track:mid", duration: 3.6)]
            )
            #expect((catalog.playlistStore.tracks.count) == (2), "replacement keeps the same row count")
            #expect(
                (catalog.playlistStore.trackCollection.version != loadedVersion) == true,
                "same-count middle replacement mints a new version")
            #expect(
                (catalog.playlistStore.tracks.map(\.id)) == (["uid-a", "uid-mid"]),
                "authoritative rows follow the replacement identity")
            #expect((catalog.playlistStore.totalDuration) == (5), "replacing rows refreshes the cached duration")
            catalog.playlistStore.reset()
            #expect((catalog.playlistStore.totalDuration) == (0), "reset clears the cached duration")
        }

    }
}

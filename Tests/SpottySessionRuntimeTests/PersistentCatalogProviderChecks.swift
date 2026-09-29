@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import SpottyCatalogStorage
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

struct PersistentCatalogProviderTests {
    @Test(arguments: [false, true])
    func retiredAccountCannotReactivateEvenWhenActivationWasStillQueued(previouslyActive: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        if previouslyActive {
            await provider.activate(accountEpoch: 7)
            _ = try await provider.profile()
        }
        #expect(await provider.retire(accountEpoch: 7, purge: true))
        let calls = await source.profileCalls
        await provider.activate(accountEpoch: 7)
        await provider.activate(accountEpoch: 6)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        #expect(await source.profileCalls == calls, "retired admission never reaches the gateway")

        await provider.activate(accountEpoch: 8)
        _ = try await provider.profile()
        #expect(await source.profileCalls == calls + 1)
        #expect(await provider.retire(accountEpoch: 8, purge: true))
    }

    @Test func delayedRetirementCannotPurgeAReplacementAccountsContentOrSubscriptions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("replacement")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 2)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let subscription = try await provider.subscribeCatalogEntities([track("replacement").uri])
        var updates = subscription.updates.makeAsyncIterator()
        let change = try #require(await updates.next())

        #expect(await provider.retire(accountEpoch: 1, purge: true))
        await provider.activate(accountEpoch: 1)
        #expect(try await provider.cachedPlaylist(id: "one")?.tracks == [track("replacement")])
        let entities = try await provider.catalogEntities(for: change)
        #expect(entities[track("replacement").uri]?.title == track("replacement").title)
        #expect(await provider.retire(accountEpoch: 2, purge: true))
        #expect(await updates.next() == nil)
    }

    @Test(arguments: [false, true])
    func olderDetailRefreshCannotReplaceANewerResultEvenWithEqualClockSamples(album: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let oldTracks = [track("old")]
        let newTracks = [track("new"), track("new", occurrence: "duplicate")]
        if album {
            let gate = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
            defer { gate.close() }
            await source.holdAlbum(gate)
            let old = Task { try await provider.album(id: "one") }
            defer { old.cancel() }
            try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
            await source.setAlbum(.success(CatalogAlbumSnapshot(tracks: newTracks, releaseDate: "New")))
            _ = try await provider.album(id: "one")
            gate.finish(CatalogAlbumSnapshot(tracks: oldTracks, releaseDate: "Old"))
            #expect(try await old.value.tracks == oldTracks, "each live caller still receives its own result")
            let saved = try #require(try await provider.cachedAlbum(id: "one"))
            #expect(saved.tracks == newTracks)
            #expect(saved.releaseDate == "New")
        } else {
            let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
            defer { gate.close() }
            await source.holdPlaylist(gate)
            let old = Task { try await provider.playlist(id: "one") }
            defer { old.cancel() }
            try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
            await source.setPlaylist(.success(playlist(newTracks)))
            _ = try await provider.playlist(id: "one")
            gate.finish(playlist(oldTracks))
            #expect(try await old.value.tracks == oldTracks, "each live caller still receives its own result")
            #expect(try await provider.cachedPlaylist(id: "one")?.tracks == newTracks)
        }
        #expect(await provider.retire(accountEpoch: 1, purge: false))
        let reopened = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await reopened.activate(accountEpoch: 1)
        _ = try await reopened.profile()
        if album {
            #expect(try await reopened.cachedAlbum(id: "one")?.tracks == newTracks)
        } else {
            #expect(try await reopened.cachedPlaylist(id: "one")?.tracks == newTracks)
        }
        #expect(await reopened.retire(accountEpoch: 1, purge: true))
    }

    @Test func equalClockReadsAcrossCollectionsKeepTheNewestSharedMetadata() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func sharedTrack(_ title: String, occurrence: String) -> CatalogTrack {
            CatalogTrack(
                id: occurrence, uri: "spotify:track:shared", title: title, artist: "Artist", album: "Album",
                duration: 180, artworkURL: nil, addedAt: nil, occurrenceUID: occurrence)
        }
        let olderRows = [sharedTrack("Older", occurrence: "first"), sharedTrack("Older", occurrence: "second")]
        let newerRow = sharedTrack("Newer", occurrence: "album")
        let source = CatalogProviderSource(
            album: .success(CatalogAlbumSnapshot(tracks: [newerRow], releaseDate: "2026")))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let response = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { response.close() }
        await source.holdPlaylist(response)
        let older = Task { try await provider.playlist(id: "older") }
        defer { older.cancel() }
        try await requireEventually { response.waiterCount == 1 }
        _ = try await provider.album(id: "newer")
        let subscription = try await provider.subscribeCatalogEntities([newerRow.uri])
        await provider.acknowledgeCatalogEntities(subscription.token, revision: 0)
        response.finish(playlist(olderRows))
        #expect(try await older.value.tracks == olderRows, "A live caller still receives its own response")

        let retainedPlaylist = try #require(try await provider.cachedPlaylist(id: "older"))
        #expect(retainedPlaylist.tracks.map(\.id) == ["first", "second"])
        #expect(retainedPlaylist.tracks.map(\.occurrenceUID) == ["first", "second"])
        #expect(retainedPlaylist.tracks.map(\.title) == ["Newer", "Newer"])
        #expect(try await provider.cachedAlbum(id: "newer")?.tracks.first?.title == "Newer")
        let unchanged = try await provider.catalogEntities(
            for: CatalogEntityChange(token: subscription.token, revision: 0))
        #expect(unchanged.count == 0, "The older shared entity must not create a backward metadata notification")
        #expect(await provider.retire(accountEpoch: 1, purge: false))

        let freshRow = sharedTrack("Fresh lifetime", occurrence: "fresh")
        let freshSource = CatalogProviderSource(
            album: .success(CatalogAlbumSnapshot(tracks: [freshRow], releaseDate: "2026")))
        let reopened = PersistentCatalogProvider(source: freshSource, rootDirectory: root, clock: ProviderClock())
        await reopened.activate(accountEpoch: 1)
        _ = try await reopened.profile()
        #expect(try await reopened.cachedPlaylist(id: "older")?.tracks.map(\.title) == ["Newer", "Newer"])
        #expect(try await reopened.cachedAlbum(id: "newer")?.tracks.map(\.title) == ["Newer"])
        _ = try await reopened.album(id: "fresh")
        #expect(
            try await reopened.cachedPlaylist(id: "older")?.tracks.map(\.title) == ["Fresh lifetime", "Fresh lifetime"])
        #expect(try await reopened.cachedAlbum(id: "newer")?.tracks.map(\.title) == ["Fresh lifetime"])
        #expect(await reopened.retire(accountEpoch: 1, purge: true))
    }

    @Test func overlappingDifferentCollectionsRetainTheirIndependentResults() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdPlaylist(gate)
        let first = Task { try await provider.playlist(id: "one") }
        defer { first.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        await source.setPlaylist(.success(playlist([track("second")])))
        _ = try await provider.playlist(id: "two")
        await source.setAlbum(.success(CatalogAlbumSnapshot(tracks: [track("album")], releaseDate: "2026")))
        _ = try await provider.album(id: "one")
        gate.finish(playlist([track("first")]))
        _ = try await first.value
        #expect(try await provider.cachedPlaylist(id: "one")?.tracks == [track("first")])
        #expect(try await provider.cachedPlaylist(id: "two")?.tracks == [track("second")])
        #expect(try await provider.cachedAlbum(id: "one")?.tracks == [track("album")])
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func failedNewerRefreshDoesNotReadmitAnOlderCompletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("saved")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdPlaylist(gate)
        let old = Task { try await provider.playlist(id: "one") }
        defer { old.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        await source.setPlaylist(.failure(.offline))
        #expect(try await provider.playlist(id: "one").tracks == [track("saved")])
        gate.finish(playlist([track("superseded")]))
        _ = try await old.value
        #expect(try await provider.cachedPlaylist(id: "one")?.tracks == [track("saved")])
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func supersededLibraryRefreshCannotOverwriteTheNewestTree() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let gate = HarnessResponseGate<[PlaylistLibraryNode]>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdLibrary(gate)
        let old = Task { try await provider.playlistLibrary() }
        defer { old.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        await source.setLibrary([])
        #expect(try await provider.playlistLibrary().isEmpty)
        gate.finish([.init(playlist: try #require(playlist([]).item))])
        _ = try await old.value
        #expect(try await provider.cachedPlaylistLibrary()?.nodes == [])
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func savedLibraryRequiresAccountProofAndNeverRetainsEditPermission() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(playlist([]).item)
        let nodes = [PlaylistLibraryNode(folderURI: "folder:one", title: "Folder", children: [.init(playlist: item)])]
        let source = CatalogProviderSource()
        await source.setLibrary(nodes)
        let original = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await original.activate(accountEpoch: 1)
        _ = try await original.profile()
        #expect(try await original.playlistLibrary() == nodes)
        #expect(await original.retire(accountEpoch: 1, purge: false))

        let sameAccount = CatalogProviderSource()
        let reopened = PersistentCatalogProvider(source: sameAccount, rootDirectory: root)
        await reopened.activate(accountEpoch: 1)
        #expect(try await reopened.cachedPlaylistLibrary() == nil)
        _ = try await reopened.profile()
        let cached = try #require(try await reopened.cachedPlaylistLibrary())
        #expect(cached.nodes == nodes.map(\.withoutOwnership))
        #expect(cached.fetchedAt == ProviderClock.instant)
        #expect(await sameAccount.libraryCalls == 0, "the saved read never waits for the live library")
        #expect(await reopened.retire(accountEpoch: 1, purge: false))

        let other = PersistentCatalogProvider(
            source: CatalogProviderSource(
                profile: CatalogProfileSnapshot(name: "Other", uri: "spotify:user:other")), rootDirectory: root)
        await other.activate(accountEpoch: 1)
        _ = try await other.profile()
        #expect(try await other.cachedPlaylistLibrary() == nil)
        #expect(await other.retire(accountEpoch: 1, purge: true))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await other.cachedPlaylistLibrary() }
    }

    @Test func lateLibraryRefreshCannotPersistAfterRetirement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let gate = HarnessResponseGate<[PlaylistLibraryNode]>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdLibrary(gate)
        let pending = Task { try await provider.playlistLibrary() }
        defer { pending.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        gate.finish([.init(playlist: try #require(playlist([]).item))])
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await pending.value }
        let replacement = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await replacement.activate(accountEpoch: 1)
        _ = try await replacement.profile()
        #expect(try await replacement.cachedPlaylistLibrary() == nil)
        #expect(await replacement.retire(accountEpoch: 1, purge: true))
    }

    @Test func inactiveProviderRejectsReadsBeforeCallingTheGateway() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.playlist(id: "one") }
        #expect(await source.profileCalls == 0)
        #expect(await source.playlistCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cachedRoutesRequireFreshAccountProofAfterReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = [track("one"), track("one", occurrence: "duplicate"), track("two")]
        let playlist = playlist(tracks)
        let artist = CatalogItem(
            id: "credit", uri: "spotify:artist:credit", title: "Album Artist", subtitle: "Artist",
            artworkURL: nil, kind: .artist)
        let album = CatalogAlbumSnapshot(
            tracks: tracks, releaseDate: "2026-09-01", playCounts: [tracks[0].uri: 9_876_543_210], artists: [artist])
        let source = CatalogProviderSource(playlist: .success(playlist), album: .success(album))
        let original = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await original.activate(accountEpoch: 1)
        _ = try await original.profile()
        #expect(try await original.playlist(id: "one") == playlist)
        #expect(try await original.album(id: "one") == album)
        #expect(await original.retire(accountEpoch: 1, purge: false))

        let offline = CatalogProviderSource()
        let reopened = PersistentCatalogProvider(source: offline, rootDirectory: root)
        await reopened.activate(accountEpoch: 1)
        // A disk partition is not evidence that this process holds that account's grant.
        #expect(try await reopened.cachedPlaylist(id: "one") == nil)
        #expect(try await reopened.cachedAlbum(id: "one") == nil)
        await #expect(throws: CatalogReadFailure.offline) { try await reopened.playlist(id: "one") }
        _ = try await reopened.profile()
        let savedPlaylist = try #require(try await reopened.cachedPlaylist(id: "one"))
        let savedAlbum = try #require(try await reopened.cachedAlbum(id: "one"))
        #expect(await offline.playlistCalls == 1, "saved reads do not wait for or issue a gateway request")
        let cachedPlaylist = try await reopened.playlist(id: "one")
        #expect(cachedPlaylist == savedPlaylist)
        #expect(cachedPlaylist.tracks == tracks)
        #expect(cachedPlaylist.description == playlist.description)
        #expect(cachedPlaylist.freshness == .cached(fetchedAt: ProviderClock.instant))
        #expect(cachedPlaylist.ownerURI == nil)
        #expect(cachedPlaylist.item?.ownerURI == nil)
        #expect(cachedPlaylist.item?.title == playlist.item?.title)
        let cachedAlbum = try await reopened.album(id: "one")
        #expect(cachedAlbum == savedAlbum)
        #expect(cachedAlbum.tracks == tracks)
        #expect(cachedAlbum.releaseDate == album.releaseDate)
        #expect(cachedAlbum.playCounts == album.playCounts)
        #expect(cachedAlbum.artists == [artist])
        #expect(cachedAlbum.freshness == .cached(fetchedAt: ProviderClock.instant))
        #expect(await reopened.retire(accountEpoch: 1, purge: true))
    }

    @Test func credentialRefusalFencesSavedDetailsUntilProfileIsVerifiedAgain() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = [track("one")]
        let source = CatalogProviderSource(
            playlist: .success(playlist(tracks)),
            album: .success(CatalogAlbumSnapshot(tracks: tracks, releaseDate: "2026")))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        _ = try await provider.album(id: "one")
        _ = try await provider.playlistLibrary()
        await source.setPlaylist(.failure(.sessionExpired))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.playlist(id: "one") }
        #expect(try await provider.cachedPlaylist(id: "one") == nil)
        #expect(try await provider.cachedAlbum(id: "one") == nil)
        #expect(try await provider.cachedPlaylistLibrary() == nil)
        _ = try await provider.profile()
        #expect(try await provider.cachedPlaylist(id: "one")?.tracks == tracks)
        #expect(try await provider.cachedAlbum(id: "one")?.tracks == tracks)
        #expect(try await provider.cachedPlaylistLibrary()?.nodes == [])
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.cachedPlaylist(id: "one") }
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.cachedAlbum(id: "one") }
    }

    @Test func verifiedAccountsCannotReadEachOthersRetainedRoutes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountA = CatalogProviderSource(playlist: .success(playlist([track("account-a-only")])))
        let first = PersistentCatalogProvider(source: accountA, rootDirectory: root)
        await first.activate(accountEpoch: 1)
        _ = try await first.profile()
        _ = try await first.playlist(id: "one")
        #expect(await first.retire(accountEpoch: 1, purge: false))

        let accountB = CatalogProviderSource(profile: CatalogProfileSnapshot(name: "B", uri: "spotify:user:account-b"))
        let second = PersistentCatalogProvider(source: accountB, rootDirectory: root)
        await second.activate(accountEpoch: 1)
        _ = try await second.profile()
        #expect(try await second.cachedPlaylist(id: "one") == nil)
        #expect(try await second.cachedAlbum(id: "one") == nil)
        await #expect(throws: CatalogReadFailure.offline) { try await second.playlist(id: "one") }
        #expect(await second.retire(accountEpoch: 1, purge: false))

        let sameAccount = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await sameAccount.activate(accountEpoch: 1)
        _ = try await sameAccount.profile()
        #expect(try await sameAccount.playlist(id: "one").tracks == [track("account-a-only")])
        #expect(await sameAccount.retire(accountEpoch: 1, purge: true))
    }

    @Test func coldLogoutPurgesRetainedContentBeforeAnyProfileProof() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PersistentCatalogProvider(
            source: CatalogProviderSource(playlist: .success(playlist([track("retained")]))), rootDirectory: root
        )
        await original.activate(accountEpoch: 1)
        _ = try await original.profile()
        _ = try await original.playlist(id: "one")
        #expect(await original.retire(accountEpoch: 1, purge: false))

        let coldSource = CatalogProviderSource()
        let cold = PersistentCatalogProvider(source: coldSource, rootDirectory: root)
        #expect(await cold.retire(accountEpoch: 1, purge: true))
        #expect(await coldSource.profileCalls == 0)

        let reopened = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await reopened.activate(accountEpoch: 1)
        _ = try await reopened.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await reopened.playlist(id: "one") }
        #expect(await reopened.retire(accountEpoch: 1, purge: true))
    }

    @Test func cachedRestorePreservesTheCompleteOrderedCollection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = (0..<503).map { track("row-\($0)") } + [track("row-0", occurrence: "duplicate")]
        let source = CatalogProviderSource(playlist: .success(playlist(tracks)))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(.offline))
        #expect(try await provider.playlist(id: "one").tracks == tracks)
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func coldCleanupCannotEraseAnActiveOwnerOrReopenAdmissionAfterFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = PersistentCatalogProvider(
            source: CatalogProviderSource(playlist: .success(playlist([track("active")]))), rootDirectory: root
        )
        await active.activate(accountEpoch: 1)
        _ = try await active.profile()
        _ = try await active.playlist(id: "one")

        let cold = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        #expect(await cold.retire(accountEpoch: 1, purge: true) == false)
        await cold.activate(accountEpoch: 1)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await cold.profile() }
        #expect(try await active.playlist(id: "one").tracks == [track("active")])
        #expect(await active.retire(accountEpoch: 1, purge: false))
        #expect(await cold.retire(accountEpoch: 1, purge: true))
        await cold.activate(accountEpoch: 2)
        _ = try await cold.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await cold.playlist(id: "one") }
        #expect(await cold.retire(accountEpoch: 2, purge: true))
    }

    @Test(arguments: [nil, "", "spotify:user:", "spotify:playlist:one"])
    func unverifiedProfileNeverCreatesPersistentAccountContent(uri: String?) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = playlist([track("one")])
        let source = CatalogProviderSource(
            profile: CatalogProfileSnapshot(name: "Unknown", uri: uri), playlist: .success(value)
        )
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        #expect(try await provider.playlist(id: "one") == value)
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test(arguments: [CatalogReadFailure.offline, .timedOut, .throttled])
    func transientFailuresCanUseRetainedBrowsingWithoutWritePermission(failure: CatalogReadFailure) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(failure))
        let cached = try await provider.playlist(id: "one")
        #expect(cached.tracks == [track("one")])
        #expect(!cached.freshness.isCurrent)
        #expect(cached.ownerURI == nil)
        #expect(cached.item?.ownerURI == nil)
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test(arguments: [CatalogReadFailure.sessionExpired, .compatibility, .unavailable])
    func credentialAndCompatibilityFailuresDoNotDisappearBehindCachedContent(failure: CatalogReadFailure) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(failure))
        await #expect(throws: failure) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func suspendedReadCannotPublishOrPersistAfterRetirement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("before-retirement")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdPlaylist(gate)
        let pending = Task { try await provider.playlist(id: "one") }
        defer { pending.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        gate.finish(playlist([track("late-result")]))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await pending.value }

        let replacement = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await replacement.activate(accountEpoch: 1)
        _ = try await replacement.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await replacement.playlist(id: "one") }
        #expect(await replacement.retire(accountEpoch: 1, purge: true))
    }

    @Test func suspendedAccountProofCannotBindARetiredLifetime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let gate = HarnessResponseGate<CatalogProfileSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        await source.holdProfile(gate)
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        let pending = Task { try await provider.profile() }
        defer { pending.cancel() }
        try await requireEventually(description: "catalog read admitted") { gate.waiterCount == 1 }
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        gate.finish(CatalogProfileSnapshot(name: "Late", uri: "spotify:user:account-a"))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await pending.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [nil, "spotify:user:account-b"])
    func accountMismatchRequiresRetirementBeforeActivationCanResume(replacementURI: String?) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("account-a-only")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setProfile(CatalogProfileSnapshot(name: "B", uri: replacementURI))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        await provider.activate(accountEpoch: 1)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        await provider.activate(accountEpoch: 2)
        _ = try await provider.profile()
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(accountEpoch: 2, purge: true))
    }

    @Test func failedCleanupKeepsAdmissionClosedUntilPurgeCanBeRetried() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let directory = try #require(directories.first)
        // A non-regular sidecar is a deterministic cleanup failure; no system permissions change.
        let obstruction = directory.appendingPathComponent("catalog.sqlite-journal")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        #expect(await provider.retire(accountEpoch: 1, purge: true) == false)
        await provider.activate(accountEpoch: 1)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        #expect(await provider.retire(accountEpoch: 1, purge: false) == false)
        try FileManager.default.removeItem(at: obstruction)
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        await provider.activate(accountEpoch: 2)
        _ = try await provider.profile()
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(accountEpoch: 2, purge: true))
    }

    private func playlist(_ tracks: [CatalogTrack]) -> CatalogPlaylistSnapshot {
        CatalogPlaylistSnapshot(
            description: "Retained description", ownerURI: "spotify:user:account-a", tracks: tracks,
            item: CatalogItem(
                id: "one", uri: "spotify:playlist:one", title: "Retained playlist", subtitle: "Account A",
                artworkURL: nil, kind: .playlist, ownerURI: "spotify:user:account-a"
            )
        )
    }

    private func track(_ id: String, occurrence: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: occurrence ?? id, uri: "spotify:track:\(id)", title: id, artist: "Fixture artist",
            album: "Fixture album",
            duration: 180, artworkURL: nil, addedAt: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spotty-provider-check-\(UUID().uuidString)")
    }
}

// The desktop HarnessCatalog lives in SpottyBoundaryTests and cannot be imported by the headless
// runtime suite. This fake exposes only contract reads and deterministic suspended responses.
private actor CatalogProviderSource: CatalogProviding {
    private(set) var profileCalls = 0
    private(set) var playlistCalls = 0
    private(set) var libraryCalls = 0
    private var library: [PlaylistLibraryNode] = []
    private var libraryGate: HarnessResponseGate<[PlaylistLibraryNode]>?
    private var profileValue: CatalogProfileSnapshot
    private var playlistResult: Result<CatalogPlaylistSnapshot, CatalogReadFailure>
    private var albumResult: Result<CatalogAlbumSnapshot, CatalogReadFailure>
    private var playlistGate: HarnessResponseGate<CatalogPlaylistSnapshot>?
    private var profileGate: HarnessResponseGate<CatalogProfileSnapshot>?
    private var albumGate: HarnessResponseGate<CatalogAlbumSnapshot>?

    init(
        profile: CatalogProfileSnapshot = CatalogProfileSnapshot(name: "Account A", uri: "spotify:user:account-a"),
        playlist: Result<CatalogPlaylistSnapshot, CatalogReadFailure> = .failure(.offline),
        album: Result<CatalogAlbumSnapshot, CatalogReadFailure> = .failure(.offline)
    ) {
        profileValue = profile
        playlistResult = playlist
        albumResult = album
    }

    func setPlaylist(_ value: Result<CatalogPlaylistSnapshot, CatalogReadFailure>) {
        playlistResult = value
        playlistGate = nil
    }
    func setAlbum(_ value: Result<CatalogAlbumSnapshot, CatalogReadFailure>) {
        albumResult = value
        albumGate = nil
    }
    func holdAlbum(_ gate: HarnessResponseGate<CatalogAlbumSnapshot>) { albumGate = gate }
    func setProfile(_ value: CatalogProfileSnapshot) { profileValue = value }
    func holdPlaylist(_ gate: HarnessResponseGate<CatalogPlaylistSnapshot>) { playlistGate = gate }
    func holdProfile(_ gate: HarnessResponseGate<CatalogProfileSnapshot>) { profileGate = gate }
    func setLibrary(_ nodes: [PlaylistLibraryNode]) { library = nodes; libraryGate = nil }
    func holdLibrary(_ gate: HarnessResponseGate<[PlaylistLibraryNode]>) { libraryGate = gate }

    func profile() async throws -> CatalogProfileSnapshot {
        profileCalls += 1
        if let profileGate { return try await profileGate.wait() }
        return profileValue
    }
    func playlist(id _: String) async throws -> CatalogPlaylistSnapshot {
        playlistCalls += 1
        if let playlistGate { return try await playlistGate.wait() }
        return try playlistResult.get()
    }
    func album(id _: String) async throws -> CatalogAlbumSnapshot {
        if let albumGate { return try await albumGate.wait() }
        return try albumResult.get()
    }
    func searchTracks(_: String, limit _: Int) -> [CatalogTrack] { [] }
    func home() -> CatalogHomeSnapshot { CatalogHomeSnapshot(greeting: "Hello", sections: []) }
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        libraryCalls += 1
        if let libraryGate { return try await libraryGate.wait() }
        return library
    }
    func libraryAlbums() -> [CatalogItem] { [] }
    func libraryArtists() -> [CatalogItem] { [] }
    func libraryTracks() -> [CatalogTrack] { [] }
}

private struct ProviderClock: PlaybackClock {
    static let instant = Date(timeIntervalSince1970: 1_780_000_000)
    func now() -> Date { Self.instant }
    func sleep(seconds _: TimeInterval) async throws { throw CatalogProviderCapabilityError.unsupported }
}

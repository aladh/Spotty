@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Retained Catalog Entity Observation")
@MainActor
struct CatalogEntityObservationTests {
    @Test func albumEnrichmentUpdatesRetainedPlaylistWithoutReplacingItsOccurrencesOrUnrelatedRows() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let uri = "spotify:track:shared"
        let first = track(
            uri, title: "Original", id: "display1", uid: "server1", addedAt: Date(timeIntervalSince1970: 1))
        let duplicate = track(uri, title: "Original", id: "display2", addedAt: Date(timeIntervalSince1970: 2))
        let other = track("spotify:track:other", title: "Other")
        let enriched = track(
            uri, title: "Enriched", id: "entity", uid: "notOccurrence", addedAt: Date(timeIntervalSince1970: 99))
        provider.onPlaylist = { id in
            CatalogPlaylistSnapshot(
                description: id, ownerURI: "spotify:user:owner", tracks: id == "first" ? [first, duplicate] : [other])
        }
        provider.onAlbum = { _ in
            await queries.publish([enriched])
            return CatalogAlbumSnapshot(tracks: [enriched], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let playlist = PlaylistStore(provider: provider, metadata: metadata, session: session)
        let album = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        defer { playlist.reset(); album.reset() }
        await playlist.load(item("first", kind: .playlist))
        await playlist.load(item("other", kind: .playlist))
        try await requireEventually { await queries.activeQueryCount == 1 }
        let unrelatedVersion = playlist.trackCollection.version
        await album.load(item("album", kind: .album))
        try await requireEventually { await queries.acknowledgementCount >= 2 }
        #expect(playlist.trackCollection.version == unrelatedVersion)
        playlist.prepare(item("first", kind: .playlist))
        #expect(playlist.tracks.map(\.title) == ["Enriched", "Enriched"])
        #expect(playlist.tracks.map(\.id) == ["display1", "display2"])
        #expect(playlist.tracks.map(\.occurrenceUID) == ["server1", nil])
        #expect(playlist.tracks.map(\.addedAt) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
        #expect(playlist.canEditLoadedContent)
        #expect(playlist.ownerURI == "spotify:user:owner")
        await playlist.load(item("first", kind: .playlist))
        #expect(provider.playlistRequestCount == 2)
        playlist.reset()
        album.reset()
        try await requireEventually { await queries.activeQueryCount == 0 }
    }

    @Test func identicalEntityMetadataKeepsCollectionVersionAndCachedAuthority() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let row = track(
            "spotify:track:first", title: "First", id: "display", uid: "server", addedAt: HarnessDates.fixed)
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(
                description: "Saved", ownerURI: "spotify:user:owner", tracks: [row],
                freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylist(provider, session: session)
        defer { store.reset() }
        await store.load(item("first", kind: .playlist))
        try await requireEventually { await queries.activeQueryCount == 1 }
        let originalVersion = store.trackCollection.version
        await queries.publish([
            track(row.uri, title: "First", id: "different", uid: "irrelevant", addedAt: Date(timeIntervalSince1970: 99))
        ])
        try await requireEventually { await queries.acknowledgementCount == 1 }
        #expect(store.trackCollection.version == originalVersion)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        store.reset()
    }

    @Test func entityChangesPublishOnlyAfterTheCompleteRead() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let original = (0...500).map { track("spotify:track:\($0)", title: "Original") }
        let changed = original.map { track($0.uri, title: "Changed") }
        provider.onAlbum = { _ in CatalogAlbumSnapshot(tracks: original, releaseDate: "2026") }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        defer { store.reset() }
        await store.load(item("album", kind: .album))
        try await requireEventually { await queries.activeQueryCount == 1 }
        let originalVersion = store.trackCollection.version
        let completion = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { completion.close() }
        await queries.delayNextRead(until: completion)
        await queries.publish(changed)
        try await requireEventually { completion.waiterCount == 1 }
        #expect(store.trackCollection.version == originalVersion)
        #expect(store.tracks.allSatisfy { $0.title == "Original" })
        completion.finish(())
        try await requireEventually { await queries.acknowledgementCount == 1 }
        #expect(store.tracks.allSatisfy { $0.title == "Changed" })
        #expect(store.tracks.map(\.uri) == original.map(\.uri))
        store.reset()
    }

    @Test func accountReplacementRejectsAnUncooperativeEntityReadAndRetiresItsQuery() async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let original = track("spotify:track:first", title: "Original")
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "First", ownerURI: nil, tracks: [original])
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makePlaylist(provider, session: session)
        defer { store.reset() }
        await store.load(item("first", kind: .playlist))
        try await requireEventually { await queries.activeQueryCount == 1 }
        let completion = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { completion.close() }
        await queries.delayNextRead(until: completion)
        await queries.publish([track(original.uri, title: "Retired")])
        try await requireEventually { completion.waiterCount == 1 }
        session.update(accountEpoch: 2, isAvailable: true)
        store.prepare(item("first", kind: .playlist))
        completion.finish(())
        try await requireEventually { await queries.unsubscribeCount == 1 }
        #expect(await queries.acknowledgementCount == 0)
        #expect(store.tracks.isEmpty)
        #expect(store.description.isEmpty)
        store.prepare(item("other", kind: .playlist))
        store.prepare(item("first", kind: .playlist))
        #expect(store.tracks.isEmpty)
    }

    @Test(arguments: [CatalogItem.Kind.playlist, .album])
    func completeResultRetiresAnAlreadyReturnedReadFromThePreviousQuery(kind: CatalogItem.Kind) async throws {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let original = track("spotify:track:first", title: "Original")
        let fresh = track(original.uri, title: "Fresh server result")
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "First", ownerURI: nil, tracks: [original])
        }
        provider.onAlbum = { _ in CatalogAlbumSnapshot(tracks: [original], releaseDate: "2026") }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let playlist = PlaylistStore(provider: provider, metadata: metadata, session: session)
        let album = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        defer { playlist.reset(); album.reset() }
        let selected = item("first", kind: kind)
        let load: @MainActor (Bool) async -> Void = { force in
            if kind == .playlist {
                await playlist.load(selected, force: force)
            } else {
                await album.load(selected, force: force)
            }
        }
        let rows: @MainActor () -> [CatalogTrack] = { kind == .playlist ? playlist.tracks : album.tracks }
        await load(false)
        try await requireEventually { await queries.activeQueryCount == 1 }
        let completion = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { completion.close() }
        await queries.delayNextRead(until: completion)
        await queries.publish([track(original.uri, title: "Old retained metadata")])
        try await requireEventually { completion.waiterCount == 1 }

        // The new live read succeeds while its storage write disables query admission. Finishing
        // the stream alone cannot revoke the old read already suspended in the presentation path.
        await queries.finishStreams()
        await queries.failNextSubscription()
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "Fresh", ownerURI: nil, tracks: [fresh])
        }
        provider.onAlbum = { _ in CatalogAlbumSnapshot(tracks: [fresh], releaseDate: "2026") }
        await load(true)
        #expect(rows() == [fresh])
        try await requireEventually { await queries.subscriptionAttemptCount == 2 }
        completion.finish(())
        try await requireEventually { await queries.unsubscribeCount == 1 }
        #expect(await queries.acknowledgementCount == 0)
        #expect(rows() == [fresh])
        if kind == .playlist {
            playlist.prepare(item("other", kind: kind))
            playlist.prepare(selected)
        } else {
            album.prepare(item("other", kind: kind))
            album.prepare(selected)
        }
        #expect(rows() == [fresh], "the rejected read must not overwrite the retained full result")
        playlist.reset()
        album.reset()
    }

    @Test(arguments: [false, true])
    func unavailableEntityQueryCanRetryOnTheSameRouteAndSession(failAtRead: Bool) async throws {
        let queries = HarnessCatalogQueries()
        if failAtRead { await queries.failNextRead() } else { await queries.failNextSubscription() }
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        let row = track("spotify:track:first", title: "Original")
        await queries.publish([row])
        provider.onPlaylist = { _ in CatalogPlaylistSnapshot(description: "First", ownerURI: nil, tracks: [row])
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylist(provider, session: session)
        defer { store.reset() }
        let selected = item("first", kind: .playlist)
        await store.load(selected)
        try await requireEventually { await queries.subscriptionAttemptCount == 1 }
        if failAtRead {
            try await requireEventually {
                let failed = await queries.failedReadCount
                let active = await queries.activeQueryCount
                return failed == 1 && active == 0
            }
        }
        try await requireEventually {
            store.prepare(selected)
            return await queries.activeQueryCount == 1
        }
        await queries.publish([track(row.uri, title: "Recovered")])
        try await requireEventually { store.tracks.first?.title == "Recovered" }
        #expect(provider.playlistRequestCount == 1)
        store.reset()
    }

    private func makePlaylist(_ provider: HarnessCatalog, session: CatalogSessionAvailability) -> PlaylistStore {
        let metadata = CatalogMetadataRepository(session: session)
        return PlaylistStore(provider: provider, metadata: metadata, session: session)
    }

    private nonisolated static func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id, subtitle: "", artworkURL: nil,
            kind: kind)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem { Self.item(id, kind: kind) }

    private nonisolated static func track(
        _ uri: String, title: String, id: String? = nil, uid: String? = nil, addedAt: Date? = nil
    ) -> CatalogTrack {
        CatalogTrack(
            id: id ?? uri, uri: uri, title: title, artist: "Artist", album: "Album", duration: 100,
            artworkURL: nil, addedAt: addedAt, artists: [], albumItem: nil, occurrenceUID: uid)
    }

    private func track(_ uri: String, title: String, id: String? = nil, uid: String? = nil, addedAt: Date? = nil)
        -> CatalogTrack
    {
        Self.track(uri, title: title, id: id, uid: uid, addedAt: addedAt)
    }
}

import Foundation
import SpottyCatalogStorage
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

struct CatalogEntityQueryChecks {
    @Test func initialEntitiesArePagedAndMissingRowsAdvanceTheCursor() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let rows = (0..<502).map { queryTrack("\($0)") }
        await fixture.source.setTracks(rows)
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let requested = Set(rows.map(\.uri)).union(["spotify:track:missing"])
        let subscription = try await fixture.provider.subscribeCatalogEntities(requested)
        var updates = subscription.updates.makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(initial.totalCount == 503)
        let first = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: initial.revision, offset: 0, limit: 500)
        let last = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: initial.revision, offset: first.nextOffset, limit: 500)
        #expect(first.nextOffset == 500)
        #expect(last.nextOffset == 503)
        #expect(first.tracks.count + last.tracks.count == 502)
        #expect(first.tracks.values.allSatisfy { $0.id == $0.uri && $0.addedAt == nil && $0.occurrenceUID == nil })
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: initial.revision)
        #expect(await fixture.provider.retire(purge: true))
        #expect(await updates.next() == nil)
    }

    @Test func relinkedMetadataRetainsRequestedQueryIdentity() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let requested = "spotify:track:requested"
        let playable = queryTrack("playable", occurrence: "server-occurrence")
        let storage = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await storage.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:relinked",
                occurrences: [
                    .init(id: "display", requestedURI: requested, serverUID: "server-occurrence", track: playable)
                ],
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ), scope: storage.scope
        )
        try await storage.close(scope: storage.scope)
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([requested])
        let page = try await fixture.provider.catalogEntityPage(subscription.token, revision: 0, offset: 0, limit: 500)
        let entity = try #require(page.tracks[requested])
        #expect(entity.uri == requested)
        #expect(entity.id == requested)
        #expect(entity.title == playable.title)
        #expect(entity.occurrenceUID == nil)
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func effectiveMetadataChangesAreFilteredAndCoalesceUntilAcknowledged() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let first = queryTrack("one")
        let second = queryTrack("two")
        await fixture.source.setTracks([first, second])
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let subscription = try await fixture.provider.subscribeCatalogEntities([first.uri, second.uri])
        var updates = subscription.updates.makeAsyncIterator()
        let initial = try #require(await updates.next())
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: initial.revision)

        // Neither a different collection nor an identical effective entity can advance revision.
        await fixture.source.setTracks([queryTrack("unrelated")])
        _ = try await fixture.provider.album(id: "unrelated")
        await fixture.source.setTracks([queryTrack("one", occurrence: "new-occurrence")])
        _ = try await fixture.provider.album(id: "identical")
        let silent = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: initial.revision, offset: 0, limit: 500)
        #expect(silent.totalCount == 0)

        await fixture.source.setTracks([queryTrack("one", title: "Updated one")])
        _ = try await fixture.provider.album(id: "changed-one")
        let updateOne = try #require(await updates.next())
        #expect(updateOne.revision == initial.revision + 1)
        #expect(updateOne.totalCount == 1)
        await fixture.source.setTracks([queryTrack("two", title: "Updated two")])
        _ = try await fixture.provider.album(id: "changed-two")
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: updateOne.revision)
        let updateBoth = try #require(await updates.next())
        #expect(updateBoth.revision == updateOne.revision + 1)
        #expect(updateBoth.totalCount == 2)
        await #expect(throws: CatalogEntityQueryFailure.superseded) {
            try await fixture.provider.catalogEntityPage(
                subscription.token, revision: updateOne.revision, offset: 0, limit: 500)
        }
        let entities = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: updateBoth.revision, offset: 0, limit: 500)
        #expect(entities.tracks[first.uri]?.title == "Updated one")
        #expect(entities.tracks[second.uri]?.title == "Updated two")
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: updateBoth.revision)
        let acknowledged = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: updateBoth.revision, offset: 0, limit: 500)
        #expect(acknowledged.totalCount == 0)
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func slowSubscriberReceivesTheUnionWithoutAnUnboundedEventQueue() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([
            queryTrack("one").uri, queryTrack("two").uri,
        ])
        await fixture.source.setTracks([queryTrack("one")])
        _ = try await fixture.provider.playlist(id: "one")
        await fixture.source.setTracks([queryTrack("two")])
        _ = try await fixture.provider.album(id: "two")
        var updates = subscription.updates.makeAsyncIterator()
        let newest = try #require(await updates.next())
        #expect(newest.revision == 2)
        #expect(newest.totalCount == 2)
        let page = try await fixture.provider.catalogEntityPage(
            subscription.token, revision: newest.revision, offset: 0, limit: 500)
        #expect(page.tracks.count == 2)
        await fixture.provider.unsubscribeCatalogEntities(subscription.token)
        #expect(await updates.next() == nil)
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func subscriptionsAreBoundedAndOldTokensCannotRemoveReplacementObservations() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        await fixture.provider.activate()
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([])
        }
        _ = try await fixture.provider.profile()
        await #expect(throws: CatalogEntityQueryFailure.invalidRequest) {
            try await fixture.provider.subscribeCatalogEntities(
                Set((0...CatalogEntityQueryLimits.maximumRequestedURIs).map(String.init)))
        }
        var subscriptions: [CatalogEntitySubscription] = []
        for _ in 0..<CatalogEntityQueryLimits.maximumSubscriptions {
            subscriptions.append(try await fixture.provider.subscribeCatalogEntities([]))
        }
        await #expect(throws: CatalogEntityQueryFailure.capacity) {
            try await fixture.provider.subscribeCatalogEntities([])
        }
        let old = try #require(subscriptions.first)
        #expect(await fixture.provider.retire(purge: false))
        await fixture.provider.activate()
        _ = try await fixture.provider.profile()
        let replacement = try await fixture.provider.subscribeCatalogEntities([])
        #expect(replacement.token.accountLifetime != old.token.accountLifetime)
        await fixture.provider.unsubscribeCatalogEntities(old.token)
        await fixture.provider.acknowledgeCatalogEntities(old.token, revision: 0)
        await #expect(throws: CatalogEntityQueryFailure.retired) {
            try await fixture.provider.catalogEntityPage(old.token, revision: 0, offset: 0, limit: 500)
        }
        #expect(
            try await fixture.provider.catalogEntityPage(replacement.token, revision: 0, offset: 0, limit: 500)
                .totalCount == 0)
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func failedPersistenceCannotHydrateFreshLiveRowsFromOlderEntities() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        await fixture.source.setTracks([queryTrack("one", title: "Old")])
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let observation = try await fixture.provider.subscribeCatalogEntities([queryTrack("one").uri])
        var updates = observation.updates.makeAsyncIterator()
        _ = await updates.next()
        // This valid live response exceeds the cache's bounded record size; retention rejects it.
        let fresh = queryTrack("one", title: String(repeating: "N", count: 70_000))
        await fixture.source.setTracks([fresh])
        #expect(try await fixture.provider.playlist(id: "one").tracks == [fresh])
        #expect(await updates.next() == nil)
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        await fixture.source.setTracks([queryTrack("unrelated")])
        _ = try await fixture.provider.album(id: "unrelated")
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func rejectedRefreshCannotHydrateFreshLiveRowsFromAnOlderClockSample() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let row = queryTrack("one", title: "Retained before clock reset")
        let storage = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await storage.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:one", occurrences: CatalogOccurrence.browsingRows([row]),
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 4_000_000_000)
            ), scope: storage.scope
        )
        try await storage.close(scope: storage.scope)
        try await fixture.bind()
        let fresh = queryTrack("one", title: "Fresh after clock reset")
        await fixture.source.setTracks([fresh])
        #expect(try await fixture.provider.playlist(id: "one").tracks == [fresh])
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        #expect(await fixture.provider.retire(purge: true))
    }

    @Test func changedAccountProofFinishesOutstandingObservations() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([])
        var updates = subscription.updates.makeAsyncIterator()
        _ = await updates.next()
        await fixture.source.setAccount("spotify:user:replacement")
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await fixture.provider.profile() }
        #expect(await updates.next() == nil)
        #expect(await fixture.provider.retire(purge: true))
    }
}

private struct QueryFixture {
    let directory: URL
    let source: EntityQuerySource
    let provider: PersistentCatalogProvider

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-query-\(UUID())")
        source = EntityQuerySource()
        provider = PersistentCatalogProvider(source: source, rootDirectory: directory)
    }

    func bind() async throws {
        await provider.activate()
        _ = try await provider.profile()
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

private actor EntityQuerySource: CatalogProviding {
    private var tracks: [CatalogTrack] = []
    private var account = "spotify:user:query-account"
    func setTracks(_ values: [CatalogTrack]) { tracks = values }
    func setAccount(_ value: String) { account = value }
    func profile() -> CatalogProfileSnapshot { .init(name: "Query account", uri: account) }
    func playlist(id _: String) -> CatalogPlaylistSnapshot { .init(description: "", ownerURI: nil, tracks: tracks) }
    func album(id _: String) -> CatalogAlbumSnapshot { .init(tracks: tracks, releaseDate: "") }
    func searchTracks(_: String, limit _: Int) -> [CatalogTrack] { [] }
    func home() -> CatalogHomeSnapshot { .init(greeting: "", sections: []) }
    func playlistLibrary() -> [PlaylistLibraryNode] { [] }
    func libraryAlbums() -> [CatalogItem] { [] }
    func libraryArtists() -> [CatalogItem] { [] }
    func libraryTracks() -> [CatalogTrack] { [] }
}

private func queryTrack(_ id: String, title: String? = nil, occurrence: String? = nil) -> CatalogTrack {
    CatalogTrack(
        id: occurrence ?? id, uri: "spotify:track:\(id)", title: title ?? id,
        artist: "Artist", album: "Album", duration: 100, artworkURL: nil, addedAt: nil,
        occurrenceUID: occurrence
    )
}

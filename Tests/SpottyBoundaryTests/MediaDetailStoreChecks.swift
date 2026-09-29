@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
import SpottyRuntimeContracts

private func makeGatedAlbumCatalog() -> (catalog: HarnessCatalog, gate: HarnessResponseGate<CatalogAlbumSnapshot>) {
    let gate = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
    let catalog = HarnessCatalog()
    catalog.onAlbum = { _ in try await gate.wait() }
    return (catalog, gate)
}

private func makeGatedArtistCatalog() -> (catalog: HarnessCatalog, gate: HarnessResponseGate<CatalogArtistSnapshot>) {
    let gate = HarnessResponseGate<CatalogArtistSnapshot>(cancellation: .ignored)
    let catalog = HarnessCatalog()
    catalog.onArtist = { _ in try await gate.wait() }
    return (catalog, gate)
}

private func albumItem(_ id: String, uri: String? = nil) -> CatalogItem {
    CatalogItem(
        id: id,
        uri: uri ?? "spotify:album:\(id)",
        title: id,
        subtitle: "",
        artworkURL: nil,
        kind: .album
    )
}

private func artistItem(_ id: String, uri: String? = nil) -> CatalogItem {
    CatalogItem(
        id: id,
        uri: uri ?? "spotify:artist:\(id)",
        title: id,
        subtitle: "",
        artworkURL: nil,
        kind: .artist
    )
}

@MainActor
private func makeAlbumStore(
    provider: HarnessCatalog,
    session: CatalogSessionAvailability
) -> (AlbumDetailStore, CatalogMetadataRepository) {
    let metadata = CatalogMetadataRepository(session: session)
    return (AlbumDetailStore(provider: provider, metadata: metadata, session: session), metadata)
}

@MainActor
private func makeArtistStore(
    provider: HarnessCatalog,
    session: CatalogSessionAvailability
) -> ArtistDetailStore {
    ArtistDetailStore(provider: provider, session: session)
}

@MainActor
private func requireArtistRequest(
    _ provider: HarnessCatalog,
    gate: HarnessResponseGate<CatalogArtistSnapshot>,
    requests: Int,
    parked: Int
) async throws {
    try await requireEventually {
        gate.waiterCount == parked && provider.artistRequestCount == requests
    }
    #expect(provider.discographyRequestCount == 0, "the overview never fetches the complete discography")
}

@MainActor
private struct AlbumLoadProbe {
    let task: Task<Void, Never>
    let hasEntered: () -> Bool
    let hasFinished: () -> Bool
}

@MainActor
private func startJoiningAlbumLoad(_ store: AlbumDetailStore, item: CatalogItem) -> AlbumLoadProbe {
    var entered = false
    var finished = false
    let task = Task { @MainActor in
        entered = true
        await store.load(item)
        finished = true
    }
    return AlbumLoadProbe(
        task: task,
        hasEntered: { entered },
        hasFinished: { finished }
    )
}

@MainActor
private struct ArtistLoadProbe {
    let task: Task<Void, Never>
    let hasEntered: () -> Bool
    let hasFinished: () -> Bool
}

@MainActor
private func startJoiningArtistLoad(_ store: ArtistDetailStore, item: CatalogItem) -> ArtistLoadProbe {
    var entered = false
    var finished = false
    let task = Task { @MainActor in
        entered = true
        await store.load(item)
        finished = true
    }
    return ArtistLoadProbe(
        task: task,
        hasEntered: { entered },
        hasFinished: { finished }
    )
}

@Suite("Media Detail Store")
struct MediaDetailStoreTests {
    @Test
    @MainActor
    func testMediaDetailStore() async throws {
        let firstAlbumValue = CatalogAlbumSnapshot(
            tracks: [HarnessFixtures.track(uri: "spotify:track:first", title: "First Track", duration: 120)],
            releaseDate: "2024-01-02")
        let secondAlbumValue = CatalogAlbumSnapshot(
            tracks: [HarnessFixtures.track(uri: "spotify:track:second", title: "Second Track", duration: 90)],
            releaseDate: "2025-03-04")
        let firstArtistValue = CatalogArtistSnapshot(
            name: "First Artist",
            releases: [
                CatalogItem(
                    id: "first-release", uri: "spotify:album:first-release", title: "First Release",
                    subtitle: "2024 • Album", artworkURL: nil, kind: .album)
            ])
        let secondArtistValue = CatalogArtistSnapshot(
            name: "Second Artist",
            releases: [
                CatalogItem(
                    id: "second-release", uri: "spotify:album:second-release", title: "Second Release",
                    subtitle: "2025 • Album", artworkURL: nil, kind: .album)
            ])

        let firstAlbumItem = albumItem("first")
        let secondAlbumItem = albumItem("second")
        let firstArtistItem = artistItem("first")
        let secondArtistItem = artistItem("second")

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            let follower = startJoiningAlbumLoad(store, item: firstAlbumItem)
            try #require((await waitUntil { follower.hasEntered() }) == true, "the duplicate caller entered load")
            #expect(
                (provider.albumRequestCount) == (1), "a duplicate current-selection request joins the in-flight work")
            #expect((store.isLoading) == true, "the joined album stays loading")
            #expect((!follower.hasFinished()) == true, "the duplicate caller is still waiting on the in-flight request")
            #expect((store.item?.uri) == ("spotify:album:first"), "join does not clear the current selection")

            gate.finish(firstAlbumValue)
            await firstLoad.value
            await follower.task.value
            #expect((follower.hasFinished()) == true, "the duplicate caller finishes after the in-flight request")
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "joined consumers publish one album")
            #expect((store.releaseDate) == ("2024-01-02"), "joined consumers publish the release date")
            #expect((!store.isLoading) == true, "joined loading finishes")
            #expect((store.error) == nil, "join does not surface an error")

            await store.load(firstAlbumItem)
            #expect((provider.albumRequestCount) == (1), "a completed same-session album is not fetched again")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            let joiner = startJoiningAlbumLoad(store, item: firstAlbumItem)
            try #require((await waitUntil { joiner.hasEntered() }) == true, "the joiner entered load")
            #expect((provider.albumRequestCount) == (1), "the joiner claimed the in-flight request")
            #expect((!joiner.hasFinished()) == true, "the joiner is waiting on the claimed flight")

            owner.cancel()
            #expect(
                (provider.albumRequestCount) == (1),
                "owner cancel does not start a second provider request after a join claim")
            #expect((!joiner.hasFinished()) == true, "the joiner remains on the live flight after owner cancel")

            gate.finish(firstAlbumValue)
            await joiner.task.value
            await owner.value
            #expect((joiner.hasFinished()) == true, "the joiner finishes after the claimed flight")
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "the joiner receives the in-flight result")
            #expect((!store.isLoading) == true, "claimed-flight loading finishes")
            #expect((store.error) == nil, "claimed-flight success does not surface an error")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = startJoiningAlbumLoad(store, item: firstAlbumItem)
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            owner.task.cancel()
            let reload = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 2 && provider.albumRequestCount == 2
            }
            #expect((store.isLoading) == true, "the replacement flight owns loading")

            gate.resolve(.failure(CancellationError()))
            await owner.task.value
            #expect((store.tracks.isEmpty) == true, "the cancelled owner does not publish")
            #expect((store.error) == nil, "the cancelled owner does not surface an error")

            gate.finish(firstAlbumValue)
            await reload.value
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "the replacement flight publishes")
            #expect((!store.isLoading) == true, "the replacement flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }

            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 2 && provider.albumRequestCount == 2
            }
            #expect((store.isLoading) == true, "the newest flight owns loading")
            #expect((store.item?.uri) == ("spotify:album:second"), "the newest selection is presented immediately")
            #expect((store.tracks.map(\.uri)) == ([]), "a new selection clears the previous tracks")
            #expect((store.error) == nil, "a new selection clears the previous error")

            gate.finish(firstAlbumValue)
            await stale.value
            #expect((store.isLoading) == true, "a stale success leaves the new request loading")
            #expect((store.tracks.map(\.uri)) == ([]), "a stale success does not publish tracks")
            #expect((store.releaseDate) == (""), "a stale success does not publish a release date")
            #expect((store.error) == nil, "a stale success does not surface an error")

            let joiner = startJoiningAlbumLoad(store, item: secondAlbumItem)
            try #require(
                (await waitUntil { joiner.hasEntered() }) == true, "the later same-selection caller entered load")
            #expect(
                (provider.albumRequestCount) == (2), "the old request cannot clear the new request's in-flight task")
            #expect(
                (!joiner.hasFinished()) == true, "a later same-selection caller is still waiting on the newest flight")

            gate.finish(secondAlbumValue)
            await current.value
            await joiner.task.value
            #expect((joiner.hasFinished()) == true, "the later same-selection caller finishes with the newest flight")
            #expect((store.tracks.map(\.uri)) == (["spotify:track:second"]), "only the current selection publishes")
            #expect((store.releaseDate) == ("2025-03-04"), "only the current selection publishes a release date")
            #expect((!store.isLoading) == true, "the newest flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 2 && provider.albumRequestCount == 2
            }

            gate.resolve(.failure(HarnessFailure.unavailable))
            await stale.value
            #expect((store.isLoading) == true, "a stale failure leaves the new request loading")
            #expect((store.error) == nil, "a stale failure does not surface an error")

            gate.resolve(.failure(URLError(.cancelled)))
            await current.value
            #expect((!store.isLoading) == true, "cancellation clears only the cancelled flight's loading")
            #expect((store.error) == nil, "cancellation does not surface a user-facing error")
            #expect((store.tracks.map(\.uri)) == ([]), "cancellation does not publish tracks")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let staleEpoch = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            session.update(accountEpoch: 2, isAvailable: true)
            gate.finish(firstAlbumValue)
            await staleEpoch.value
            #expect((store.tracks.map(\.uri)) == ([]), "an older account epoch cannot publish tracks")
            #expect((store.releaseDate) == (""), "an older account epoch cannot publish a release date")

            let staleRevision = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 2
            }
            session.update(accountEpoch: 2, isAvailable: false)
            session.update(accountEpoch: 2, isAvailable: true)
            gate.finish(firstAlbumValue)
            await staleRevision.value
            #expect((store.tracks.map(\.uri)) == ([]), "a pre-reconnect album result cannot publish")

            let current = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 3
            }
            gate.finish(secondAlbumValue)
            await current.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:second"]), "the current session publishes album tracks")

            session.update(accountEpoch: 3, isAvailable: true)
            let afterEpoch = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 4
            }
            gate.finish(firstAlbumValue)
            await afterEpoch.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]), "the later account epoch publishes album tracks"
            )
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            #expect((store.isLoading) == true, "teardown starts from a loading album")

            store.reset()
            #expect((!store.isLoading) == true, "reset clears album loading")
            #expect((store.item) == nil, "reset clears the current album")
            #expect((store.tracks.map(\.uri)) == ([]), "reset clears album tracks")
            #expect((store.releaseDate) == (""), "reset clears the release date")
            #expect((store.error) == nil, "reset clears album errors")

            gate.finish(firstAlbumValue)
            await inflight.value
            #expect((store.tracks.map(\.uri)) == ([]), "a torn-down album success cannot publish tracks")
            #expect((store.releaseDate) == (""), "a torn-down album success cannot restore a release date")
            #expect((!store.isLoading) == true, "a torn-down album success cannot restore loading")
            #expect((store.error) == nil, "a torn-down album success cannot surface an error")
            #expect((store.item) == nil, "a torn-down album success cannot restore the selection")
        }

        do {
            let (albumProvider, _) = makeGatedAlbumCatalog()
            let (artistProvider, _) = makeGatedArtistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (albumStore, _) = makeAlbumStore(provider: albumProvider, session: session)
            let artistStore = makeArtistStore(provider: artistProvider, session: session)
            let invalidAlbum = albumItem("bad", uri: "not-an-album-uri")
            let invalidArtist = artistItem("bad", uri: "spotify:track:not-an-artist")
            let wrongKind = artistItem("first", uri: "spotify:album:first")

            await albumStore.load(invalidAlbum)
            #expect((albumProvider.albumRequestCount) == (0), "an invalid album URI does not call the provider")
            #expect(
                (albumStore.error) == ("Spotify returned an invalid album address."),
                "an invalid album URI surfaces a stable error")
            #expect((!albumStore.isLoading) == true, "an invalid album URI does not stay loading")
            #expect((albumStore.item?.uri) == ("not-an-album-uri"), "an invalid album URI still presents the selection")

            await albumStore.load(invalidAlbum)
            #expect(
                (albumProvider.albumRequestCount) == (0),
                "retrying an invalid album URI still does not call the provider")

            await albumStore.load(wrongKind)
            #expect((albumProvider.albumRequestCount) == (0), "a non-album selection is ignored")
            #expect(
                (albumStore.item?.uri) == ("not-an-album-uri"), "a non-album selection leaves the invalid album state")

            await artistStore.load(invalidArtist)
            #expect((artistProvider.artistRequestCount) == (0), "an invalid artist URI does not call overview")
            #expect(
                (artistProvider.discographyRequestCount) == (0), "an invalid artist URI does not call discography"
            )
            #expect(
                (artistStore.error) == ("Spotify returned an invalid artist address."),
                "an invalid artist URI surfaces a stable error")
            #expect((!artistStore.isLoading) == true, "an invalid artist URI does not stay loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, metadata) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 1 && provider.albumRequestCount == 1
            }
            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                gate.waiterCount == 2 && provider.albumRequestCount == 2
            }

            gate.finish(firstAlbumValue)
            await stale.value
            #expect(
                (metadata.knownTrack(for: "spotify:track:first")) == nil, "a stale album success does not cache tracks")

            gate.finish(secondAlbumValue)
            await current.value
            #expect(
                (metadata.knownTrack(for: "spotify:track:second")?.title) == ("Second Track"),
                "the current album publishes metadata")
            #expect(
                (metadata.knownTrack(for: "spotify:track:first")) == nil,
                "the current album does not keep stale album metadata")
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstArtistItem) }
            try await requireArtistRequest(provider, gate: gate, requests: 1, parked: 1)
            let follower = startJoiningArtistLoad(store, item: firstArtistItem)
            try #require(
                (await waitUntil { follower.hasEntered() }) == true, "the duplicate artist caller entered load")
            #expect((provider.artistRequestCount) == (1), "duplicate artist overview is not requested")
            #expect((provider.discographyRequestCount) == (0), "the overview does not request discography")
            #expect((store.isLoading) == true, "the artist stays loading until its overview finishes")
            #expect((!follower.hasFinished()) == true, "the duplicate artist caller is still waiting")
            #expect((store.releases.map(\.uri)) == ([]), "a pending overview does not publish yet")

            gate.finish(firstArtistValue)
            await firstLoad.value
            await follower.task.value
            #expect((follower.hasFinished()) == true, "the duplicate artist caller finishes with the overview")
            #expect(
                (store.releases.map(\.uri)) == (["spotify:album:first-release"]),
                "the overview publishes sampled releases")
            #expect(
                (store.releases.first?.subtitle) == ("2024 • Album"),
                "the store preserves the release year and type")
            #expect((!store.isLoading) == true, "artist loading finishes once")

            await store.load(firstArtistItem)
            #expect(
                (provider.artistRequestCount) == (1), "a completed same-session artist is not fetched again")
            #expect(
                (provider.discographyRequestCount) == (0),
                "revisiting the overview never fetches the complete discography"
            )
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let stale = Task { await store.load(firstArtistItem) }
            try await requireArtistRequest(provider, gate: gate, requests: 1, parked: 1)
            let current = Task { await store.load(secondArtistItem) }
            try await requireArtistRequest(provider, gate: gate, requests: 2, parked: 2)
            #expect((store.item?.uri) == ("spotify:artist:second"), "the newest artist is presented immediately")
            #expect((store.releases.map(\.uri)) == ([]), "a new artist clears previous releases")

            gate.finish(firstArtistValue)

            await stale.value
            #expect((store.isLoading) == true, "a stale artist request leaves the new request loading")
            #expect((store.releases.map(\.uri)) == ([]), "a stale artist request does not publish")

            gate.finish(secondArtistValue)

            await current.value
            #expect(
                (store.releases.map(\.uri)) == (["spotify:album:second-release"]), "only the current artist publishes")
            #expect(
                (store.releases.first?.subtitle) == ("2025 • Album"), "the current artist preserves release metadata")
            #expect((!store.isLoading) == true, "the current artist clears loading")
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            defer { gate.close() }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstArtistItem) }
            try await requireArtistRequest(provider, gate: gate, requests: 1, parked: 1)
            store.reset()
            #expect((!store.isLoading) == true, "reset clears artist loading")
            #expect((store.item) == nil, "reset clears the current artist")
            #expect((store.releases.map(\.uri)) == ([]), "reset clears releases")

            gate.finish(firstArtistValue)

            await inflight.value
            #expect((store.releases.map(\.uri)) == ([]), "a torn-down artist success cannot publish")
            #expect((!store.isLoading) == true, "a torn-down artist success cannot restore loading")
            #expect((store.item) == nil, "a torn-down artist success cannot restore the selection")
        }
    }
}

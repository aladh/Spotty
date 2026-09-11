import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

/// Gates `HarnessCatalog.album` so a check can park and release admitted requests one at a time,
/// mirroring the pre-harness `GatedAlbumCatalog` actor.
private actor AlbumGate {
    enum Outcome: Sendable {
        case album(PathfinderAlbumUnion)
        case failure
        case cancelled
        case urlCancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    /// Request counting lives on the `HarnessCatalog` itself (`albumRequestCount`).
    func album() async throws -> PathfinderAlbumUnion {
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .album(album):
            return album
        case .failure:
            throw HarnessFailure.unavailable
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        }
    }

    func completeNext(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: outcome)
    }
}

private func makeGatedAlbumCatalog() -> (catalog: HarnessCatalog, gate: AlbumGate) {
    let gate = AlbumGate()
    let catalog = HarnessCatalog()
    catalog.onAlbum = { [gate] _ in try await gate.album() }
    return (catalog, gate)
}

/// Gates `HarnessCatalog.artist`/`.artistDiscography` so a check can park and release the two
/// requests independently, mirroring the pre-harness `GatedArtistCatalog` actor.
private actor ArtistGate {
    enum Outcome: Sendable {
        case artist(PathfinderArtistUnion)
        case failure
        case cancelled
        case urlCancelled
    }

    private var overviewWaiters: [CheckedContinuation<Outcome, Never>] = []
    private var discographyWaiters: [CheckedContinuation<Outcome, Never>] = []

    /// Request counting lives on the `HarnessCatalog` itself (`artistRequestCount` and
    /// `discographyRequestCount`).
    func artist() async throws -> PathfinderArtistUnion {
        let outcome = await withCheckedContinuation { continuation in
            overviewWaiters.append(continuation)
        }
        return try result(from: outcome)
    }

    func artistDiscography() async throws -> PathfinderArtistUnion {
        let outcome = await withCheckedContinuation { continuation in
            discographyWaiters.append(continuation)
        }
        return try result(from: outcome)
    }

    func completeOverview(_ outcome: Outcome) {
        guard !overviewWaiters.isEmpty else { return }
        overviewWaiters.removeFirst().resume(returning: outcome)
    }

    func completeDiscography(_ outcome: Outcome) {
        guard !discographyWaiters.isEmpty else { return }
        discographyWaiters.removeFirst().resume(returning: outcome)
    }

    private func result(from outcome: Outcome) throws -> PathfinderArtistUnion {
        switch outcome {
        case let .artist(artist):
            return artist
        case .failure:
            throw HarnessFailure.unavailable
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        }
    }
}

private func makeGatedArtistCatalog() -> (catalog: HarnessCatalog, gate: ArtistGate) {
    let gate = ArtistGate()
    let catalog = HarnessCatalog()
    catalog.onArtist = { [gate] _ in try await gate.artist() }
    catalog.onArtistDiscography = { [gate] _ in try await gate.artistDiscography() }
    return (catalog, gate)
}

private func decodeAlbum(_ json: String) throws -> PathfinderAlbumUnion {
    let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: Data(json.utf8))
    guard let album = response.data?.albumUnion else {
        throw HarnessFailure.unavailable
    }
    return album
}

private func decodeArtist(_ json: String) throws -> PathfinderArtistUnion {
    let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: Data(json.utf8))
    guard let artist = response.data?.artistUnion else {
        throw HarnessFailure.unavailable
    }
    return artist
}

private let firstAlbumJSON = """
    {"data":{"albumUnion":{"uri":"spotify:album:first","name":"First Album","type":"ALBUM","date":{"isoString":"2024-01-02T00:00:00Z"},"coverArt":{"sources":[]},"artists":{"items":[]},"tracksV2":{"items":[{"track":{"uri":"spotify:track:first","name":"First Track","trackNumber":1,"discNumber":1,"duration":{"totalMilliseconds":120000},"artists":{"items":[]}}}],"totalCount":1}}}}
    """
private let secondAlbumJSON = """
    {"data":{"albumUnion":{"uri":"spotify:album:second","name":"Second Album","type":"ALBUM","date":{"isoString":"2025-03-04T00:00:00Z"},"coverArt":{"sources":[]},"artists":{"items":[]},"tracksV2":{"items":[{"track":{"uri":"spotify:track:second","name":"Second Track","trackNumber":1,"discNumber":1,"duration":{"totalMilliseconds":90000},"artists":{"items":[]}}}],"totalCount":1}}}}
    """
private let firstArtistJSON = """
    {"data":{"artistUnion":{"uri":"spotify:artist:first","id":"first","profile":{"name":"First Artist"},"visuals":{"avatarImage":{"sources":[]}},"discography":{"all":{"items":[{"releases":{"items":[{"uri":"spotify:album:first-release","id":"first-release","name":"First Release","type":"ALBUM","date":{"year":2024},"coverArt":{"sources":[]},"tracks":{"totalCount":1}}]}}],"totalCount":1}}}}}
    """
private let secondArtistJSON = """
    {"data":{"artistUnion":{"uri":"spotify:artist:second","id":"second","profile":{"name":"Second Artist"},"visuals":{"avatarImage":{"sources":[]}},"discography":{"all":{"items":[{"releases":{"items":[{"uri":"spotify:album:second-release","id":"second-release","name":"Second Release","type":"ALBUM","date":{"year":2025},"coverArt":{"sources":[]},"tracks":{"totalCount":1}}]}}],"totalCount":1}}}}}
    """
private func firstAlbum() throws -> PathfinderAlbumUnion { try decodeAlbum(firstAlbumJSON) }
private func secondAlbum() throws -> PathfinderAlbumUnion { try decodeAlbum(secondAlbumJSON) }
private func firstArtist() throws -> PathfinderArtistUnion { try decodeArtist(firstArtistJSON) }
private func secondArtist() throws -> PathfinderArtistUnion { try decodeArtist(secondArtistJSON) }

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
    session: CatalogSessionAvailability,
    attributes: HarnessTrackAttributes = HarnessTrackAttributes()
) -> (AlbumDetailStore, CatalogMetadataRepository) {
    let metadata = CatalogMetadataRepository(attributesProvider: attributes, session: session)
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
private func waitUntilArtistPair(
    _ provider: HarnessCatalog,
    overview: Int,
    discography: Int
) async -> Bool {
    await waitUntil {
        provider.artistRequestCount == overview && provider.discographyRequestCount == discography
    }
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
    func testMediaDetailStore() async {
        let firstAlbumValue: PathfinderAlbumUnion
        let secondAlbumValue: PathfinderAlbumUnion
        let firstArtistValue: PathfinderArtistUnion
        let secondArtistValue: PathfinderArtistUnion
        do {
            firstAlbumValue = try firstAlbum()
            secondAlbumValue = try secondAlbum()
            firstArtistValue = try firstArtist()
            secondArtistValue = try secondArtist()
        } catch {
            #expect((false) == true, "synthetic media-detail fixtures decode")
            return
        }

        let firstAlbumItem = albumItem("first")
        let secondAlbumItem = albumItem("second")
        let firstArtistItem = artistItem("first")
        let secondArtistItem = artistItem("second")

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the first album request parks")
            let follower = startJoiningAlbumLoad(store, item: firstAlbumItem)
            #expect((await waitUntil { follower.hasEntered() }) == true, "the duplicate caller entered load")
            #expect(
                (provider.albumRequestCount) == (1), "a duplicate current-selection request joins the in-flight work")
            #expect((store.isLoading) == true, "the joined album stays loading")
            #expect((!follower.hasFinished()) == true, "the duplicate caller is still waiting on the in-flight request")
            #expect((store.item?.uri) == ("spotify:album:first"), "join does not clear the current selection")

            await gate.completeNext(.album(firstAlbumValue))
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
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the owner album request parks")
            let joiner = startJoiningAlbumLoad(store, item: firstAlbumItem)
            #expect((await waitUntil { joiner.hasEntered() }) == true, "the joiner entered load")
            #expect((provider.albumRequestCount) == (1), "the joiner claimed the in-flight request")
            #expect((!joiner.hasFinished()) == true, "the joiner is waiting on the claimed flight")

            owner.cancel()
            #expect(
                (provider.albumRequestCount) == (1),
                "owner cancel does not start a second provider request after a join claim")
            #expect((!joiner.hasFinished()) == true, "the joiner remains on the live flight after owner cancel")

            await gate.completeNext(.album(firstAlbumValue))
            await joiner.task.value
            await owner.value
            #expect((joiner.hasFinished()) == true, "the joiner finishes after the claimed flight")
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "the joiner receives the in-flight result")
            #expect((!store.isLoading) == true, "claimed-flight loading finishes")
            #expect((store.error) == nil, "claimed-flight success does not surface an error")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the owner album request parks")
            owner.cancel()
            // Drain last-claim release so this admission observes no live flight.
            for _ in 0..<16 { await Task.yield() }
            let reload = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 2 }) == true,
                "reloading the same URI after owner cancellation starts a new provider request")
            #expect((store.isLoading) == true, "the replacement flight owns loading")

            await gate.completeNext(.cancelled)
            await owner.value
            #expect((store.tracks.isEmpty) == true, "the cancelled owner does not publish")
            #expect((store.error) == nil, "the cancelled owner does not surface an error")

            await gate.completeNext(.album(firstAlbumValue))
            await reload.value
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "the replacement flight publishes")
            #expect((!store.isLoading) == true, "the replacement flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 1 }) == true, "the superseded album request parks")

            let current = Task { await store.load(secondAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 2 }) == true,
                "a different selection starts a new request instead of joining")
            #expect((store.isLoading) == true, "the newest flight owns loading")
            #expect((store.item?.uri) == ("spotify:album:second"), "the newest selection is presented immediately")
            #expect((store.tracks.map(\.uri)) == ([]), "a new selection clears the previous tracks")
            #expect((store.error) == nil, "a new selection clears the previous error")

            await gate.completeNext(.album(firstAlbumValue))
            await stale.value
            #expect((store.isLoading) == true, "a stale success leaves the new request loading")
            #expect((store.tracks.map(\.uri)) == ([]), "a stale success does not publish tracks")
            #expect((store.releaseDate) == (""), "a stale success does not publish a release date")
            #expect((store.error) == nil, "a stale success does not surface an error")

            let joiner = startJoiningAlbumLoad(store, item: secondAlbumItem)
            #expect((await waitUntil { joiner.hasEntered() }) == true, "the later same-selection caller entered load")
            #expect(
                (provider.albumRequestCount) == (2), "the old request cannot clear the new request's in-flight task")
            #expect(
                (!joiner.hasFinished()) == true, "a later same-selection caller is still waiting on the newest flight")

            await gate.completeNext(.album(secondAlbumValue))
            await current.value
            await joiner.task.value
            #expect((joiner.hasFinished()) == true, "the later same-selection caller finishes with the newest flight")
            #expect((store.tracks.map(\.uri)) == (["spotify:track:second"]), "only the current selection publishes")
            #expect((store.releaseDate) == ("2025-03-04"), "only the current selection publishes a release date")
            #expect((!store.isLoading) == true, "the newest flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the failing album request parks")
            let current = Task { await store.load(secondAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 2 }) == true,
                "a different selection supersedes the failing request")

            await gate.completeNext(.failure)
            await stale.value
            #expect((store.isLoading) == true, "a stale failure leaves the new request loading")
            #expect((store.error) == nil, "a stale failure does not surface an error")

            await gate.completeNext(.urlCancelled)
            await current.value
            #expect((!store.isLoading) == true, "cancellation clears only the cancelled flight's loading")
            #expect((store.error) == nil, "cancellation does not surface a user-facing error")
            #expect((store.tracks.map(\.uri)) == ([]), "cancellation does not publish tracks")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let staleEpoch = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the pre-epoch album request parks")
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.album(firstAlbumValue))
            await staleEpoch.value
            #expect((store.tracks.map(\.uri)) == ([]), "an older account epoch cannot publish tracks")
            #expect((store.releaseDate) == (""), "an older account epoch cannot publish a release date")

            let staleRevision = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 2 }) == true, "the pre-reconnect album request parks")
            session.update(accountEpoch: 2, isAvailable: false)
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.album(firstAlbumValue))
            await staleRevision.value
            #expect((store.tracks.map(\.uri)) == ([]), "a pre-reconnect album result cannot publish")

            let current = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 3 }) == true,
                "a new catalog session starts a distinct album request")
            await gate.completeNext(.album(secondAlbumValue))
            await current.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:second"]), "the current session publishes album tracks")

            session.update(accountEpoch: 3, isAvailable: true)
            let afterEpoch = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 4 }) == true,
                "a later account epoch reloads a previously loaded album")
            await gate.completeNext(.album(firstAlbumValue))
            await afterEpoch.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]), "the later account epoch publishes album tracks"
            )
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstAlbumItem) }
            #expect((await waitUntil { provider.albumRequestCount == 1 }) == true, "the torn-down album request parks")
            #expect((store.isLoading) == true, "teardown starts from a loading album")

            store.reset()
            #expect((!store.isLoading) == true, "reset clears album loading")
            #expect((store.item) == nil, "reset clears the current album")
            #expect((store.tracks.map(\.uri)) == ([]), "reset clears album tracks")
            #expect((store.releaseDate) == (""), "reset clears the release date")
            #expect((store.error) == nil, "reset clears album errors")

            await gate.completeNext(.album(firstAlbumValue))
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
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let attributes = HarnessTrackAttributes()
            let (store, metadata) = makeAlbumStore(provider: provider, session: session, attributes: attributes)

            let stale = Task { await store.load(firstAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 1 }) == true, "the stale metadata request parks")
            let current = Task { await store.load(secondAlbumItem) }
            #expect(
                (await waitUntil { provider.albumRequestCount == 2 }) == true,
                "the current album metadata request parks")

            await gate.completeNext(.album(firstAlbumValue))
            await stale.value
            #expect(
                (metadata.knownTrack(for: "spotify:track:first")) == nil, "a stale album success does not cache tracks")
            #expect((attributes.requestCount) == (0), "a stale album success does not start attribute enrichment")

            await gate.completeNext(.album(secondAlbumValue))
            await current.value
            #expect(
                (metadata.knownTrack(for: "spotify:track:second")?.title) == ("Second Track"),
                "the current album publishes metadata")
            #expect(
                (metadata.knownTrack(for: "spotify:track:first")) == nil,
                "the current album does not keep stale album metadata")
            #expect(
                (await waitUntil { attributes.requestCount == 1 }) == true,
                "the current album starts attribute enrichment")
            #expect(
                (attributes.requests.flatMap { $0 }) == (["spotify:track:second"]),
                "attribute enrichment uses the current album tracks")
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstArtistItem) }
            #expect(
                (await waitUntilArtistPair(provider, overview: 1, discography: 1)) == true,
                "artist overview and discography both park")
            let follower = startJoiningArtistLoad(store, item: firstArtistItem)
            #expect((await waitUntil { follower.hasEntered() }) == true, "the duplicate artist caller entered load")
            #expect((provider.artistRequestCount) == (1), "duplicate artist overview is not requested")
            #expect((provider.discographyRequestCount) == (1), "duplicate artist discography is not requested")
            #expect((store.isLoading) == true, "the artist stays loading until both fetches finish")
            #expect((!follower.hasFinished()) == true, "the duplicate artist caller is still waiting")
            #expect((store.releases.map(\.uri)) == ([]), "partial artist completion does not publish yet")

            await gate.completeOverview(.artist(firstArtistValue))
            for _ in 0..<32 { await Task.yield() }
            #expect((store.isLoading) == true, "overview alone does not finish loading")
            #expect((store.releases.map(\.uri)) == ([]), "overview alone does not publish releases")
            #expect((!follower.hasFinished()) == true, "overview alone does not finish the joined caller")

            await gate.completeDiscography(.artist(firstArtistValue))
            await firstLoad.value
            await follower.task.value
            #expect((follower.hasFinished()) == true, "the duplicate artist caller finishes after both fetches")
            #expect(
                (store.releases.map(\.uri)) == (["spotify:album:first-release"]),
                "artist mapping uses the profile name after both fetches complete")
            #expect(
                (store.releases.first?.subtitle) == ("First Artist"),
                "artist mapping uses the profile as the release subtitle")
            #expect((!store.isLoading) == true, "parallel artist loading finishes once")

            await store.load(firstArtistItem)
            #expect(
                (provider.artistRequestCount) == (1), "a completed same-session artist is not fetched again")
            #expect(
                (provider.discographyRequestCount) == (1),
                "a completed same-session discography is not fetched again"
            )
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let stale = Task { await store.load(firstArtistItem) }
            #expect(
                (await waitUntilArtistPair(provider, overview: 1, discography: 1)) == true,
                "the superseded artist pair parks")
            let current = Task { await store.load(secondArtistItem) }
            #expect(
                (await waitUntilArtistPair(provider, overview: 2, discography: 2)) == true,
                "a different artist starts a new parallel pair")
            #expect((store.item?.uri) == ("spotify:artist:second"), "the newest artist is presented immediately")
            #expect((store.releases.map(\.uri)) == ([]), "a new artist clears previous releases")

            await gate.completeOverview(.artist(firstArtistValue))
            await gate.completeDiscography(.artist(firstArtistValue))
            await stale.value
            #expect((store.isLoading) == true, "a stale artist pair leaves the new request loading")
            #expect((store.releases.map(\.uri)) == ([]), "a stale artist pair does not publish")

            await gate.completeOverview(.artist(secondArtistValue))
            await gate.completeDiscography(.artist(secondArtistValue))
            await current.value
            #expect(
                (store.releases.map(\.uri)) == (["spotify:album:second-release"]), "only the current artist publishes")
            #expect(
                (store.releases.first?.subtitle) == ("Second Artist"), "the current artist profile names the releases")
            #expect((!store.isLoading) == true, "the current artist clears loading")
        }

        do {
            let (provider, gate) = makeGatedArtistCatalog()
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstArtistItem) }
            #expect(
                (await waitUntilArtistPair(provider, overview: 1, discography: 1)) == true,
                "the torn-down artist pair parks")
            store.reset()
            #expect((!store.isLoading) == true, "reset clears artist loading")
            #expect((store.item) == nil, "reset clears the current artist")
            #expect((store.releases.map(\.uri)) == ([]), "reset clears releases")

            await gate.completeOverview(.artist(firstArtistValue))
            await gate.completeDiscography(.artist(firstArtistValue))
            await inflight.value
            #expect((store.releases.map(\.uri)) == ([]), "a torn-down artist success cannot publish")
            #expect((!store.isLoading) == true, "a torn-down artist success cannot restore loading")
            #expect((store.item) == nil, "a torn-down artist success cannot restore the selection")
        }
    }
}

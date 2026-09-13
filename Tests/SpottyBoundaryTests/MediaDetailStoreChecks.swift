import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

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
    private var queuedOutcomes: [Outcome] = []
    private var isClosed = false

    var parkedRequestCount: Int { waiters.count }

    /// Request counting lives on the `HarnessCatalog` itself (`albumRequestCount`).
    func album() async throws -> PathfinderAlbumUnion {
        if isClosed { throw CancellationError() }
        let outcome: Outcome
        if queuedOutcomes.isEmpty {
            outcome = await withCheckedContinuation { waiters.append($0) }
        } else {
            outcome = queuedOutcomes.removeFirst()
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
        guard !isClosed else { return }
        guard !waiters.isEmpty else {
            queuedOutcomes.append(outcome)
            return
        }
        waiters.removeFirst().resume(returning: outcome)
    }

    func close() {
        isClosed = true
        queuedOutcomes.removeAll()
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: .cancelled) }
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
    private var overviewOutcomes: [Outcome] = []
    private var discographyOutcomes: [Outcome] = []
    private var isClosed = false

    var parkedOverviewCount: Int { overviewWaiters.count }
    var parkedDiscographyCount: Int { discographyWaiters.count }

    /// Request counting lives on the `HarnessCatalog` itself (`artistRequestCount` and
    /// `discographyRequestCount`).
    func artist() async throws -> PathfinderArtistUnion {
        if isClosed { throw CancellationError() }
        let outcome: Outcome
        if overviewOutcomes.isEmpty {
            outcome = await withCheckedContinuation { overviewWaiters.append($0) }
        } else {
            outcome = overviewOutcomes.removeFirst()
        }
        return try result(from: outcome)
    }

    func artistDiscography() async throws -> PathfinderArtistUnion {
        if isClosed { throw CancellationError() }
        let outcome: Outcome
        if discographyOutcomes.isEmpty {
            outcome = await withCheckedContinuation { discographyWaiters.append($0) }
        } else {
            outcome = discographyOutcomes.removeFirst()
        }
        return try result(from: outcome)
    }

    func completeOverview(_ outcome: Outcome) {
        guard !isClosed else { return }
        guard !overviewWaiters.isEmpty else {
            overviewOutcomes.append(outcome)
            return
        }
        overviewWaiters.removeFirst().resume(returning: outcome)
    }

    func completeDiscography(_ outcome: Outcome) {
        guard !isClosed else { return }
        guard !discographyWaiters.isEmpty else {
            discographyOutcomes.append(outcome)
            return
        }
        discographyWaiters.removeFirst().resume(returning: outcome)
    }

    func close() {
        isClosed = true
        overviewOutcomes.removeAll()
        discographyOutcomes.removeAll()
        let pendingOverview = overviewWaiters
        let pendingDiscography = discographyWaiters
        overviewWaiters.removeAll()
        discographyWaiters.removeAll()
        pendingOverview.forEach { $0.resume(returning: .cancelled) }
        pendingDiscography.forEach { $0.resume(returning: .cancelled) }
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
private func requireArtistPair(
    _ provider: HarnessCatalog,
    gate: ArtistGate,
    overview: Int,
    discography: Int,
    parkedOverview: Int,
    parkedDiscography: Int
) async throws {
    try await requireEventually {
        let overviewParks = await gate.parkedOverviewCount
        let discographyParks = await gate.parkedDiscographyCount
        return provider.artistRequestCount == overview && provider.discographyRequestCount == discography
            && overviewParks == parkedOverview && discographyParks == parkedDiscography
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
    func testMediaDetailStore() async throws {
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let owner = startJoiningAlbumLoad(store, item: firstAlbumItem)
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
            owner.task.cancel()
            let reload = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 2 && provider.albumRequestCount == 2
            }
            #expect((store.isLoading) == true, "the replacement flight owns loading")

            await gate.completeNext(.cancelled)
            await owner.task.value
            #expect((store.tracks.isEmpty) == true, "the cancelled owner does not publish")
            #expect((store.error) == nil, "the cancelled owner does not surface an error")

            await gate.completeNext(.album(firstAlbumValue))
            await reload.value
            #expect((store.tracks.map(\.uri)) == (["spotify:track:first"]), "the replacement flight publishes")
            #expect((!store.isLoading) == true, "the replacement flight clears loading")
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }

            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 2 && provider.albumRequestCount == 2
            }
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 2 && provider.albumRequestCount == 2
            }

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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let staleEpoch = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.album(firstAlbumValue))
            await staleEpoch.value
            #expect((store.tracks.map(\.uri)) == ([]), "an older account epoch cannot publish tracks")
            #expect((store.releaseDate) == (""), "an older account epoch cannot publish a release date")

            let staleRevision = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 2
            }
            session.update(accountEpoch: 2, isAvailable: false)
            session.update(accountEpoch: 2, isAvailable: true)
            await gate.completeNext(.album(firstAlbumValue))
            await staleRevision.value
            #expect((store.tracks.map(\.uri)) == ([]), "a pre-reconnect album result cannot publish")

            let current = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 3
            }
            await gate.completeNext(.album(secondAlbumValue))
            await current.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:second"]), "the current session publishes album tracks")

            session.update(accountEpoch: 3, isAvailable: true)
            let afterEpoch = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 4
            }
            await gate.completeNext(.album(firstAlbumValue))
            await afterEpoch.value
            #expect(
                (store.tracks.map(\.uri)) == (["spotify:track:first"]), "the later account epoch publishes album tracks"
            )
        }

        do {
            let (provider, gate) = makeGatedAlbumCatalog()
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let (store, _) = makeAlbumStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let attributes = HarnessTrackAttributes()
            let (store, metadata) = makeAlbumStore(provider: provider, session: session, attributes: attributes)

            let stale = Task { await store.load(firstAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 1 && provider.albumRequestCount == 1
            }
            let current = Task { await store.load(secondAlbumItem) }
            try await requireEventually {
                await gate.parkedRequestCount == 2 && provider.albumRequestCount == 2
            }

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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let firstLoad = Task { await store.load(firstArtistItem) }
            try await requireArtistPair(
                provider, gate: gate, overview: 1, discography: 1,
                parkedOverview: 1, parkedDiscography: 1)
            let follower = startJoiningArtistLoad(store, item: firstArtistItem)
            #expect((await waitUntil { follower.hasEntered() }) == true, "the duplicate artist caller entered load")
            #expect((provider.artistRequestCount) == (1), "duplicate artist overview is not requested")
            #expect((provider.discographyRequestCount) == (1), "duplicate artist discography is not requested")
            #expect((store.isLoading) == true, "the artist stays loading until both fetches finish")
            #expect((!follower.hasFinished()) == true, "the duplicate artist caller is still waiting")
            #expect((store.releases.map(\.uri)) == ([]), "partial artist completion does not publish yet")

            await gate.completeOverview(.artist(firstArtistValue))
            #expect(await gate.parkedDiscographyCount == 1, "discography still owns the incomplete parallel load")
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let stale = Task { await store.load(firstArtistItem) }
            try await requireArtistPair(
                provider, gate: gate, overview: 1, discography: 1,
                parkedOverview: 1, parkedDiscography: 1)
            let current = Task { await store.load(secondArtistItem) }
            try await requireArtistPair(
                provider, gate: gate, overview: 2, discography: 2,
                parkedOverview: 2, parkedDiscography: 2)
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
            defer { Task { await gate.close() } }
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let store = makeArtistStore(provider: provider, session: session)

            let inflight = Task { await store.load(firstArtistItem) }
            try await requireArtistPair(
                provider, gate: gate, overview: 1, discography: 1,
                parkedOverview: 1, parkedDiscography: 1)
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

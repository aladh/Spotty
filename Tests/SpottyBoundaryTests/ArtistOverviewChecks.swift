import SpottyTestSupport
@testable import SpottyRuntimeTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Artist overview")
@MainActor
struct ArtistOverviewChecks {
    @Test func overviewRestoresWithItsRouteAndRetiresWithItsAccount() async throws {
        let profile = overviewSnapshot()
        let selected = try #require(profile.item)
        let other = CatalogItem(
            id: "other", uri: "spotify:artist:other", title: "Other", subtitle: "Artist", artworkURL: nil, kind: .artist
        )
        let provider = HarnessCatalog()
        provider.onArtist = { id in
            id == "fixture" ? profile : CatalogArtistSnapshot(name: "Other", releases: [])
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session, clock: HarnessClock.sticky())
        await store.load(selected)
        let version = store.popularTracks.version
        await store.load(other)
        #expect(store.overview == nil)
        #expect(store.popularTracks.tracks.isEmpty)
        store.prepare(selected)
        #expect(store.overview == profile.overview)
        #expect(store.releaseDates == profile.releaseDates)
        #expect(store.popularTracks.version == version)
        #expect(store.artistTracks["spotify:track:second"]?.isPlayable == false)
        provider.onArtist = { _ in throw HarnessFailure.unavailable }
        await store.load(selected, force: true)
        #expect(store.isShowingCachedContent)
        #expect(store.overview == profile.overview)
        session.update(accountEpoch: 2, isAvailable: true)
        store.prepare(selected)
        #expect(store.overview == nil)
        #expect(store.popularTracks.tracks.isEmpty)
        #expect(store.artistTracks.isEmpty)
        #expect(store.releaseKinds.isEmpty)
    }

    @Test func overviewUsesOneReadWithoutDependingOnFullDiscography() async throws {
        let snapshot = overviewSnapshot()
        let selected = try #require(snapshot.item)
        let provider = HarnessCatalog()
        provider.onArtist = { _ in snapshot }
        provider.onArtistDiscography = { _ in throw HarnessFailure.unavailable }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session, clock: HarnessClock.sticky())

        await store.load(selected)

        #expect(provider.artistRequestCount == 1)
        #expect(provider.discographyRequestCount == 0)
        #expect(store.error == nil)
        #expect(!store.isLoading)
        #expect(store.overview == snapshot.overview)
        #expect(store.releases == snapshot.releases)
    }

    private func overviewSnapshot() -> CatalogArtistSnapshot {
        let artist = CatalogItem(
            id: "fixture", uri: "spotify:artist:fixture", title: "Fixture Artist",
            subtitle: "Artist", artworkURL: nil, kind: .artist)
        let release = CatalogItem(
            id: "release", uri: "spotify:album:release", title: "Release",
            subtitle: "2024 • Album", artworkURL: nil, kind: .album)
        let playlist = CatalogItem(
            id: "featuring", uri: "spotify:playlist:featuring", title: "Featuring",
            subtitle: "", artworkURL: nil, kind: .playlist)
        let overview = CatalogArtistOverview(
            headerArtworkURL: URL(string: "https://example.test/banner.jpg"), monthlyListeners: 123456,
            isVerified: true,
            popularTracks: [
                CatalogArtistPopularTrack(
                    track: HarnessFixtures.track(uri: "spotify:track:first"), playCount: 9_876_543_210),
                CatalogArtistPopularTrack(track: HarnessFixtures.track(uri: "spotify:track:second"), isPlayable: false),
            ], popularReleases: [release], featuringPlaylists: [playlist], biography: "Fixture biography",
            aboutArtworkURL: URL(string: "https://example.test/about.jpg"), followers: 6543,
            discoveredOnPlaylists: [playlist], artistPlaylists: [playlist])
        return CatalogArtistSnapshot(
            name: artist.title, releases: [release], item: artist, overview: overview,
            releaseKinds: [release.uri: .album], releaseDates: [release.uri: "2024-02-03"])
    }
}

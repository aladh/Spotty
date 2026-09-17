import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore
@testable import SpottyGateway

@Suite("Artist overview")
@MainActor
struct ArtistOverviewChecks {
    @Test func mapsBannerStatisticsPopularityAndReleaseMetadata() throws {
        let artist = try decodedArtist()
        let snapshot = CatalogMapping.artist(artist)
        let overview = try #require(snapshot.overview)
        #expect(overview.headerArtworkURL?.absoluteString == "https://example.test/banner-large.jpg")
        #expect(overview.monthlyListeners == 123456)
        #expect(overview.isVerified)
        #expect(overview.biography == "Fixture Artist makes music & mixes.\nA second paragraph.")
        #expect(overview.aboutArtworkURL?.absoluteString == "https://example.test/gallery-large.jpg")
        #expect(overview.followers == 6543)
        #expect(overview.discoveredOnPlaylists?.map(\.uri) == ["spotify:playlist:discovery"])
        #expect(overview.artistPlaylists?.map(\.uri) == ["spotify:playlist:curated"])
        #expect(overview.artistPlaylists?.first?.subtitle == "Artist's favorites")
        #expect(overview.popularTracks.map(\.track.uri) == ["spotify:track:first", "spotify:track:second"])
        #expect(overview.popularTracks.first?.playCount == 9_876_543_210)
        #expect(overview.popularTracks.first?.track.duration == 183.7)
        #expect(overview.popularTracks.first?.track.artists.first?.title == "Fixture Artist")
        #expect(overview.popularTracks.last?.playCount == nil)
        #expect(overview.popularTracks.last?.isPlayable == false)
        #expect(overview.popularReleases.map(\.subtitle) == ["2026 • EP"])
        #expect(snapshot.releases.first?.subtitle == "2024 • Album")
        #expect(snapshot.releaseKinds?["spotify:album:popular"] == .ep)
        #expect(snapshot.releaseKinds?["spotify:album:release"] == .album)
        #expect(snapshot.releaseDates?["spotify:album:release"]?.hasPrefix("2024") == true)
        let featuring = try #require(overview.featuringPlaylists)
        #expect(
            featuring.map(\.uri) == [
                "spotify:playlist:this-is", "spotify:playlist:radio", "spotify:playlist:editorial",
            ])
        #expect(featuring.map(\.subtitle) == ["Essential tracks.", "With Friends & Guests", "Artist's picks."])
        #expect(featuring.first?.artworkURL?.absoluteString == "https://example.test/this-is.jpg")
        #expect(featuring.allSatisfy { $0.kind == .playlist })
        let paged = artist.withDiscographyItems([])
        #expect(CatalogMapping.artist(paged).overview?.headerArtworkURL == overview.headerArtworkURL)
        #expect(CatalogMapping.artist(paged).overview?.featuringPlaylists == featuring)
        #expect(CatalogMapping.artist(paged).overview?.biography == overview.biography)
        #expect(CatalogMapping.artist(paged).overview?.aboutArtworkURL == overview.aboutArtworkURL)
        #expect(CatalogMapping.artist(paged).overview?.artistPlaylists == overview.artistPlaylists)
        #expect(CatalogMapping.artist(paged).overview?.discoveredOnPlaylists == overview.discoveredOnPlaylists)
    }

    @Test func missingOverviewFactsStayAbsent() throws {
        let value = try JSONDecoder().decode(
            PathfinderArtistResponse.self,
            from: Data(#"{"data":{"artistUnion":{"uri":"spotify:artist:empty","profile":{"name":"Empty"}}}}"#.utf8))
        let result = CatalogMapping.artist(try #require(value.data?.artistUnion))
        #expect(result.overview?.headerArtworkURL == nil)
        #expect(result.overview?.monthlyListeners == nil)
        #expect(result.overview?.isVerified == false)
        #expect(result.overview?.popularTracks.isEmpty == true)
        #expect(result.overview?.featuringPlaylists?.isEmpty == true)
        #expect(result.overview?.discoveredOnPlaylists?.isEmpty == true)
        #expect(result.overview?.artistPlaylists?.isEmpty == true)
        #expect(result.overview?.biography == nil)
        #expect(result.overview?.aboutArtworkURL == nil)
        #expect(result.overview?.followers == nil)
        #expect(result.releases.isEmpty)
        // The new optional fields also remain absent when decoding an older typed snapshot.
        let encoded = try JSONEncoder().encode(CatalogArtistSnapshot(name: "Old", releases: []))
        #expect(try JSONDecoder().decode(CatalogArtistSnapshot.self, from: encoded).overview == nil)
        let oldOverview = Data(#"{"isVerified":false,"popularTracks":[],"popularReleases":[]}"#.utf8)
        let old = try JSONDecoder().decode(CatalogArtistOverview.self, from: oldOverview)
        #expect(old.featuringPlaylists == nil)
        #expect(old.biography == nil && old.aboutArtworkURL == nil && old.followers == nil)
        #expect(old.discoveredOnPlaylists == nil && old.artistPlaylists == nil)
    }

    @Test func aboutUsesPortraitFallbackAndRejectsNegativeAudienceCounts() throws {
        let data = Data(
            #"""
            {"data":{"artistUnion":{"profile":{"name":"Portrait","biography":{"text":"<p> </p>"}},
              "visuals":{"avatarImage":{"sources":[{"url":"https://example.test/portrait.jpg"}]}},
              "stats":{"monthlyListeners":-1,"followers":-1}}}}
            """#.utf8)
        let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: data)
        let artist = try #require(response.data?.artistUnion)
        let overview = try #require(CatalogMapping.artist(artist).overview)
        #expect(overview.aboutArtworkURL?.absoluteString == "https://example.test/portrait.jpg")
        #expect(overview.biography == "")
        #expect(overview.monthlyListeners == nil && overview.followers == nil)
    }

    @Test func overviewRestoresWithItsRouteAndRetiresWithItsAccount() async throws {
        let profile = CatalogMapping.artist(try decodedArtist())
        let selected = try #require(profile.item)
        let other = CatalogItem(
            id: "other", uri: "spotify:artist:other", title: "Other", subtitle: "Artist", artworkURL: nil, kind: .artist
        )
        let provider = HarnessCatalog()
        provider.onArtistSnapshot = { id in
            id == "fixture" ? profile : CatalogArtistSnapshot(name: "Other", releases: [])
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session)
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
        provider.onArtistSnapshot = { _ in throw HarnessFailure.unavailable }
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
        let snapshot = CatalogMapping.artist(try decodedArtist())
        let selected = try #require(snapshot.item)
        let provider = HarnessCatalog()
        provider.onArtistSnapshot = { _ in snapshot }
        provider.onArtistDiscographySnapshot = { _ in throw HarnessFailure.unavailable }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session)

        await store.load(selected)

        #expect(provider.artistRequestCount == 1)
        #expect(provider.discographyRequestCount == 0)
        #expect(store.error == nil)
        #expect(!store.isLoading)
        #expect(store.overview == snapshot.overview)
        #expect(store.releases == snapshot.releases)
    }

    private func decodedArtist() throws -> PathfinderArtistUnion {
        let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: Data(Self.fixture.utf8))
        return try #require(response.data?.artistUnion)
    }

    private static let fixture = #"""
        {"data":{"artistUnion":{
          "uri":"spotify:artist:fixture","profile":{"name":"Fixture Artist",
            "biography":{"text":"<a href=\"spotify:artist:fixture\">Fixture Artist</a> makes music &amp; mixes.<br>A second paragraph."},
            "playlistsV2":{"items":[
              {"data":{"uri":"spotify:playlist:curated","name":"Artist selection","description":"Artist's favorites"}},
              {"data":{"uri":"spotify:playlist:curated","name":"Duplicate"}},
              {"data":{"__typename":"GenericError"}}, {"data":null}
            ]}},
          "visuals":{"avatarImage":{"sources":[{"url":"https://example.test/portrait.jpg"}]},
            "gallery":{"items":[{"sources":[
              {"url":"https://example.test/gallery-small.jpg","width":320},
              {"url":"https://example.test/gallery-large.jpg","width":1920}]}]}},
          "headerImage":{"data":{"sources":[
            {"url":"https://example.test/banner-small.jpg","maxWidth":320},
            {"url":"https://example.test/banner-large.jpg","maxWidth":1920}]}},
          "stats":{"monthlyListeners":123456,"followers":6543},
          "onPlatformReputationTrait":{"verification":{"isVerified":true}},
          "relatedContent":{"featuringV2":{"items":[
            {"data":{"__typename":"Playlist","uri":"spotify:playlist:this-is","name":"This Is Fixture Artist",
              "description":"Essential tracks.","images":{"items":[{"sources":[{"url":"https://example.test/this-is.jpg"}]}]}}},
            {"data":{"__typename":"Playlist","uri":"spotify:playlist:radio","name":"Fixture Artist Radio",
              "description":"With Friends &amp; Guests"}},
            {"data":{"__typename":"Playlist","uri":"spotify:playlist:editorial","name":"Guest's track IDs",
              "description":"<a href=\"spotify:artist:fixture\">Artist</a>'s picks."}},
            {"data":{"uri":"spotify:playlist:this-is","name":"Duplicate"}},
            {"data":{"__typename":"NotFound"}}, {"data":null},
            {"data":{"uri":"spotify:folder:unsupported","name":"Folder"}},
            {"data":{"uri":123,"name":"Malformed"}}
          ],"totalCount":8},"discoveredOnV2":{"items":[
            {"data":{"__typename":"GenericError"}},
            {"data":{"uri":"spotify:playlist:discovery","name":"Discovery","description":"Found here"}},
            {"data":{"uri":"spotify:playlist:discovery","name":"Duplicate"}},
            {"data":{"uri":"spotify:album:wrong-kind","name":"Wrong kind"}},
            {"data":{"uri":123,"name":"Malformed"}}
          ]}},
          "discography":{
            "topTracks":{"items":[
              {"track":{"uri":"spotify:track:first","name":"First","playcount":"9876543210",
                "duration":{"totalMilliseconds":183700},"playability":{"playable":true},
                "artists":{"items":[{"uri":"spotify:artist:fixture","profile":{"name":"Fixture Artist"}}]},
                "albumOfTrack":{"uri":"spotify:album:release","coverArt":{"sources":[{"url":"https://example.test/cover.jpg"}]}}}},
              {"track":{"uri":"spotify:track:second","name":"Second","playcount":"unknown","playability":{"playable":false}}}
            ]},
            "popularReleasesAlbums":{"items":[
              {"uri":"spotify:album:popular","name":"Popular","type":"EP","date":{"year":2026}},
              {"uri":"spotify:album:popular","name":"Popular","type":"EP","date":{"year":2026}}
            ]},
            "all":{"items":[{"releases":{"items":[
              {"uri":"spotify:album:release","name":"Release","type":"ALBUM","date":{"isoString":"2024-02-03T00:00:00Z","year":2024}}
            ]}}]}
          }
        }}}
        """#
}

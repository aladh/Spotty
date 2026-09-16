import Foundation
import AppKit
import SwiftUI
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Artist discography")
@MainActor
struct DiscographyChecks {
    @Test func hostedDiscographyLoadsVisibleAlbumSectionsWithoutFetchingTheWholeCatalog() async throws {
        let provider = HarnessCatalog()
        let artist = CatalogItem(
            id: "fixture", uri: "spotify:artist:fixture", title: "Fixture Artist", subtitle: "Artist", artworkURL: nil,
            kind: .artist)
        let releases = (0..<40).map { release("album-\($0)") }
        provider.onArtistSnapshot = { _ in CatalogArtistSnapshot(name: artist.title, releases: [], item: artist) }
        provider.onArtistDiscographySnapshot = { _ in CatalogArtistSnapshot(name: nil, releases: releases) }
        provider.onAlbumSnapshot = { id in
            CatalogAlbumSnapshot(
                tracks: (0..<3).map { HarnessFixtures.track(uri: "spotify:track:\(id)-\($0)") }, releaseDate: "2026")
        }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        let interaction = CatalogRouteInteractionState()
        let restoredTrack = HarnessFixtures.track(uri: "spotify:track:album-0-0")
        let restoredSelection = "\(releases[0].uri):\(restoredTrack.id)"
        interaction.selection = [restoredSelection]
        let host = NSHostingView(
            rootView: ArtistDiscographyView(
                item: artist, artist: player.catalog.artistStore, albums: player.catalog.discographyStore,
                playback: CatalogPlaybackAccess(player: player), playlistActions: nil, onSelect: { _ in },
                interactionState: interaction))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return player.catalog.discographyStore.albums.values.contains { $0.tracks.count == 3 }
        }
        #expect(provider.albumRequestCount > 0)
        #expect(provider.albumRequestCount < releases.count)
        #expect(player.catalog.artistStore.releases.count == releases.count)
        let album = try #require(player.catalog.discographyStore.albums[releases[0].uri])
        let track = try #require(album.tracks.first)
        let selection = "\(releases[0].uri):\(track.id)"
        #expect(selection == restoredSelection)
        #expect(interaction.selection == [selection], "retained selection survives mounting before albums load")
        host.layoutSubtreeIfNeeded()
        provider.onAlbumSnapshot = { _ in CatalogAlbumSnapshot(tracks: [], releaseDate: "2026") }
        await album.load(releases[0], force: true)
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return interaction.selection.isEmpty
        }
        provider.onAlbumSnapshot = { _ in CatalogAlbumSnapshot(tracks: [track], releaseDate: "2026") }
        await album.load(releases[0], force: true)
        host.layoutSubtreeIfNeeded()
        #expect(interaction.selection.isEmpty, "reappearing tracks do not regain a removed selection")
        await player.shutdownForTermination()
    }

    @Test func filtersTypesAndSortsDatesWithoutParsingDisplaySubtitles() {
        let releases = [
            release("old", title: "Zulu"), release("single", title: "Alpha"), release("new", title: "Beta"),
            release("unknown", title: "Gamma"),
        ]
        let kinds: [String: CatalogArtistReleaseKind] = [
            releases[0].uri: .album, releases[1].uri: .ep, releases[2].uri: .album,
        ]
        let dates = [releases[0].uri: "2020-02-03", releases[1].uri: "2026-01-02", releases[2].uri: "2026-04-05"]
        func shown(_ filter: ArtistReleaseFilter, _ sort: DiscographySort) -> [String] {
            DiscographyReleases.project(releases, kinds: kinds, dates: dates, filter: filter, sort: sort).map(\.title)
        }
        #expect(shown(.popular, .releaseDate) == ["Beta", "Alpha", "Zulu", "Gamma"])
        #expect(shown(.popular, .name) == ["Alpha", "Beta", "Gamma", "Zulu"])
        #expect(shown(.albums, .releaseDate) == ["Beta", "Zulu"])
        #expect(shown(.singles, .name) == ["Alpha"])
        #expect(shown(.compilations, .name).isEmpty)
    }

    @Test func discographyKeepsArtistIdentityAndBackHistory() {
        let navigation = CatalogNavigation()
        let artist = CatalogItem(
            id: "fixture", uri: "spotify:artist:fixture", title: "Fixture Artist", subtitle: "Artist", artworkURL: nil,
            kind: .artist)
        _ = navigation.select(artist)
        navigation.updateSelection(.discography(artist.uri))
        #expect(navigation.model.item(uri: artist.uri, kind: .artist, metadataItem: nil) == artist)
        _ = navigation.select(release("one"))
        navigation.goBack()
        #expect(navigation.selection == .discography(artist.uri))
        navigation.goBack()
        #expect(navigation.selection == .artist(artist.uri))
        navigation.goForward()
        #expect(navigation.selection == .discography(artist.uri))
    }

    @Test func visibleAlbumsReuseAlbumAdmissionAndKeepRetentionBounded() async {
        let provider = HarnessCatalog()
        provider.onAlbumSnapshot = { id in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session)
        metadata.replaceTracks([HarnessFixtures.track(uri: "spotify:track:album-page")], from: .album)
        store.prepare(artistURI: "spotify:artist:one")
        #expect(provider.albumRequestCount == 0)
        let first = release("first")
        await store.load(first, artistURI: "spotify:artist:one")
        await store.load(first, artistURI: "spotify:artist:one")
        #expect(provider.albumRequestCount == 1)
        #expect(store.albums[first.uri]?.tracks.count == 1)
        #expect(metadata.knownTrack(for: "spotify:track:first") != nil)
        #expect(metadata.knownTrack(for: "spotify:track:album-page") != nil)
        metadata.replaceTracks([HarnessFixtures.track(uri: "spotify:track:first", title: "Album page")], from: .album)
        #expect(metadata.knownTrack(for: "spotify:track:first")?.title == "Album page")
        #expect(metadata.runtimeTracks["spotify:track:first"]?.title == "Album page")
        metadata.replaceTracks([HarnessFixtures.track(uri: "spotify:track:album-page")], from: .album)
        for number in 0..<22 { await store.load(release("album-\(number)"), artistURI: "spotify:artist:one") }
        #expect(store.albums.count == 20)
        #expect(store.albums[first.uri] == nil)
        #expect(metadata.knownTrack(for: "spotify:track:first") == nil)
        store.prepare(artistURI: "spotify:artist:two")
        #expect(store.albums.isEmpty)
        #expect(metadata.knownTrack(for: "spotify:track:album-page") != nil)
        let calls = provider.albumRequestCount
        await store.load(first, artistURI: "spotify:artist:one")
        #expect(provider.albumRequestCount == calls)
    }

    private func release(_ id: String, title: String = "Album") -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:album:\(id)", title: title, subtitle: "Localized display text", artworkURL: nil,
            kind: .album)
    }
}

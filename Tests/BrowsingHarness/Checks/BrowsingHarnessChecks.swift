import AppKit
import Foundation
import ImageIO
import Testing
@testable import SpottyBrowsingSupport
@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyGateway

@Suite("Synthetic browsing", .serialized)
@MainActor
struct BrowsingHarnessTests {
    private func scenario() -> BrowsingScenario {
        BrowsingScenario(trackCount: 30, artworkCount: 2, artworkPixels: 64, cycles: 1)
    }

    @Test func searchUsesBrowsableSyntheticEntitiesAndHonorsQueryAndLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottySearchDemo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try BrowsingWorld(scenario: scenario(), artworkDirectory: root)
        let tracks = try await world.searchTracks("HARBOR", limit: 3)
        #expect(tracks.count == 3)
        #expect(tracks.allSatisfy { $0.artist == "Harbor Lights" && $0.albumItem != nil })
        let artists = try await world.searchArtists("harbor", limit: 30)
        #expect(artists.map(\.title) == ["Harbor Lights"])
        let albums = try await world.searchAlbums("signals dusk", limit: 30)
        #expect(albums.map(\.title) == ["Signals at Dusk"])
        let playlists = try await world.searchPlaylists("moonlit", limit: 30)
        #expect(playlists.map(\.title) == ["Moonlit Drive"])
        #expect(try await world.searchTracks("no-such-result", limit: 50).isEmpty)
        #expect(try await world.searchAlbums("", limit: 30).isEmpty)
        #expect(try await world.searchTracks("harbor", limit: 0).isEmpty)
        #expect(world.snapshot().mutationAttempts == 0)
    }

    @Test(arguments: [BrowsingScenario.Mode.browsing, .signedOut])
    func unsupportedClearDoesNotReportAStoredLoginRemovalFailure(mode: BrowsingScenario.Mode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyBrowsingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        input.mode = mode
        let world = try BrowsingWorld(scenario: input, artworkDirectory: root)

        #expect(await world.clear(), "this world has no persisted login that can fail removal")
        #expect(world.snapshot().mutationAttempts == 1, "unsupported mutations still fail read-only acceptance")
        #expect(await world.hasGrant() == (mode == .browsing), "a rejected action does not mutate the scenario")
    }

    @Test
    func remotePlayUsesSemanticTrackSelection() throws {
        let playback = SyntheticPlayback()
        try playback.send(.play(uri: "spotify:playlist:synthetic1", trackIndex: 7), to: SyntheticPlayback.remoteID)
        #expect(playback.queueSnapshot().track?.uri == "spotify:track:synthetic1x7")
        try playback.send(.play(uri: "spotify:track:synthetic0x3"), to: SyntheticPlayback.remoteID)
        #expect(playback.queueSnapshot().track?.uri == "spotify:track:synthetic0x3")
        try playback.send(
            .play(trackURIs: ["spotify:track:synthetic0x5", "spotify:track:synthetic0x6"]),
            to: SyntheticPlayback.remoteID)
        #expect(playback.queueSnapshot().track?.uri == "spotify:track:synthetic0x5")
    }

    @Test
    func playbackControlsAndFaultsUseProductionIntake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyPlaybackDemo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        input.version = 2
        input.mode = .playback
        let world = try BrowsingWorld(scenario: input, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        await player.restore()
        let checkpoints: [PlaybackTraceCheckpoint]
        do {
            checkpoints = try await PlaybackTrace.run(player: player, world: world)
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        #expect(checkpoints.count == 8)
        #expect(checkpoints.prefix(3).allSatisfy { $0.intentOutcome == "observedConfirmed" })
        #expect(
            checkpoints.prefix(3).allSatisfy {
                $0.admissionToDispatchMilliseconds != nil
                    && $0.admissionToSettlementMilliseconds != nil && $0.actionToStateFeedbackMilliseconds != nil
            })
        #expect(world.snapshot().mutationAttempts == 0)
        #expect(world.playback.snapshot().rejectedCount == 1)
        await player.shutdownForTermination()
    }

    @Test
    func fixtureValidationAndRepeatability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpottyBrowsingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        #expect(try BrowsingScenario.decode(JSONEncoder().encode(input)) == input)
        input.combinedHydration = true
        #expect(throws: (any Error).self) { try input.validate() }
        input = scenario()
        input.version = 3
        #expect(throws: (any Error).self) { try input.validate() }
        input = scenario()
        input.trackCount = 0
        #expect(throws: (any Error).self) { try input.validate() }
        input = scenario()
        input.artworkPixels = 100_000
        #expect(throws: (any Error).self) { try input.validate() }
        #expect(throws: (any Error).self) { try BrowsingScenario.decode(Data("{}".utf8)) }
        let first = try BrowsingFixtures(scenario: scenario(), artworkDirectory: root.appendingPathComponent("first"))
        let second = try BrowsingFixtures(scenario: scenario(), artworkDirectory: root.appendingPathComponent("second"))
        #expect(
            try first.artworkURLs.map { try Data(contentsOf: $0) }
                == second.artworkURLs.map { try Data(contentsOf: $0) })
        let tracks = try #require(first.details["synthetic0"]?.content?.items)
        #expect(tracks.count == 30)
        #expect(Set(tracks.compactMap(\.uid)).count == 30)
        #expect(tracks.map(\.track?.uri) == second.details["synthetic0"]?.content?.items?.map(\.track?.uri))
        let source = try #require(
            CGImageSourceCreateWithData(try Data(contentsOf: first.artworkURLs[0]) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 64)
    }

    @Test
    func restoreAndBrowseUseOnlyInjectedWorld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpottyBrowsingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try BrowsingWorld(scenario: scenario(), artworkDirectory: root)
        let environment = world.environment
        #expect(try await world.libraryAlbums().isEmpty)
        for port: AnyObject in [
            environment.account as AnyObject, environment.catalog as AnyObject,
            environment.local as AnyObject, environment.remote as AnyObject,
            environment.webQueue as AnyObject, environment.audioOutput as AnyObject,
            environment.preferences as AnyObject, environment.lifecycle as AnyObject,
            environment.clock as AnyObject,
        ] {
            let isWorld = port === world
            #expect(isWorld)
        }
        let player = PlaybackStore(environment: environment, feedback: TransientFeedbackPresenter(clock: world))
        await player.restore()
        await player.effects.settlement(of: .catalogLoad)?.wait()
        #expect(player.accountStore.phase == .ready)
        #expect(player.catalog.homeLibrary.homeSections.count == 1)
        let items = player.catalog.homeLibrary.playlists
        #expect(items.count == 2)
        for item in items + items {
            await player.catalog.playlistStore.load(item)
            #expect(player.catalog.playlistStore.tracks.count == 30)
            #expect(player.catalog.playlistStore.loadedURI == item.uri)
            #expect(player.catalog.playlistStore.error == nil)
        }
        let playlistReads = world.snapshot().requests
        #expect(playlistReads["playlist.synthetic0"] == 1, "plain revisits reuse the retained first playlist")
        #expect(playlistReads["playlist.synthetic1"] == 1, "plain revisits reuse the retained second playlist")
        #expect(world.snapshot().mutationAttempts == 0)
        await player.shutdownForTermination()
        #expect(player.accountStore.phase == .signedOut)
        #expect(world.snapshot().requests["engine.synthetic-shutdown"] == 1)
    }

    @Test
    func expandedLibraryAlbumsAndArtistsCanBeBrowsedThroughTheInjectedCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpottyAlbumDemo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        input.expandedLibrary = true
        let world = try BrowsingWorld(scenario: input, artworkDirectory: root)
        let home = try await world.home()
        let albums = try await world.libraryAlbums()
        #expect(home.sections.first { $0.id == "synthetic-albums" }?.items == albums)
        #expect(!albums.isEmpty)
        for item in albums {
            let id = String(item.uri.dropFirst("spotify:album:".count))
            let album = try await world.album(id: id)
            #expect(album.item == item)
            #expect(album.tracks.allSatisfy { $0.albumItem == item })
        }
        let artists = try #require(home.sections.first { $0.id == "synthetic-artists" }?.items)
        #expect(artists.count == 5)
        for item in artists {
            let id = String(item.uri.dropFirst("spotify:artist:".count))
            let artist = try await world.artist(id: id)
            #expect(artist.item == item)
            #expect(try await world.artistDiscography(id: id).releases == artist.releases)
            for release in artist.releases {
                let albumID = String(release.uri.dropFirst("spotify:album:".count))
                #expect(try await world.album(id: albumID).item == release)
            }
        }
        #expect(world.snapshot().mutationAttempts == 0)
    }

    @Test
    func signedOutDoesNotInitializeAndCommandsFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpottyBrowsingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        input.mode = .signedOut
        let world = try BrowsingWorld(scenario: input, artworkDirectory: root)
        let player = PlaybackStore(environment: world.environment, feedback: TransientFeedbackPresenter(clock: world))
        await player.restore()
        #expect(player.accountStore.phase == .signedOut)
        #expect(world.snapshot().requests["engine.synthetic-initialize"] == nil)
        #expect(world.execute(.pause) == .error)
        #expect(world.snapshot().mutationAttempts == 1)
        await player.shutdownForTermination()
    }

    @Test
    func navigationHistoryAndAccountReset() {
        let navigation = CatalogNavigation()
        navigation.updateSelection(.destination(.search))
        navigation.searchText = "fixture"
        navigation.updateSelection(.destination(.albums))
        navigation.goBack()
        #expect(navigation.selection == .destination(.search))
        #expect(navigation.searchText == "fixture")
        navigation.goForward()
        #expect(navigation.selection == .destination(.albums))
        navigation.goBack()
        navigation.updateSelection(.destination(.artists))
        #expect(navigation.forwardHistory.isEmpty)
        navigation.reset()
        #expect(navigation.selection == .destination(.home))
        #expect(navigation.backHistory.isEmpty && navigation.forwardHistory.isEmpty)
        #expect(navigation.searchText.isEmpty)
    }

    @Test
    func scrollLookupUsesOwnedTrackContainerInsteadOfDocumentHeight() {
        let root = NSView()
        let sidebar = NSScrollView()
        sidebar.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 10_000))
        let playlist = NativeTrackTableContainer(variant: .playlist)
        root.addSubview(sidebar)
        root.addSubview(playlist)
        #expect(BrowsingRun.findPlaylistScrollView(in: root) === playlist.scrollView)
        #expect(BrowsingRun.findPlaylistScrollView(in: root, retaining: playlist.scrollView) === playlist.scrollView)
        playlist.removeFromSuperview()
        #expect(BrowsingRun.findPlaylistScrollView(in: root, retaining: playlist.scrollView) == nil)
        #expect(BrowsingRun.findPlaylistScrollView(in: root) == nil)
    }

    @Test
    func fixtureFilesAreReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpottyBrowsingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try BrowsingWorld(scenario: scenario(), artworkDirectory: root)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in world.fixtures.artworkURLs {
            #expect(url.isFileURL)
            #expect(url.deletingLastPathComponent().path == root.path)
            let (data, _) = try await session.data(from: url)
            #expect(data == (try Data(contentsOf: url)))
        }
    }
}

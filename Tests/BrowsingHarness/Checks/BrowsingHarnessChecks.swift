import Foundation
import ImageIO
import Testing
@testable import SpottyBrowsingSupport
@testable import SpottyCore

@Suite("Synthetic browsing", .serialized)
@MainActor
struct BrowsingHarnessTests {
    private func scenario() -> BrowsingScenario {
        BrowsingScenario(trackCount: 30, artworkCount: 2, artworkPixels: 64, cycles: 1)
    }

    @Test
    func fixtureValidationAndRepeatability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpottyBrowsingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = scenario()
        #expect(try BrowsingScenario.decode(JSONEncoder().encode(input)) == input)
        input.version = 2
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
        for port: AnyObject in [
            environment.account as AnyObject, environment.catalog as AnyObject,
            environment.local as AnyObject, environment.remote as AnyObject,
            environment.webQueue as AnyObject, environment.audioOutput as AnyObject,
            environment.preferences as AnyObject, environment.lifecycle as AnyObject,
            environment.clock as AnyObject, environment.playlistMutations as AnyObject,
            environment.trackAttributes as AnyObject,
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
        #expect(world.snapshot().requests["playlist.synthetic0"] == 2)
        #expect(world.snapshot().requests["playlist.synthetic1"] == 2)
        #expect(world.snapshot().mutationAttempts == 0)
        await player.shutdownForTermination()
        #expect(player.accountStore.phase == .signedOut)
        #expect(world.snapshot().requests["engine.synthetic-shutdown"] == 1)
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
    func artworkUsesLocalURLLoading() async throws {
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

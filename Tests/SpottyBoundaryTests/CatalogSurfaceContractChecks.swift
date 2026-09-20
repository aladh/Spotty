import AppKit
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Hosted catalog interaction contract")
@MainActor
struct CatalogSurfaceContractChecks {
    enum Surface: String, CaseIterable {
        case card, expandedHeader, compactHeader, sidebar, searchPreview, searchTable, discography, queue, history
        var isCollection: Bool { [.card, .expandedHeader, .compactHeader, .sidebar, .discography].contains(self) }
    }

    @Test(arguments: Surface.allCases, ["local-paused", "local-playing", "remote-paused", "remote-playing"])
    func actualControlsShareTheTransportContract(surface: Surface, state: String) async throws {
        let local = state.hasPrefix("local")
        let playing = state.hasSuffix("-playing")
        let fixture = Fixture(surface: surface, local: local, playing: playing)
        let hosted = try await fixture.host()
        defer { hosted.detach(); fixture.player.effects.cancelAccountScoped() }
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0, "discovering controls cannot play")
        try await hosted.activatePlaybackControl()
        try await requireEventually { local ? fixture.engine.executeCount == 1 : fixture.remote.sendCount == 1 }
        if local {
            switch try #require(fixture.engine.operations.first) {
            case let .playURI(uri):
                #expect(surface == .history && uri == Fixture.track.uri)
            case .pause: #expect(playing && surface != .history)
            case let .resumeObserved(target):
                #expect(!playing && surface != .history)
                #expect(target.trackURI == Fixture.track.uri && target.positionMS == 42_000)
                #expect(target.contextURI == fixture.collection.uri)
            default: Issue.record("A current surface control must pause/resume; history explicitly restarts")
            }
        } else {
            #expect(fixture.remote.endpoints == [surface == .history ? .play : playing ? .pause : .resume])
        }
        if surface != .history { #expect(fixture.player.position == 42) }
        await fixture.player.shutdownForTermination()
    }

    @Test(arguments: [Surface.sidebar, .searchPreview, .queue, .history])
    func nativeRowsShareSelectionTabReturnAndSingleSpaceActivation(surface: Surface) async throws {
        let fixture = Fixture(surface: surface, local: false, playing: false)
        let hosted = try await fixture.host()
        defer { hosted.detach(); fixture.player.effects.cancelAccountScoped() }
        let table = try await hosted.table()
        let selected = surface == .queue || surface == .searchPreview ? 1 : 0
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        try #require(hosted.window.makeFirstResponder(table))
        table.keyDown(with: try hosted.key(48, "\t"))
        try await requireEventually { hosted.window.firstResponder !== table }
        #expect(table.selectedRowIndexes == IndexSet(integer: selected))
        #expect(fixture.remote.sendCount == 0)
        hosted.window.sendEvent(try hosted.key(48, "\u{19}", shift: true))
        try await requireEventually { hosted.window.firstResponder === table }
        table.keyDown(with: try hosted.key(48, "\t"))
        try await requireEventually { hosted.window.firstResponder !== table }
        hosted.window.sendEvent(try hosted.key(49, " "))
        hosted.window.sendEvent(try hosted.key(49, " ", repeatKey: true))
        hosted.window.sendEvent(try hosted.key(49, " ", up: true))
        try await requireEventually { fixture.remote.sendCount == 1 }
        #expect(fixture.remote.endpoints == [surface == .history ? .play : .resume])
        #expect(table.window === hosted.window && table.selectedRowIndexes == IndexSet(integer: selected))
        await fixture.player.shutdownForTermination()
        #expect(fixture.remote.sendCount == 1, "one Space press, including repeat/up phases, dispatches once")
    }

    @MainActor
    private final class Fixture {
        nonisolated static let track = HarnessFixtures.track(
            uri: "spotify:track:current", title: "Current", duration: 200)
        let surface: Surface
        let engine = HarnessEngine(position: 42_000)
        let remote = HarnessRemote(send: .park)
        let provider = HarnessCatalog()
        let player: PlaybackStore
        let collection: CatalogItem
        var selection: Set<String> = []
        var sidebarSelection: SidebarSelection?

        init(surface: Surface, local: Bool, playing: Bool) {
            self.surface = surface
            collection = CatalogItem(
                id: "collection", uri: "spotify:\(surface == .discography ? "album" : "playlist"):collection",
                title: "Collection", subtitle: "", artworkURL: nil, kind: surface == .discography ? .album : .playlist)
            player = HarnessEnvironment.makePlaybackStore(
                HarnessEnvironment.make(engine: engine, remote: remote, catalog: provider))
            let context = collection.uri
            player.withRuntime {
                let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local)
                let timing = PlaybackTiming(position: 42, duration: 200, anchoredAt: HarnessDates.fixed)
                $0.accountStore.publishPhase(.ready)
                _ = $0.send(.session(.ready), source: .account)
                _ = $0.send(
                    .devices(PlaybackDeviceSnapshot(devices: [device], localDeviceID: "mac", revision: 1)),
                    source: .engineDevices, revision: 1)
                _ = $0.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: playing ? .playing : .paused, trackURI: Self.track.uri, timing: timing,
                            contextURI: context, isActiveDevice: local)), source: .enginePlayback, revision: 1)
                _ = $0.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: Self.track.uri, title: "Current", artist: "Artist", duration: 200,
                                metadataSource: .catalog),
                            transport: playing ? .playing : .paused, timing: timing)), source: .user)
                _ = $0.send(
                    .owner(
                        local
                            ? .local(device) : .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
                    source: .engineConnection)
                $0.history.notePlayed(
                    uri: Self.track.uri, title: "Current", artist: "Artist", artworkURL: nil,
                    playedAt: HarnessDates.fixed)
            }
        }

        func host() async throws -> HostedSurfaceHarness {
            let access = CatalogPlaybackAccess(player: player)
            let action = access.action(for: collection, behavior: .activateSelection)
            let selection = Binding(get: { self.selection }, set: { self.selection = $0 })
            switch surface {
            case .card:
                return HostedSurfaceHarness(
                    CatalogCardPlayButton(item: collection, playback: access, isHovering: false))
            case .expandedHeader:
                return HostedSurfaceHarness(DetailActionRow(action: action))
            case .compactHeader:
                return HostedSurfaceHarness(CompactMediaDetailHeader(title: collection.title, action: action))
            case .sidebar:
                return HostedSurfaceHarness(
                    SidebarView(
                        selection: Binding(get: { self.sidebarSelection }, set: { self.sidebarSelection = $0 }),
                        library: [PlaylistLibraryNode(playlist: collection)], playback: access))
            case .searchPreview, .searchTable:
                provider.onSearchTracks = { _, _ in [Self.track] }
                await player.catalog.searchStore.search("Current")
                let interaction = SearchInteractionState()
                interaction.prepare(for: "Current")
                interaction.filter = surface == .searchTable ? .songs : .all
                return HostedSurfaceHarness(
                    SearchView(
                        store: player.catalog.searchStore, playback: access, searchText: .constant("Current"),
                        interaction: interaction, onSelect: { _ in },
                        playlistActions: TrackPlaylistActions(
                            editablePlaylists: [], canRemoveOccurrences: false, addToPlaylist: { _, _ in },
                            removeOccurrences: { _ in })))
            case .discography:
                let artist = CatalogItem(
                    id: "artist", uri: "spotify:artist:artist", title: "Artist", subtitle: "", artworkURL: nil,
                    kind: .artist)
                let release = collection
                provider.onArtistDiscographySnapshot = { _ in .init(name: "Artist", releases: [release]) }
                provider.onAlbumSnapshot = { _ in .init(tracks: [Self.track], releaseDate: "2026") }
                let albums = player.catalog.discographyStore
                albums.prepare(artistURI: artist.uri)
                await albums.artist.load(artist)
                return HostedSurfaceHarness(
                    ArtistDiscographyView(
                        item: artist, albums: albums, playback: access, playlistActions: nil, onSelect: { _ in },
                        interactionState: CatalogRouteInteractionState(isPlaylist: false)))
            case .queue:
                return HostedSurfaceHarness(
                    SidePanelView(
                        metadata: player.catalog.metadata, player: player, panel: .queue, selection: selection,
                        historySelection: .constant([]), onSelect: { _ in }, onClose: {}))
            case .history:
                return HostedSurfaceHarness(
                    HistoryListView(
                        entries: player.history, metadata: player.catalog.metadata,
                        actions: SidePanelPlaybackActions(player: player),
                        onSelect: { _ in }, selection: selection, scrollState: NativeListScrollState()))
            }
        }
    }
}

import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private let publishedPriorTrack = CurrentTrack(
    uri: "spotify:track:a", title: "A", artist: "Artist", duration: 200, metadataSource: .catalog)
private let publishedNextTrack = HarnessFixtures.track(uri: "spotify:track:b", title: "B", duration: 180)
private let publishedPriorPlayTiming = PlaybackTiming(
    position: 40, duration: 200, anchoredAt: HarnessDates.fixed.addingTimeInterval(-10))

@MainActor
private final class PlayPresentationFixture {
    let player: PlaybackStore
    let engine = HarnessEngine()
    let remote = HarnessRemote(send: .park)
    let gate = HarnessEngineGate()
    private let useLocal: Bool

    init(useLocal: Bool) {
        self.useLocal = useLocal
        if useLocal { engine.onExecute = { [gate] _ in gate.enter() } }
        let catalog = HarnessCatalog()
        catalog.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "", ownerURI: nil, tracks: [publishedNextTrack])
        }
        player = HarnessEnvironment.makePlaybackStore(
            HarnessEnvironment.make(engine: engine, remote: remote, catalog: catalog))
    }

    func seed() throws {
        try #require(player.send(.session(.ready), source: .account))
        try #require(
            player.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: useLocal),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: !useLocal),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        try #require(
            player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: publishedPriorTrack, transport: .playing, timing: publishedPriorPlayTiming)),
                source: .user))
    }

    func requireDispatch() async throws {
        try await requireEventually(description: "The desktop play request enters its dependency") {
            useLocal ? gate.enteredCount == 1 : remote.parkedSendCount == 1
        }
    }

    func reply(accepted: Bool) throws {
        if useLocal {
            gate.finish(with: accepted ? .ok : .error)
        } else {
            try #require(remote.completePark(success: accepted))
        }
    }

    func cleanUp() async {
        gate.close()
        await player.shutdownForTermination()
    }
}

@MainActor
private func withPlayPresentation(
    useLocal: Bool,
    _ body: (PlayPresentationFixture) async throws -> Void
) async throws {
    let fixture = PlayPresentationFixture(useLocal: useLocal)
    do {
        try fixture.seed()
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

@Suite("Play publication")
@MainActor
struct PlayPublicationTests {
    @Test(arguments: [false, true])
    func rejectedPlayPublishesRestoredTrackTimelineAndNotice(useLocal: Bool) async throws {
        try await withPlayPresentation(useLocal: useLocal) { fixture in
            let player = fixture.player
            player.play(track: publishedNextTrack)
            #expect(player.trackURI == publishedNextTrack.uri)
            #expect(player.trackTitle == publishedNextTrack.title)
            #expect(player.timeline == PlaybackTiming(position: 0, duration: 180, anchoredAt: HarnessDates.fixed))
            #expect(player.isPlaying)
            try await fixture.requireDispatch()
            try fixture.reply(accepted: false)
            // Only publications are read after the reply. Compatibility effect handles would
            // apply a fresh runtime snapshot and hide a missing subscription update.
            try await requireEventually(description: "The desktop publishes the play rollback and action notice") {
                player.semantic.currentTrack == publishedPriorTrack && player.timeline == publishedPriorPlayTiming
                    && player.transientCommandError == "Could not play that Spotify URI" && player.canStartPlayback
            }
            #expect(player.history.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func observedPlaybackPublishesHistoryAfterTheAcceptedRequest(useLocal: Bool) async throws {
        try await withPlayPresentation(useLocal: useLocal) { fixture in
            let player = fixture.player
            let runtime = player.runtime
            player.play(track: publishedNextTrack)
            try await fixture.requireDispatch()
            try fixture.reply(accepted: true)
            try await requireEventually(description: "The accepted request releases the displayed controls") {
                player.canStartPlayback
            }
            #expect(player.history.isEmpty)
            // Inject the observation at its owner without synchronizing the desktop facade.
            // History must cross the ordinary publication subscription to become visible.
            try #require(
                await runtime.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing, trackURI: publishedNextTrack.uri,
                            timing: PlaybackTiming(position: 1, duration: 180, anchoredAt: HarnessDates.fixed))),
                    source: .enginePlayback, revision: 1))
            try await requireEventually(description: "Observed playback publishes one history entry") {
                player.history.map(\.uri) == [publishedNextTrack.uri]
            }
        }
    }

    @Test(arguments: [false, true])
    func playlistSelectionUsesOnlyLoadedContents(loaded: Bool) async throws {
        try await withPlayPresentation(useLocal: true) { fixture in
            let player = fixture.player
            let playlist = CatalogItem(
                id: "playlist", uri: "spotify:playlist:selected", title: "Mix", subtitle: "", artworkURL: nil,
                kind: .playlist)
            if loaded {
                player.withRuntime { $0.accountStore.publishPhase(.ready) }
                await player.catalog.playlistStore.load(playlist)
                try #require(player.catalog.playlistStore.tracks == [publishedNextTrack])
            }
            player.playPlaylist(playlist)
            #expect(player.trackURI == (loaded ? publishedNextTrack.uri : publishedPriorTrack.uri))
            #expect(player.trackTitle == (loaded ? publishedNextTrack.title : publishedPriorTrack.title))
            #expect(player.history.isEmpty)
            try await fixture.requireDispatch()
            #expect(fixture.engine.operations.count == 1)
            guard case let .playURI(uri)? = fixture.engine.operations.first else {
                Issue.record("Playlist selection must dispatch the selected context")
                return
            }
            #expect(uri == playlist.uri)
            try fixture.reply(accepted: !loaded)
            try await requireEventually(
                description: "The desktop publishes playlist settlement without invented history"
            ) {
                player.canStartPlayback && player.semantic.currentTrack == publishedPriorTrack
                    && player.transientCommandError == (loaded ? "Could not play that Spotify URI" : nil)
            }
            #expect(player.timeline == publishedPriorPlayTiming)
            #expect(player.history.isEmpty)
        }
    }
}

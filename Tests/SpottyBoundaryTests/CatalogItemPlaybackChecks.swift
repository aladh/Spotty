import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Catalog item playback controls")
@MainActor
struct CatalogItemPlaybackChecks {
    @Test(arguments: [CatalogItem.Kind.playlist, .album, .artist, .track], [false, true])
    func currentSelectionPausesOrResumesWithoutRestarting(kind: CatalogItem.Kind, playing: Bool) async throws {
        for local in [false, true] {
            let engine = HarnessEngine(position: 42_000)
            let remote = HarnessRemote(send: .park)
            let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
            let item = selection(kind)
            player.withRuntime { seed($0, item: item, playing: playing, local: local) }
            let access = CatalogPlaybackAccess(player: player)
            #expect(access.canActivateItem(item))
            #expect(access.showsPause(for: item) == playing)
            #expect(access.activationLabel(for: item) == "\(playing ? "Pause" : "Play") Selection")
            let trackURI = player.trackURI
            let contextURI = player.playingContextURI
            let generation = player.engineGeneration
            access.activateItem(item)
            try await requireEventually { local ? engine.executeCount == 1 : remote.sendCount == 1 }
            if local {
                #expect(remote.sendCount == 0)
                switch try #require(engine.operations.first) {
                case .pause:
                    #expect(playing)
                case let .resumeObserved(target):
                    #expect(!playing)
                    #expect(
                        target
                            == PlaybackResumeTarget(
                                trackURI: trackURI, contextURI: contextURI, positionMS: 42_000,
                                engineGeneration: generation))
                default:
                    Issue.record("The current selection must pause/resume, never load again")
                }
            } else {
                #expect(engine.operations.isEmpty)
                #expect(remote.endpoints == [playing ? .pause : .resume])
                #expect(!access.canActivateItem(item), "pending transport disables repeated activation")
                access.activateItem(item)
                #expect(remote.sendCount == 1)
            }
            #expect(player.trackURI == trackURI && player.position == 42)
            #expect(player.playingContextURI == contextURI)
            await player.shutdownForTermination()
        }
    }

    @Test(arguments: [CatalogItem.Kind.playlist, .album, .artist], [false, true])
    func retainedControlCannotPauseAnotherContextWithTheSameTrack(kind: CatalogItem.Kind, published: Bool) async throws
    {
        let remote = HarnessRemote(send: .park)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(remote: remote))
        let item = selection(kind)
        player.withRuntime { seed($0, item: item, playing: true) }
        let access = CatalogPlaybackAccess(player: player)
        #expect(access.showsPause(for: item))
        let other = selection(kind, id: "other")
        if published {
            player.withRuntime { seed($0, item: other, playing: true, revision: 2) }
            #expect(!access.showsPause(for: item))
        } else {
            let runtime = player.runtime
            SessionRuntimeActor.sync { seed(runtime, item: other, playing: true, revision: 2) }
            #expect(player.playingContextURI == item.uri, "the displayed Pause control has not caught up")
        }
        #expect(player.trackURI == "spotify:track:current", "track membership cannot identify a collection")
        access.activateItem(item)
        try await requireEventually { remote.sendCount == 1 }
        #expect(remote.endpoints == [.play])
        #expect(remote.commands.first?.context?.uri == item.uri)
        await player.shutdownForTermination()
    }

    @Test func rejectedResumeDisablesCurrentSelectionButAllowsAnother() async throws {
        let engine = HarnessEngine(executeResult: .resumeMismatch, position: 42_000)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
        let item = selection(.playlist)
        player.withRuntime { seed($0, item: item, playing: false, local: true) }
        let access = CatalogPlaybackAccess(player: player)
        access.activateItem(item)
        try await requireEventually { player.playbackNotice?.kind == .resumeUnavailable }
        #expect(!access.canActivateItem(item))
        #expect(!access.showsPause(for: item))
        #expect(access.canStartPlayback, "shuffle and new selections remain available")
        let before = player.state
        access.activateItem(item)
        #expect(player.state == before)
        #expect(engine.executeCount == 1)
        let other = selection(.playlist, id: "other")
        #expect(access.canActivateItem(other))
        engine.executeResult = .ok
        access.activateItem(other)
        try await requireEventually { engine.executeCount == 2 }
        if case let .playURI(uri) = engine.operations.last {
            #expect(uri == other.uri)
        } else {
            Issue.record("Choosing another playlist starts its own context")
        }
        await player.shutdownForTermination()
    }

    @Test func disconnectedAndReplacedAccountControlsCannotActivate() async {
        let engine = HarnessEngine()
        let remote = HarnessRemote()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
        let item = selection(.playlist)
        let access = CatalogPlaybackAccess(player: player)
        #expect(!access.canActivateItem(item) && !access.showsPause(for: item))
        access.activateItem(item)
        player.withRuntime { seed($0, item: item, playing: true) }
        #expect(access.canActivateItem(item) && access.showsPause(for: item))
        player.withRuntime {
            $0.accountStore.advanceEpoch()
            _ = $0.send(.reset(session: .ready), source: .account)
            seed($0, item: item, playing: true)
        }
        let replacement = player.state
        #expect(!access.canActivateItem(item) && !access.showsPause(for: item))
        access.activateItem(item)
        #expect(player.state == replacement)
        await player.shutdownForTermination()
        #expect(engine.operations.isEmpty && remote.sendCount == 0)
    }

    @Test(arguments: [false, true])
    func unpublishedEngineOrOwnerReplacementRejectsTheOldControl(changesOwner: Bool) async {
        let engine = HarnessEngine()
        let remote = HarnessRemote()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
        let item = selection(.playlist)
        player.withRuntime { seed($0, item: item, playing: true, local: true) }
        let access = CatalogPlaybackAccess(player: player)
        let runtime = player.runtime
        SessionRuntimeActor.sync {
            if changesOwner {
                _ = runtime.send(
                    .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
                    source: .engineConnection)
            } else {
                _ = runtime.send(.reset(session: .ready), source: .account, engineEpoch: runtime.engineGeneration + 1)
                seed(runtime, item: item, playing: true, local: true)
            }
        }
        access.activateItem(item)
        await player.shutdownForTermination()
        #expect(engine.operations.isEmpty && remote.sendCount == 0)
    }

    private func selection(_ kind: CatalogItem.Kind, id: String = "selection") -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: "Selection", subtitle: "",
            artworkURL: nil, kind: kind)
    }

    @SessionRuntimeActor
    private func seed(
        _ runtime: PlaybackSessionRuntime, item: CatalogItem, playing: Bool, local: Bool = false,
        revision: UInt64 = 1
    ) {
        let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local)
        let trackURI = item.kind == .track ? item.uri : "spotify:track:current"
        let contextURI = item.kind == .track ? "spotify:playlist:context" : item.uri
        let timing = PlaybackTiming(position: 42, duration: 200, anchoredAt: HarnessDates.fixed)
        _ = runtime.send(.session(.ready), source: .account)
        _ = runtime.send(
            .devices(PlaybackDeviceSnapshot(devices: [device], localDeviceID: "mac", revision: revision)),
            source: .engineDevices, revision: revision)
        _ = runtime.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: playing ? .playing : .paused, trackURI: trackURI, timing: timing,
                    contextURI: contextURI, isActiveDevice: local)), source: .enginePlayback, revision: revision)
        _ = runtime.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: trackURI, title: "Current", artist: "Artist", duration: 200,
                        metadataSource: .catalog),
                    transport: playing ? .playing : .paused, timing: timing)), source: .user)
        _ = runtime.send(
            .owner(
                local
                    ? .local(device)
                    : .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
            source: .engineConnection)
    }
}

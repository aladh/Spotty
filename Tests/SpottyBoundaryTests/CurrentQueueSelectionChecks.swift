import AppKit
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Current queue row selection")
@MainActor
struct CurrentQueueSelectionChecks {
    @Test(arguments: [false, true], [false, true])
    func currentRowSupportsNativeSelectionAndRetainedTransport(playing: Bool, local: Bool) async throws {
        let fixture = Fixture(playing: playing, local: local)
        defer {
            fixture.window.contentView = nil
            fixture.player.effects.cancelAccountScoped()
        }
        let table = try await fixture.table()
        try #require(table.canSelectRow?(1) == true, "The current track is a selectable row, not a section heading")
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        #expect(table.selectedRowIndexes == IndexSet(integer: 1))
        #expect(fixture.selection == ["current"])
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0, "Selection cannot play")

        table.keyDown(with: try key(code: 36, characters: "\r"))
        try await requireEventually { local ? fixture.engine.executeCount == 1 : fixture.remote.sendCount == 1 }
        if local {
            switch try #require(fixture.engine.operations.first) {
            case .pause:
                #expect(playing)
            case let .resumeObserved(target):
                #expect(!playing)
                #expect(target.trackURI == "spotify:track:current")
                #expect(target.contextURI == "spotify:playlist:mix")
                #expect(target.positionMS == 42_000)
            default:
                Issue.record("Return on the current row must pause or resume, never load it again")
            }
            #expect(fixture.remote.sendCount == 0)
        } else {
            #expect(fixture.engine.operations.isEmpty)
            #expect(fixture.remote.endpoints == [playing ? .pause : .resume])
        }
        #expect(fixture.player.trackURI == "spotify:track:current" && fixture.player.position == 42)
        await fixture.player.shutdownForTermination()
    }

    @Test func currentAndMixedSelectionsCannotRemoveOrAccidentallyStartUpcomingTracks() async throws {
        let fixture = Fixture(playing: false, local: false)
        defer {
            fixture.window.contentView = nil
            fixture.player.effects.cancelAccountScoped()
        }
        let entries = (0..<2).map {
            QueueEntry(uri: "spotify:track:current", provider: "queue", occurrence: $0, uid: "next-\($0)")
        }
        try await fixture.installUpcoming(entries)
        let actions = SidePanelPlaybackActions(player: fixture.player)
        try #require(actions.canRemoveUpcomingQueue(selectedIDs: [entries[0].id]), "The upcoming queue is editable")
        let current = SidePanelPlaybackActions.currentRowID
        let before = fixture.player.state
        for ids: Set<String> in [[], [current, entries[0].id], Set(entries.map(\.id)), ["stale"]] {
            actions.activateQueueSelection(ids)
        }
        for ids: Set<String> in [[current], [current, entries[0].id]] {
            #expect(!actions.canRemoveUpcomingQueue(selectedIDs: ids))
            #expect(!actions.removeUpcomingQueue(selectedIDs: ids))
        }
        #expect(fixture.player.state == before)
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0)

        // An upcoming occurrence of the very same URI still means an explicit start, not Resume.
        actions.activateQueueSelection([entries[1].id])
        try await requireEventually { fixture.remote.sendCount == 1 }
        #expect(fixture.remote.endpoints == [.play])
        #expect(fixture.remote.commands.first?.context?.uri == entries[1].uri)
        #expect(fixture.player.queueNextEntries.map(\.id) == entries.map(\.id))
        await fixture.player.shutdownForTermination()
    }

    private func key(code: UInt16, characters: String) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
    }

    @MainActor
    private final class Fixture {
        let engine = HarnessEngine(position: 42_000)
        let remote = HarnessRemote(send: .park)
        let player: PlaybackStore
        var selection: Set<QueueEntry.ID> = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        var host: NSHostingView<SidePanelView>!

        init(playing: Bool, local: Bool) {
            player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
            player.withRuntime {
                let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local)
                let timing = PlaybackTiming(position: 42, duration: 200, anchoredAt: HarnessDates.fixed)
                _ = $0.send(.session(.ready), source: .account)
                _ = $0.send(
                    .devices(PlaybackDeviceSnapshot(devices: [device], localDeviceID: "mac", revision: 1)),
                    source: .engineDevices, revision: 1)
                _ = $0.send(
                    .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: playing ? .playing : .paused, trackURI: "spotify:track:current", timing: timing,
                            contextURI: "spotify:playlist:mix", isActiveDevice: local)),
                    source: .enginePlayback, revision: 1)
                _ = $0.send(
                    .presentation(
                        PlaybackPresentationSnapshot(
                            currentTrack: CurrentTrack(
                                uri: "spotify:track:current", title: "Current", artist: "Artist", duration: 200,
                                metadataSource: .catalog),
                            transport: playing ? .playing : .paused, timing: timing)), source: .user)
                _ = $0.send(
                    .owner(
                        local
                            ? .local(device) : .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
                    source: .engineConnection)
            }
            host = NSHostingView(
                rootView: SidePanelView(
                    metadata: player.catalog.metadata, player: player, panel: .queue,
                    selection: Binding(get: { [unowned self] in selection }, set: { [unowned self] in selection = $0 }),
                    onSelect: { _ in }, onClose: {}))
            window.contentView = host
        }

        func table() async throws -> NativeTrackTableView {
            func list(in view: NSView) -> NativeOccurrenceScrollView? {
                if let list = view as? NativeOccurrenceScrollView { return list }
                return view.subviews.lazy.compactMap { list(in: $0) }.first
            }
            try await requireEventually {
                self.host.layoutSubtreeIfNeeded()
                return list(in: self.host)?.table.numberOfRows == 2
            }
            return try #require(list(in: host)).table
        }

        func installUpcoming(_ entries: [QueueEntry]) async throws {
            await player.queueService.reset(accountEpoch: player.accountEpoch)
            let accepted = try #require(
                await player.queueService.acceptConnect(
                    entries, accountEpoch: player.accountEpoch, sourceRevision: 2,
                    contextURI: player.trackURI, engineEpoch: player.engineGeneration,
                    protocolNext: entries.map { QueueProtocolTrack(uri: $0.uri, uid: $0.uid, provider: "queue") },
                    protocolPrev: [], queueRevision: "fixture-queue"))
            player.queueMutation = accepted.mutation
            _ = player.send(
                .queue(
                    PlaybackQueueSnapshot(
                        entries: entries.map { PlaybackQueueItem($0) }, source: .connect, completeness: .complete,
                        revision: 2, receivedAt: HarnessDates.fixed, contextURI: player.trackURI)),
                source: .engineQueue, revision: 2, engineEpoch: player.engineGeneration,
                accountEpoch: player.accountEpoch)
        }
    }
}

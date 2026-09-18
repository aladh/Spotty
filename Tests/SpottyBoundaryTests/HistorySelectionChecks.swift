import AppKit
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Native listening history selection")
@MainActor
struct HistorySelectionChecks {
    @Test(arguments: [false, true])
    func arrowsSelectWithoutPlaybackAndReturnStartsTheSelectedHistoryTrack(local: Bool) async throws {
        let fixture = Fixture(local: local)
        defer { fixture.tearDown() }
        let table = try await fixture.table()
        let first = try #require(fixture.player.history.first)
        #expect(table.canSelectRow?(0) == true)
        #expect(!table.allowsMultipleSelection)
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.selection == [first.id])
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0)

        let history = fixture.player.history
        table.keyDown(with: try key(code: 51, characters: "\u{7F}"))
        #expect(fixture.player.history == history, "history selection is never queue removal")
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0)

        table.keyDown(with: try key(code: 36, characters: "\r"))
        try await requireEventually { local ? fixture.engine.executeCount == 1 : fixture.remote.sendCount == 1 }
        if local {
            switch try #require(fixture.engine.operations.first) {
            case let .playURI(uri): #expect(uri == first.uri)
            default: Issue.record("Playing history starts the selected track, including a replay of the current URI")
            }
            #expect(fixture.remote.sendCount == 0)
        } else {
            #expect(fixture.remote.endpoints == [.play])
            #expect(fixture.remote.commands.first?.context?.uri == first.uri)
            #expect(fixture.engine.operations.isEmpty)
        }
        await fixture.player.shutdownForTermination()
    }

    @Test func selectionFollowsHistoryReorderingAndSurvivesInspectorRecreation() async throws {
        let fixture = Fixture(local: false)
        defer { fixture.tearDown() }
        let table = try await fixture.table()
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        #expect(fixture.selection == [Fixture.currentURI])
        fixture.player.withRuntime {
            $0.history.applyMetadata(uri: Fixture.currentURI, title: "Updated", artist: "Artist", artworkURL: nil)
            $0.history.notePlayed(
                uri: Fixture.otherURI, title: "Other", artist: "Artist", artworkURL: nil,
                playedAt: HarnessDates.fixed.addingTimeInterval(1))
        }
        fixture.refresh()
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 1) }
        #expect(fixture.selection == [Fixture.currentURI])
        #expect(fixture.player.history[1].title == "Updated")
        #expect(try await fixture.table() === table)

        fixture.recreateInspector()
        let replacement = try await fixture.table()
        #expect(replacement !== table)
        #expect(replacement.selectedRowIndexes == IndexSet(integer: 1))
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0)
        await fixture.player.shutdownForTermination()
    }

    @Test func retainedHistoryActionsRejectRemovedUnavailableAndReplacementAccountEntries() async {
        let fixture = Fixture(local: false)
        defer { fixture.tearDown() }
        let actions = SidePanelPlaybackActions(player: fixture.player)
        let beforeInvalid = fixture.player.state
        for ids: Set<String> in [[], ["stale"], ["current"], [Fixture.currentURI, Fixture.otherURI]] {
            actions.activateHistorySelection(ids)
        }
        #expect(fixture.player.state == beforeInvalid)

        fixture.player.withRuntime { $0.history.reset() }
        let beforeRemoved = fixture.player.state
        actions.activateHistorySelection([Fixture.currentURI])
        #expect(fixture.player.state == beforeRemoved)

        fixture.player.withRuntime {
            Fixture.seedHistory($0)
            _ = $0.send(.session(.failed("offline")), source: .account)
        }
        #expect(!actions.canStartPlayback)
        let beforeUnavailable = fixture.player.state
        actions.activateHistorySelection([Fixture.currentURI])
        #expect(fixture.player.state == beforeUnavailable)

        fixture.player.withRuntime {
            $0.accountStore.advanceEpoch()
            _ = $0.send(.reset(session: .ready), source: .account)
            Fixture.seedReady($0, local: false)
            Fixture.seedHistory($0)
        }
        #expect(SidePanelPlaybackActions(player: fixture.player).canStartPlayback)
        let replacement = fixture.player.state
        actions.activateHistorySelection([Fixture.currentURI])
        #expect(fixture.player.state == replacement)
        #expect(fixture.engine.operations.isEmpty && fixture.remote.sendCount == 0)
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
        nonisolated static let currentURI = "spotify:track:current"
        nonisolated static let otherURI = "spotify:track:other"
        let engine = HarnessEngine(position: 42_000)
        let remote = HarnessRemote(send: .park)
        let player: PlaybackStore
        var selection: Set<HistoryEntry.ID> = []
        let scrollState = NativeListScrollState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: false)
        var host: NSHostingView<HistoryListView>!

        init(local: Bool) {
            player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, remote: remote))
            player.withRuntime {
                Self.seedReady($0, local: local)
                Self.seedHistory($0)
            }
            recreateInspector()
        }

        private func content() -> HistoryListView {
            HistoryListView(
                entries: player.history, actions: SidePanelPlaybackActions(player: player),
                selection: Binding(get: { [unowned self] in selection }, set: { [unowned self] in selection = $0 }),
                scrollState: scrollState)
        }

        func refresh() { host.rootView = content() }

        func recreateInspector() {
            window.contentView = nil
            host = NSHostingView(rootView: content())
            window.contentView = host
        }

        func table() async throws -> NativeTrackTableView {
            func list(in view: NSView) -> NativeOccurrenceScrollView? {
                if let list = view as? NativeOccurrenceScrollView { return list }
                return view.subviews.lazy.compactMap { list(in: $0) }.first
            }
            try await requireEventually {
                self.host.layoutSubtreeIfNeeded()
                return list(in: self.host)?.table.numberOfRows == self.player.history.count
            }
            return try #require(list(in: host)).table
        }

        func tearDown() {
            window.contentView = nil
            player.effects.cancelAccountScoped()
        }

        @SessionRuntimeActor
        static func seedHistory(_ runtime: PlaybackSessionRuntime) {
            for uri in [otherURI, currentURI] {
                runtime.history.notePlayed(
                    uri: uri, title: uri == currentURI ? "Current" : "Other", artist: "Artist", artworkURL: nil,
                    playedAt: HarnessDates.fixed)
            }
        }

        @SessionRuntimeActor
        static func seedReady(_ runtime: PlaybackSessionRuntime, local: Bool) {
            let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: local)
            let timing = PlaybackTiming(position: 42, duration: 200, anchoredAt: HarnessDates.fixed)
            _ = runtime.send(.session(.ready), source: .account)
            _ = runtime.send(
                .devices(PlaybackDeviceSnapshot(devices: [device], localDeviceID: "mac", revision: 1)),
                source: .engineDevices, revision: 1)
            _ = runtime.send(
                .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused, trackURI: currentURI, timing: timing,
                        contextURI: "spotify:playlist:mix", isActiveDevice: local)),
                source: .enginePlayback, revision: 1)
            _ = runtime.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: currentURI, title: "Current", artist: "Artist", duration: 200, metadataSource: .catalog
                        ),
                        transport: .paused, timing: timing)), source: .user)
            _ = runtime.send(
                .owner(
                    local ? .local(device) : .remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker"))),
                source: .engineConnection)
        }
    }
}

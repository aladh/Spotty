import AppKit
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Home scroll lifetime")
@MainActor
struct HomeScrollChecks {
    @Test func shelfPositionSurvivesTemporaryQuickAccessPresentation() async throws {
        func snapshot(_ ids: [Int]) throws -> PathfinderHome {
            let sections = ids.map { index in
                let items = (0..<6).map { item in
                    """
                    {"content":{"__typename":"PlaylistResponseWrapper","data":{
                      "uri":"spotify:playlist:mix\(index)-\(item)","name":"Mix"}}}
                    """
                }.joined(separator: ",")
                return "{\"uri\":\"section:\(index)\",\"sectionItems\":{\"items\":[\(items)]}}"
            }.joined(separator: ",")
            return try JSONDecoder().decode(
                PathfinderHome.self,
                from: Data(
                    "{\"__typename\":\"HomeResponsePayload\",\"sectionContainer\":{\"sections\":{\"items\":[\(sections)]}}}"
                        .utf8))
        }
        let original = try snapshot([0, 1, 2])
        let promoted = try snapshot([1, 2])
        let provider = HarnessCatalog()
        provider.onHome = { original }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        let interaction = HomeInteractionState()
        var firstSection: String?
        func content() -> some View {
            HomeView(
                store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                interaction: interaction, onSelect: { _ in }
            )
            .onChange(of: player.catalog.homeLibrary.homeSections.first?.id, initial: true) { _, first in
                firstSection = first
            }
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func shelf(in view: NSView) -> NativeHorizontalScrollView? {
            if let shelf = view as? NativeHorizontalScrollView { return shelf }
            return view.subviews.lazy.compactMap { shelf(in: $0) }.first
        }
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return firstSection == "section:0" && (shelf(in: host)?.hostedSize.width ?? 0) > 900
        }
        let id = HomeInteractionState.SectionID(source: "section:1", ordinal: 0)
        let retained = interaction.shelfScroll(for: id)
        try #require(shelf(in: host)).contentView.scroll(to: NSPoint(x: 100, y: 0))
        #expect(retained.offset == 100)
        provider.onHome = { promoted }
        await player.catalog.homeLibrary.loadHome(force: true)
        host.rootView = content()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return firstSection == "section:1"
        }
        #expect(interaction.shelfScroll(for: id) === retained)
        #expect(interaction.shelfScroll(for: id).offset == 100)
        provider.onHome = { original }
        await player.catalog.homeLibrary.loadHome(force: true)
        host.rootView = content()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return firstSection == "section:0" && shelf(in: host)?.contentView.bounds.minX == 100
        }
        #expect(interaction.shelfScroll(for: id) === retained)
        await player.shutdownForTermination()
    }

    @Test(arguments: [CGFloat(320), 2200])
    func reconnectPlaceholdersDoNotReplaceTheRetainedPagePosition(offset: CGFloat) async throws {
        let sections = (0..<12).map { index in
            """
            {"uri":"section:\(index)","sectionItems":{"items":[
              {"content":{"__typename":"PlaylistResponseWrapper","data":{
                "uri":"spotify:playlist:mix\(index)","name":"Mix \(index)"}}}]}}
            """
        }.joined(separator: ",")
        let home = try JSONDecoder().decode(
            PathfinderHome.self,
            from: Data(
                "{\"__typename\":\"HomeResponsePayload\",\"sectionContainer\":{\"sections\":{\"items\":[\(sections)]}}}"
                    .utf8))
        let provider = HarnessCatalog()
        provider.onHome = { home }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        let interaction = HomeInteractionState()
        interaction.scrollOffset = offset
        player.withRuntime {
            $0.accountStore.publishPhase(.recovering)
            _ = $0.send(.session(.recovering), source: .account)
        }
        var appeared = false
        var observedPhase = player.phase
        func content() -> some View {
            HomeView(
                store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                interaction: interaction, onSelect: { _ in }
            )
            .onAppear { appeared = true }
            .onChange(of: player.phase) { _, phase in observedPhase = phase }
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func page(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { page(in: $0) }.first
        }
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return appeared && page(in: host)?.contentSize.height == 600
        }
        #expect(interaction.scrollOffset == offset)
        for _ in 0..<2 {
            player.withRuntime {
                $0.accountStore.publishPhase(.ready)
                _ = $0.send(.session(.ready), source: .account)
            }
            host.rootView = content()
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedPhase == .ready && abs((page(in: host)?.contentView.bounds.minY ?? 0) - offset) < 1
            }
            #expect(interaction.scrollOffset == offset)
            player.withRuntime {
                $0.accountStore.publishPhase(.recovering)
                _ = $0.send(.session(.recovering), source: .account)
            }
            host.rootView = content()
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedPhase == .recovering && page(in: host)?.contentView.bounds.minY == 0
            }
            #expect(interaction.scrollOffset == offset)
        }
        await player.shutdownForTermination()
    }
}

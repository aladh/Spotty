import AppKit
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Home scroll lifetime")
@MainActor
struct HomeScrollChecks {
    @Test func reconnectPlaceholdersDoNotReplaceTheRetainedPagePosition() async throws {
        let sections = (0..<5).map { index in
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
        interaction.scrollOffset = 320
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
        #expect(interaction.scrollOffset == 320)
        for _ in 0..<2 {
            player.withRuntime {
                $0.accountStore.publishPhase(.ready)
                _ = $0.send(.session(.ready), source: .account)
            }
            host.rootView = content()
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedPhase == .ready && abs((page(in: host)?.contentView.bounds.minY ?? 0) - 320) < 1
            }
            #expect(interaction.scrollOffset == 320)
            player.withRuntime {
                $0.accountStore.publishPhase(.recovering)
                _ = $0.send(.session(.recovering), source: .account)
            }
            host.rootView = content()
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedPhase == .recovering && page(in: host)?.contentView.bounds.minY == 0
            }
            #expect(interaction.scrollOffset == 320)
        }
        await player.shutdownForTermination()
    }
}

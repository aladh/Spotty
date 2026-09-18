import AppKit
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Sidebar width continuity")
@MainActor
struct SidebarWidthChecks {
    @Test func changingContentKeepsTheLibraryWidthInANarrowWindow() async throws {
        let items = (0..<8).map { index in
            """
            {"content":{"__typename":"PlaylistResponseWrapper","data":{
              "uri":"spotify:playlist:mix\(index)","name":"Mix \(index)"}}}
            """
        }.joined(separator: ",")
        let home = try JSONDecoder().decode(
            PathfinderHome.self,
            from: Data(
                """
                {"__typename":"HomeResponsePayload","sectionContainer":{"sections":{"items":[
                  {"uri":"section:quick","sectionItems":{"items":[\(items)]}}]}}}
                """.utf8))
        let provider = HarnessCatalog()
        provider.onHome = { home }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        let navigation = CatalogNavigation()
        var observedPhase = player.phase
        var observedSelection = navigation.selection
        var appeared = false
        func content() -> some View {
            RootView(
                player: player, catalog: player.catalog, feedback: player.feedback, navigation: navigation
            )
            .frame(minWidth: 960, minHeight: 640)
            .onAppear { appeared = true }
            .onChange(of: player.phase) { _, phase in observedPhase = phase }
            .onChange(of: navigation.selection) { _, selection in observedSelection = selection }
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1728, height: 900), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func sidebar(in view: NSView) -> NativeOccurrenceScrollView? {
            if let scroll = view as? NativeOccurrenceScrollView { return scroll }
            return view.subviews.lazy.compactMap { sidebar(in: $0) }.first
        }
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return appeared && (sidebar(in: host)?.bounds.width ?? 0) > 0
        }
        window.setContentSize(NSSize(width: 960, height: 900))
        host.layoutSubtreeIfNeeded()
        let library = try #require(sidebar(in: host))
        let width = library.bounds.width
        try #require((180...260).contains(width))
        func expectRetainedSidebar() throws {
            let current = try #require(sidebar(in: host))
            #expect(current === library)
            #expect(abs(current.bounds.width - width) < 1)
        }
        player.withRuntime {
            $0.accountStore.publishPhase(.failed("Offline"))
            _ = $0.send(.session(.failed("Offline")), source: .account)
        }
        host.rootView = content()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return observedPhase == .failed("Offline")
        }
        try expectRetainedSidebar()
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        host.rootView = content()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return observedPhase == .ready
        }
        try expectRetainedSidebar()
        for destination in [SidebarDestination.search, .home] {
            navigation.updateSelection(.destination(destination))
            host.rootView = content()
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedSelection == .destination(destination)
            }
            try expectRetainedSidebar()
        }
        await player.shutdownForTermination()
    }
}

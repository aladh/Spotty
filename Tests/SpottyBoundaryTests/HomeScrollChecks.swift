@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import AppKit
import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Home scroll lifetime")
@MainActor
struct HomeScrollChecks {
    @Test func artworkAdmissionFollowsTheViewportWithoutRetiringOffscreenControls() async throws {
        let provider = HarnessCatalog()
        provider.onHome = {
            CatalogHomeSnapshot(
                greeting: "Synthetic",
                sections: (0..<12).map { section in
                    CatalogSection(
                        id: "section:\(section)", title: "Synthetic",
                        items: [
                            CatalogItem(
                                id: "item:\(section)", uri: "spotify:album:\(section)", title: "Synthetic",
                                subtitle: "",
                                artworkURL: URL(string: "https://synthetic.invalid/\(section)"), kind: .album)
                        ])
                })
        }
        let artwork = HarnessArtwork(immediateFailure: .unavailable)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        do {
            let host = NSHostingView(
                rootView: HomeView(
                    store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                    interaction: HomeInteractionState(), onSelect: { _ in }
                )
                .environment(\.artworkAccess, ArtworkAccess(provider: artwork, accountEpoch: 1)))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            func page(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { page(in: $0) }.first
            }
            func shelves(in view: NSView) -> [NativeHorizontalScrollView] {
                if let shelf = view as? NativeHorizontalScrollView { return [shelf] }
                return view.subviews.flatMap { shelves(in: $0) }
            }
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return await artwork.requests.contains { $0.url.path == "/1" }
            }
            #expect(await artwork.requests.contains { $0.url.path == "/11" } == false)
            let retainedShelves = shelves(in: host)
            #expect(retainedShelves.count == 11, "offscreen semantic/focus controls remain instantiated")
            let scroll = try #require(page(in: host))
            let maximum = try #require(scroll.documentView).bounds.height - scroll.contentSize.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return await artwork.requests.contains { $0.url.path == "/11" }
            }
            #expect(abs(scroll.contentView.bounds.minY - maximum) < 1)
            #expect(shelves(in: host).elementsEqual(retainedShelves, by: { $0 === $1 }))
        } catch {
            await player.shutdownForTermination()
            throw error
        }
        await player.shutdownForTermination()
    }

    @Test func refreshesPreserveTheClampedScrollPositionThroughFailureAndRecovery() async throws {
        let shorter = HarnessFixtures.home(sectionIDs: Array(0..<3))
        let longer = HarnessFixtures.home(sectionIDs: Array(0..<12))
        let provider = HarnessCatalog()
        provider.onHome = { shorter }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        let interaction = HomeInteractionState()
        interaction.scrollOffset = 2200
        let host = NSHostingView(
            rootView: HomeView(
                store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                interaction: interaction, onSelect: { _ in }))
        // The app's viewport is window-owned; a status notice must not resize the test window.
        host.sizingOptions = []
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
            guard let scroll = page(in: host), let document = scroll.documentView else { return false }
            let maximum = document.bounds.height - scroll.contentSize.height
            // Layout and SwiftUI's geometry publication need not arrive in the same turn.
            return maximum > 100 && maximum < 2200
                && abs(scroll.contentView.bounds.minY - maximum) < 1
                && abs(interaction.scrollOffset - maximum) < 1
        }
        let scroll = try #require(page(in: host))
        let maximum = try #require(scroll.documentView).bounds.height - scroll.contentSize.height
        #expect(abs(interaction.scrollOffset - maximum) < 1)
        let clampedOffset = interaction.scrollOffset
        // Home publishes complete snapshots. Later sections are a new result, not partially
        // rendered artwork; the old unreachable offset must not reapply when that result grows.
        provider.onHome = { longer }
        await player.catalog.homeLibrary.loadHome(force: true)
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return (scroll.documentView?.bounds.height ?? 0) > 2500
        }
        #expect(abs(scroll.contentView.bounds.minY - clampedOffset) < 1)
        #expect(interaction.scrollOffset == clampedOffset)
        let contentHeight = scroll.bounds.height
        provider.onHome = { throw HarnessFailure.unavailable }
        await player.catalog.homeLibrary.loadHome(force: true)
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return scroll.bounds.height < contentHeight
        }
        #expect(page(in: host) === scroll, "the refresh notice must not replace the retained scrolling surface")
        #expect(abs(scroll.contentView.bounds.minY - clampedOffset) < 1)
        #expect(player.catalog.homeLibrary.homeSections.count == 12)
        provider.onHome = { longer }
        await player.catalog.homeLibrary.loadHome(force: true)
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return scroll.bounds.height == contentHeight
        }
        #expect(page(in: host) === scroll)
        #expect(abs(scroll.contentView.bounds.minY - clampedOffset) < 1)
        await player.shutdownForTermination()
    }

    @Test func shelfPositionSurvivesTemporaryQuickAccessPresentation() async throws {
        let original = HarnessFixtures.home(sectionIDs: [0, 1, 2], itemsPerSection: 6)
        let promoted = HarnessFixtures.home(sectionIDs: [1, 2], itemsPerSection: 6)
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

    @Test(arguments: [CGFloat(320), 2200], [NSScroller.Style.overlay, .legacy])
    func reconnectPlaceholdersDoNotReplaceTheRetainedPagePosition(offset: CGFloat, style: NSScroller.Style) async throws
    {
        let home = HarnessFixtures.home(sectionIDs: Array(0..<12))
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
        // The app's viewport is window-owned; reconnecting content must not resize the test window.
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func page(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { page(in: $0) }.first
        }
        func layout() {
            page(in: host)?.scrollerStyle = style
            host.layoutSubtreeIfNeeded()
            page(in: host)?.scrollerStyle = style
        }
        try await requireEventually {
            layout()
            return appeared && page(in: host)?.contentSize.height == 600
        }
        #expect(host.bounds.size == NSSize(width: 900, height: 600))
        #expect(page(in: host)?.bounds.width == 900)
        #expect(page(in: host)?.contentSize.height == 600)
        #expect(interaction.scrollOffset == offset)
        for iteration in 0..<2 {
            player.withRuntime {
                $0.accountStore.publishPhase(.ready)
                _ = $0.send(.session(.ready), source: .account)
            }
            host.rootView = content()
            do {
                try await requireEventually {
                    layout()
                    return observedPhase == .ready && abs((page(in: host)?.contentView.bounds.minY ?? 0) - offset) < 1
                }
            } catch {
                let scroll = page(in: host)
                Issue.record(
                    "Home restoration scrollerStyle=\(style.rawValue), iteration=\(iteration), requested=\(offset), observedReady=\(observedPhase == .ready), playerReady=\(player.phase == .ready), connected=\(player.isConnected), retainedOffset=\(interaction.scrollOffset), clipOffset=\(scroll?.contentView.bounds.minY ?? -1), documentHeight=\(scroll?.documentView?.bounds.height ?? -1), viewportHeight=\(scroll?.contentSize.height ?? -1), hostHeight=\(host.frame.height), windowContentHeight=\(window.contentLayoutRect.height)"
                )
                throw error
            }
            #expect(host.bounds.size == NSSize(width: 900, height: 600))
            #expect(page(in: host)?.bounds.width == 900)
            #expect(page(in: host)?.contentSize.height == 600)
            #expect(interaction.scrollOffset == offset)
            player.withRuntime {
                $0.accountStore.publishPhase(.recovering)
                _ = $0.send(.session(.recovering), source: .account)
            }
            host.rootView = content()
            try await requireEventually {
                layout()
                return observedPhase == .recovering && page(in: host)?.contentView.bounds.minY == 0
            }
            #expect(host.bounds.size == NSSize(width: 900, height: 600))
            #expect(page(in: host)?.bounds.width == 900)
            #expect(page(in: host)?.contentSize.height == 600)
            #expect(interaction.scrollOffset == offset)
        }
        await player.shutdownForTermination()
    }
}

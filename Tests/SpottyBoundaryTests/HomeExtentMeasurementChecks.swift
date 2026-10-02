import AppKit
import Darwin
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

/// An opt-in native layout/admission probe. No visible window, network, live engine or account.
/// Layout readiness measures the attached host, not a presented first frame.
@MainActor
struct HomeExtentMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_HOME_EXTENT_REPORT"] != nil))
    func measureEagerHomeExtent() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["SPOTTY_HOME_EXTENT_REPORT"])
        let sections = try #require(Int(environment["SPOTTY_HOME_EXTENT_SECTIONS"] ?? "120"))
        let mode = environment["SPOTTY_HOME_EXTENT_MODE"] ?? "eager"
        try #require(["eager", "viewport"].contains(mode))
        try #require([12, 120, 500].contains(sections))
        try #require(!FileManager.default.fileExists(atPath: path))
        let snapshot = CatalogHomeSnapshot(
            greeting: "Synthetic Home",
            sections: (0..<sections).map { section in
                CatalogSection(
                    id: "section:\(section)", title: "Synthetic shelf \(section)",
                    items: (0..<8).map { item in
                        let id = "\(section)-\(item)"
                        return CatalogItem(
                            id: id, uri: "spotify:album:\(id)", title: "Synthetic album", subtitle: "Synthetic artist",
                            artworkURL: URL(string: "https://synthetic.invalid/\(section)/\(item)"), kind: .album)
                    })
            })
        let provider = HarnessCatalog()
        provider.onHome = { snapshot }
        let artwork = HarnessArtwork(immediateFailure: .unavailable)
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.homeLibrary.loadHome()
        do {
            let before = try memory()
            let start = ContinuousClock.now
            let interaction = HomeInteractionState()
            let host = NSHostingView(
                rootView: HomeView(
                    store: player.catalog.homeLibrary, playback: CatalogPlaybackAccess(player: player),
                    interaction: interaction, onSelect: { _ in }
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
            try await requireEventually(description: "Large Home complete native extent") {
                host.layoutSubtreeIfNeeded()
                return (page(in: host)?.documentView?.bounds.height ?? 0) > CGFloat(sections * 200)
            }
            let layout = start.duration(to: .now)
            let admittedSection = mode == "eager" ? sections - 1 : 1
            try await requireEventually(description: "Home admits artwork at the declared measurement barrier") {
                await artwork.requests.contains { $0.url.path == "/\(admittedSection)/0" }
            }
            let requests = await artwork.requests
            let report: [String: Any] = [
                "sections": sections, "itemsPerSection": 8, "viewportWidth": 900, "viewportHeight": 600,
                "admissionBarrierSection": admittedSection, "mode": mode,
                "layoutReadinessSeconds": Double(layout.components.seconds) + Double(layout.components.attoseconds)
                    / 1e18,
                "documentHeight": page(in: host)?.documentView?.bounds.height ?? 0,
                "artworkAdmissions": requests.count,
                "admittedShelves": Set(requests.compactMap { $0.url.pathComponents.dropFirst().first }).count,
                "before": before, "attached": try memory(),
                "limitations":
                    "Unpresented native host; initial layout and admission only, not first usable frame. Artwork immediately returns synthetic unavailability, excluding network/decode/raster costs. No whole-app or live-account performance claim.",
            ]
            window.contentView = nil
            await player.shutdownForTermination()
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        } catch {
            await player.shutdownForTermination()
            throw error
        }
    }

    private func memory() throws -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(status == KERN_SUCCESS)
        return ["residentBytes": info.resident_size, "physicalFootprintBytes": info.phys_footprint]
    }

}

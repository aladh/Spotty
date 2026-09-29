@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Darwin
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

/// Opt-in preparation CPU through the real detail store, including metadata publication when
/// switching retained routes. Loading, fixture construction and query settlement are untimed.
@MainActor
struct CatalogPreparationMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_CATALOG_PREPARATION_REPORT"] != nil))
    func measureRepeatedPreparation() async throws {
        let iterations = 100
        var reports: [[String: Any]] = []
        for (count, routes) in [(500, 1), (10_000, 2), (40_000, 1)] {
            let queries = HarnessCatalogQueries()
            let provider = HarnessCatalog()
            provider.entityQueries = queries
            let items = (0..<routes).map { index in
                CatalogItem(
                    id: "route-\(index)", uri: "spotify:playlist:route-\(index)", title: "Playlist \(index)",
                    subtitle: "", artworkURL: nil, kind: .playlist)
            }
            let tracks = Dictionary(
                uniqueKeysWithValues: items.map { item in
                    (
                        item.id,
                        (0..<count).map { index in
                            CatalogTrack(
                                id: "row-\(item.id)-\(index)", uri: "spotify:track:\(item.id)-\(index)",
                                title: "Track \(index)", artist: "Artist", album: "Album", duration: 180,
                                artworkURL: nil, addedAt: nil)
                        }
                    )
                })
            provider.onPlaylist = { id in
                CatalogPlaylistSnapshot(description: id, ownerURI: nil, tracks: tracks[id] ?? [])
            }
            let session = CatalogSessionAvailability(isAvailable: true)
            let store = PlaylistStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            defer { store.reset() }
            for item in items { await store.load(item) }
            let expectedCount = min(count * routes, CatalogEntityQueryLimits.maximumRequestedURIs)
            try await requireEventually { await queries.activeRequestedURIs.count == expectedCount }
            let subscriptions = await queries.subscriptionCount
            let last = try #require(items.last)
            for workload in routes == 1 ? ["same-selection"] : ["same-selection", "retained-switch"] {
                for sample in 0..<3 {
                    for _ in 0..<5 { store.prepare(last) }
                    let before = try cpuSeconds()
                    let started = ContinuousClock.now
                    for iteration in 0..<iterations {
                        store.prepare(workload == "same-selection" ? last : items[iteration % routes])
                    }
                    let elapsed = started.duration(to: .now).components
                    let cpu = try cpuSeconds() - before
                    reports.append([
                        "tracksPerRoute": count, "routes": routes, "workload": workload, "sample": sample,
                        "cpuSeconds": cpu,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                        "processPeakResidentBytes": try peakResidentBytes(),
                    ])
                    #expect(store.tracks.count == count)
                    #expect(store.item?.uri == last.uri)
                }
            }
            #expect(provider.playlistRequestCount == routes)
            #expect(await queries.subscriptionCount == subscriptions)
            store.reset()
            try await requireEventually { await queries.activeQueryCount == 0 }
        }
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 2, "iterations": iterations, "measurements": reports,
                "limits":
                    "Synthetic optimized preparation; process peak RSS includes all earlier fixtures and work. No rendering or live latency claim.",
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_CATALOG_PREPARATION_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func peakResidentBytes() throws -> Int {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return usage.ru_maxrss
    }
}

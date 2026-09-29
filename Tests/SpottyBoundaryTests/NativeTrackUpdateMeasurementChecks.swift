@testable import SpottyRuntimeTestSupport
import AppKit
import Darwin
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI
import Testing
@testable import SpottyCore

/// Isolated coordinator CPU, not a scrolling, frame-rate, or interactive rendering measurement.
@MainActor
struct NativeTrackUpdateMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_NATIVE_TRACK_UPDATE_REPORT"] != nil))
    func measureNativeTrackUpdates() throws {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let playback = CatalogPlaybackAccess(player: player)
        let samples = 3
        let iterations = 20
        var measurements: [[String: Any]] = []
        for count in [500, 5_000, 20_000] {
            let tracks = (0..<count).map { track($0) }
            let rows = TrackTableDisplayCache(CatalogTrackCollection(tracks: tracks)).rows
            var enrichedTracks = tracks
            enrichedTracks[count - 1] = track(count - 1, changed: true)
            let enriched = TrackTableDisplayCache(CatalogTrackCollection(tracks: enrichedTracks)).rows
            let equalCopy = TrackTableDisplayCache(CatalogTrackCollection(tracks: tracks)).rows
            let reordered = Array(rows.reversed())
            for workload in ["unchanged", "retained-selection", "equal-copy", "selection", "metadata", "reorder"] {
                let state = CatalogRouteInteractionState()
                if workload == "retained-selection" { state.selection = [rows[count - 1].id] }
                let container = NativeTrackTableContainer(variant: .playlist)
                container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
                func content(_ rows: [TrackTableRow]) -> NativeTrackTable {
                    NativeTrackTable(
                        rows: rows, variant: .playlist, playback: playback, searchQuery: "",
                        selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                        sortOrder: Binding(get: { state.sortOrder }, set: { state.sortOrder = $0 }),
                        scrollOffset: Binding(get: { state.scrollOffset }, set: { state.scrollOffset = $0 }),
                        playlistActions: nil, onSelect: nil, detailHeader: nil, compactDetailHeader: nil)
                }
                let coordinator = NativeTrackTable.Coordinator(content([]))
                coordinator.attach(to: container)
                defer { coordinator.detach(from: container) }
                coordinator.update(content(rows), in: container)
                for sample in -1..<samples {
                    let start = ContinuousClock.now
                    let cpuStart = try cpuSeconds()
                    for iteration in 0..<iterations {
                        autoreleasepool {
                            let alternate = iteration.isMultiple(of: 2)
                            let input: [TrackTableRow]
                            switch workload {
                            case "equal-copy": input = alternate ? rows : equalCopy
                            case "selection":
                                state.selection = [rows[alternate ? 0 : count - 1].id]
                                input = rows
                            case "metadata": input = alternate ? rows : enriched
                            case "reorder": input = alternate ? rows : reordered
                            default: input = rows
                            }
                            coordinator.update(content(input), in: container)
                        }
                    }
                    let cpu = try cpuSeconds() - cpuStart
                    let wall = start.duration(to: .now).components
                    #expect(container.table.numberOfRows == count)
                    if sample >= 0 {
                        measurements.append([
                            "rows": count, "workload": workload, "sample": sample, "cpuSeconds": cpu,
                            "wallSeconds": Double(wall.seconds) + Double(wall.attoseconds) / 1e18,
                        ])
                    }
                }
            }
        }
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "samples": samples, "iterations": iterations, "measurements": measurements,
                "environment": [
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "attachedWindow": false, "width": 900, "height": 400,
                    "renderingOrInputMetrics": "Not measured; offscreen AppKit coordinator CPU only",
                    "engineInvoked": false,
                ],
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_NATIVE_TRACK_UPDATE_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func track(_ index: Int, changed: Bool = false) -> CatalogTrack {
        CatalogTrack(
            id: "occurrence-\(index)", uri: "spotify:track:\(index)", title: changed ? "Updated" : "Track \(index)",
            artist: "Artist", album: "Album", duration: 180, artworkURL: nil, addedAt: nil)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

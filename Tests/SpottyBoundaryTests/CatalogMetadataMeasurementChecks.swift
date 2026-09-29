@testable import SpottyRuntimeTestSupport
import Darwin
import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

/// Opt-in optimized microbenchmark: isolates catalog work from network, rendering and startup.
/// The report has no timing threshold; compare repeated runs on the same host and configuration.
@MainActor
struct CatalogMetadataMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_ENTITY_OBSERVATION_REPORT"] != nil))
    func measureUnchangedEntitySubscriptions() throws {
        let iterations = 100
        var reports: [[String: Any]] = []
        for count in [500, 20_000, 40_000] {
            let provider = HarnessCatalog()
            provider.entityQueries = HarnessCatalogQueries()
            let session = CatalogSessionAvailability(isAvailable: true)
            let observation = CatalogEntityObservation(provider: provider, session: session)
            defer { observation.reset() }
            let collection = CatalogTrackCollection(
                tracks: (0..<count).map { HarnessFixtures.track(uri: "spotify:track:synthetic-\($0)") })
            observation.update(collections: [collection]) { _ in }
            // Copies preserve immutable collection versions, as active and retained routes do.
            let repeated = collection
            let started = ContinuousClock.now
            let before = try cpuSeconds()
            for _ in 0..<iterations { observation.update(collections: [repeated]) { _ in } }
            let cpu = try cpuSeconds() - before
            let elapsed = started.duration(to: .now).components
            reports.append([
                "requestedURIs": count, "cpuSeconds": cpu,
                "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            ])
        }
        let report = try JSONSerialization.data(
            withJSONObject: ["version": 2, "iterations": iterations, "measurements": reports],
            options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_ENTITY_OBSERVATION_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_CATALOG_MEASUREMENT_REPORT"] != nil))
    func measureLargeCatalogUpdates() throws {
        let trackCount = 10_000
        let iterations = 50
        let tracks = (0..<trackCount).map { index in
            CatalogTrack(
                id: "row-\(index)", uri: "spotify:track:synthetic-\(index)", title: "Track \(index)",
                artist: "Artist \(index % 100)", album: "Album \(index % 500)", duration: 180,
                artworkURL: nil, addedAt: nil)
        }
        var changed = tracks
        let first = tracks[0]
        changed[0] = CatalogTrack(
            id: first.id, uri: first.uri, title: "Changed title", artist: first.artist, album: first.album,
            duration: first.duration, artworkURL: nil, addedAt: nil)
        var reports: [[String: Any]] = []
        for workload in ["unchanged-library", "one-track-change", "playback-publication"] {
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let metadata = CatalogMetadataRepository(session: session)
            metadata.replaceTracks(tracks, from: .library)
            let playback = Array(tracks.prefix(100))
            metadata.replaceTracks(playback, from: .playback)
            let started = ContinuousClock.now
            let before = try cpuSeconds()
            for iteration in 0..<iterations {
                switch workload {
                case "unchanged-library": metadata.replaceTracks(tracks, from: .library)
                case "one-track-change":
                    metadata.replaceTracks(iteration.isMultiple(of: 2) ? changed : tracks, from: .library)
                default: metadata.replaceTracks(playback, from: .playback)
                }
            }
            let cpu = try cpuSeconds() - before
            let elapsed = started.duration(to: .now).components
            reports.append([
                "workload": workload, "cpuSeconds": cpu,
                "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            ])
            #expect(metadata.browsingMetadata.tracks.count == trackCount)
            #expect(
                metadata.knownTrack(for: first.uri)
                    == CatalogTrackMetadata(track: first, requestedURI: first.uri).playbackTrack)
        }
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "trackCount": trackCount, "iterations": iterations,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "measurements": reports,
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_CATALOG_MEASUREMENT_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

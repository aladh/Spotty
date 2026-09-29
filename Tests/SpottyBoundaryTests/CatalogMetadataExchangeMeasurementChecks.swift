@testable import SpottyRuntimeTestSupport
import Darwin
import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

/// Includes the real desktop admission path: source replacement, export, runtime ingestion and
/// bounded playback publication. Run optimized, without other build or measurement processes.
@MainActor
struct CatalogMetadataExchangeMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_METADATA_EXCHANGE_REPORT"] != nil))
    func measureCompleteMetadataExchange() async throws {
        let iterations = 30
        var reports: [[String: Any]] = []
        for count in [500, 10_000, 20_000] {
            let original = (0..<count).map { track($0) }
            for workload in ["unchanged", "occurrence-only", "one-label", "all-labels", "retained-labels"] {
                let replacement = (0..<count).map { index in
                    track(
                        index, occurrence: workload == "occurrence-only" ? 1 : 0,
                        changed: workload == "all-labels" || workload == "one-label" && index == count - 1
                            || workload == "retained-labels" && index < 100)
                }
                let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
                player.withRuntime { $0.accountStore.publishPhase(.ready) }
                await player.catalogLoadTask?.value
                player.catalog.metadata.replaceTracks(original, from: .library)
                player.withRuntime { runtime in
                    runtime.catalogMetadata.retainTracks(from: .queue, for: Set(original.prefix(100).map(\.uri)))
                }
                var sourceCPU = 0.0
                var exchangeCPU = 0.0
                var admissions: [Double] = []
                for iteration in 0..<iterations {
                    let values = iteration.isMultiple(of: 2) ? replacement : original
                    let beforeSource = try cpuSeconds()
                    player.catalog.metadata.replaceTracks(values, from: .library)
                    sourceCPU += try cpuSeconds() - beforeSource
                    let beforeExchange = try cpuSeconds()
                    let started = ContinuousClock.now
                    player.withRuntime { _ in }
                    let elapsed = started.duration(to: .now).components
                    admissions.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    exchangeCPU += try cpuSeconds() - beforeExchange
                }
                let title = player.withRuntime { $0.catalogMetadata.knownTrack(for: original[count - 1].uri)?.title }
                #expect(title == original[count - 1].title)
                let labelCount = player.withRuntime { $0.catalogMetadata.playbackTracks.count }
                #expect(labelCount == 100)
                admissions.sort()
                reports.append([
                    "trackCount": count, "workload": workload, "sourceCPUSeconds": sourceCPU,
                    "exchangeCPUSeconds": exchangeCPU,
                    "admissionMedianSeconds": admissions[iterations / 2],
                    "admissionP95Seconds": admissions[Int(Double(iterations - 1) * 0.95)],
                ])
                await player.shutdownForTermination()
            }
        }
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "iterations": iterations, "retainedTracks": 100,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "measurements": reports,
                "limits":
                    "Synthetic optimized CPU and admission samples; no allocation, energy or live playback claim.",
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_METADATA_EXCHANGE_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func track(_ index: Int, occurrence: Int = 0, changed: Bool = false) -> CatalogTrack {
        CatalogTrack(
            id: "row-\(index)-\(occurrence)", uri: "spotify:track:synthetic-\(index)",
            title: "\(changed ? "Changed" : "Track") \(index)", artist: "Artist \(index % 100)",
            album: "Album \(index % 500)", duration: 180, artworkURL: nil,
            addedAt: Date(timeIntervalSince1970: Double(occurrence)), occurrenceUID: "uid-\(index)-\(occurrence)")
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

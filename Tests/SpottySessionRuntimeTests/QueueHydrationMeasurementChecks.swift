@testable import SpottyRuntimeTestSupport
import Darwin
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

/// Measures the real hydration service with immediate synthetic metadata and a controlled flush.
/// There are no HTTP requests, real-time sleeps, or machine-specific performance thresholds.
@MainActor
struct QueueHydrationMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_QUEUE_HYDRATION_REPORT"] != nil))
    func measureQueueHydration() async throws {
        let samples = 5
        var measurements: [[String: Any]] = []
        for count in [64, 512, 5_000] {
            let entries = (0..<count).map {
                QueueEntry(uri: "spotify:track:\($0)", provider: "connect", occurrence: $0, uid: "uid-\($0)")
            }
            for available in [true, false] {
                for sample in -1..<samples {
                    let calls = HarnessCounters()
                    let web = HarnessResponseGate<[CatalogTrack]>()
                    web.resolve(.failure(WebQueueFailure.requestFailed(403)))
                    let clock = HarnessClock.parked()
                    defer { web.close(); clock.releaseAll() }
                    let service = QueueService(
                        webQueue: GatedQueue(responses: web),
                        metadata: TrackMetadataService(
                            remote: MetadataResponses { uri in
                                calls.record("fetch")
                                guard available else { throw URLError(.resourceUnavailable) }
                                return SpotifyConnectTrackMetadata(
                                    uri: uri, title: "Track", artist: "Artist", artworkURL: nil, duration: 180)
                            }), clock: clock)
                    await service.reset(accountEpoch: 1)
                    _ = await service.acceptConnect(
                        HarnessFixtures.queueState(
                            revision: 1,
                            trackURI: "spotify:track:current",
                            next: HarnessFixtures.queueTracks(entries)),
                        accountEpoch: 1, fallbackTrackURI: nil)
                    let start = ContinuousClock.now
                    let cpuStart = try cpuSeconds()
                    let refresh = Task {
                        await service.refresh(
                            fallbackEntries: entries, currentTrackURI: "spotify:track:current", accountEpoch: 1,
                            onUpdate: { _ in calls.record("publication") })
                    }
                    defer { refresh.cancel() }
                    if available {
                        try await requireEventually(description: "all synthetic metadata reaches the service") {
                            await service.refreshDiagnostics.metadataResults == count
                        }
                        try await requireEventually { clock.waiterCount == 1 }
                        clock.releaseAll()
                    }
                    let result = await refresh.value
                    let cpu = try cpuSeconds() - cpuStart
                    let elapsed = start.duration(to: .now).components
                    let orderingMatches = result?.entries == entries
                    #expect(orderingMatches)
                    #expect(result?.tracks.count == (available ? count : 0))
                    #expect(calls.count("fetch") == count)
                    #expect(calls.count("publication") == (available ? 2 : 1))
                    if sample >= 0 {
                        measurements.append([
                            "entryCount": count, "workload": available ? "metadata" : "unavailable",
                            "sample": sample, "cpuSeconds": cpu,
                            "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                        ])
                    }
                }
            }
        }
        let report = try JSONSerialization.data(
            withJSONObject: ["version": 1, "samples": samples, "measurements": measurements],
            options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_QUEUE_HYDRATION_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

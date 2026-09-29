#if os(macOS)
    import Darwin
    import Foundation
    import SpottyTestSupport
    import Testing

    /// Opt-in polling cost. Delayed conditions model observation latency, not product deadlines.
    @MainActor
    struct WaitUntilMeasurementTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_POLLING_REPORT"] != nil))
        func measurePrerequisitePolling() async throws {
            var rows: [[String: Any]] = []
            for mode in ["immediate", "cooperative", "delayed", "absent"] {
                let iterations = mode == "immediate" ? 10_000 : (mode == "cooperative" ? 500 : 1)
                for sample in 0..<5 {
                    var polls = 0
                    let started = ContinuousClock.now
                    let cpuStart = try cpuSeconds()
                    for _ in 0..<iterations {
                        switch mode {
                        case "immediate":
                            let accepted = await waitUntil {
                                polls += 1; return true
                            }
                            _ = try #require(accepted)
                        case "cooperative":
                            var ready = false
                            let producer = Task { @MainActor in
                                await Task.yield()
                                ready = true
                            }
                            let accepted = await waitUntil {
                                polls += 1; return ready
                            }
                            await producer.value
                            _ = try #require(accepted)
                        case "delayed":
                            let readyAt = ContinuousClock.now + .milliseconds(250)
                            let accepted = await waitUntil {
                                polls += 1
                                return ContinuousClock.now >= readyAt
                            }
                            _ = try #require(accepted)
                        default:
                            let accepted = await waitUntil(timeout: .milliseconds(250)) {
                                polls += 1; return false
                            }
                            _ = try #require(!accepted)
                        }
                    }
                    let cpu = try cpuSeconds() - cpuStart
                    let elapsed = started.duration(to: .now).components
                    rows.append([
                        "mode": mode, "sample": sample, "iterations": iterations, "polls": polls,
                        "cpuSeconds": cpu,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    ])
                }
            }
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_POLLING_REPORT"])
            let data = try JSONSerialization.data(
                withJSONObject: ["version": 1, "measurements": rows], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func cpuSeconds() throws -> Double {
            var usage = rusage()
            _ = try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
    }
#endif

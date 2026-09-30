#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    /// Opt-in diagnostics only. Returning immediately preserves the native test schedule.
    struct TestHostObservationChecks {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_HOST_OBSERVATION_DIR"] != nil))
        func reportsExecutingHost() throws {
            let environment = ProcessInfo.processInfo.environment
            let directory = try #require(environment["SPOTTY_HOST_OBSERVATION_DIR"])
            let nonce = try #require(environment["SPOTTY_HOST_OBSERVATION_NONCE"])
            let pid = Int(getpid())
            let record: [String: Any] = [
                "nonce": nonce,
                "pid": pid,
                "ppid": Int(getppid()),
                "pgid": Int(getpgid(0)),
                "function": "SpottyGatewayTests.TestHostObservationChecks/reportsExecutingHost()",
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(
                    to: URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("host-\(pid).json"),
                    options: [.atomic])
        }
    }
#endif

#if canImport(Darwin)
    import Darwin
    import Foundation
    import SpottyDomain
    import Testing

    /// Opt-in optimized CPU probe. Fixtures cross the real reducer entrance and validate receipt
    /// counts; measurements carry no machine-dependent pass/fail threshold.
    struct PlaybackReducerMeasurementTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_REDUCER_REPORT"] != nil))
        func measureRetainedIntentHistory() throws {
            let iterations = 1_000
            let samples = 7
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let uri = "spotify:track:synthetic"
            let envelopes = (0..<iterations).map { index in
                PlaybackEventEnvelope(
                    accountEpoch: 1, engineEpoch: 1, source: .enginePlayback, revision: UInt64(index + 1),
                    receivedAt: now.addingTimeInterval(Double(index)),
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing, trackURI: uri,
                            timing: PlaybackTiming(position: Double(index), duration: 10_000), shuffle: false)))
            }
            var measurements: [[String: Any]] = []
            for historyCount in [0, 32, 128] {
                for workload in ["timing", "pending-options", "confirm-play"] {
                    var fixture = PlaybackState(
                        accountEpoch: 1, engineEpoch: 1, session: .ready,
                        transport: .playing, currentTrack: CurrentTrack(uri: uri))
                    let retainedCount = workload == "timing" ? historyCount : max(0, historyCount - 1)
                    fixture.intents = (0..<retainedCount).map { index in
                        var intent = PlaybackIntent(
                            command: PendingPlaybackCommand(
                                id: UUID(), kind: .transport, expectedTransport: .playing,
                                expectedTrackURI: uri, startedAt: now), baselineTrackURI: uri)
                        intent.dispatchedAt = now
                        intent.settle(index.isMultiple(of: 2) ? .observedConfirmed : .rejected, at: now)
                        return intent
                    }
                    if workload != "timing" {
                        let confirms = workload == "confirm-play"
                        var intent = PlaybackIntent(
                            command: PendingPlaybackCommand(
                                id: UUID(), kind: confirms ? .transport : .options,
                                expectedTransport: confirms ? .playing : nil,
                                expectedTrackURI: uri, expectedShuffle: confirms ? nil : true, startedAt: now),
                            baselineTrackURI: uri)
                        intent.dispatchedAt = now
                        intent.outcome = .sent
                        fixture.intents.append(intent)
                    }
                    // Warm the code and immutable fixture before collecting process CPU samples.
                    var warmed = fixture
                    _ = PlaybackReducer.apply(&warmed, envelope: envelopes[0])
                    for sample in 0..<samples {
                        var state = fixture
                        var accepted = 0
                        var settled = 0
                        var confirmed = 0
                        let start = ContinuousClock.now
                        let cpuStart = try cpuSeconds()
                        for envelope in envelopes {
                            if workload == "confirm-play" { state = fixture }
                            let reduction = PlaybackReducer.apply(&state, envelope: envelope)
                            accepted += reduction.accepted ? 1 : 0
                            settled += reduction.settledIntents.count
                            confirmed += reduction.confirmedPlayTrackURIs.count
                        }
                        let cpu = try cpuSeconds() - cpuStart
                        let duration = start.duration(to: .now).components
                        #expect(accepted == iterations)
                        #expect(settled == (workload == "confirm-play" ? iterations : 0))
                        #expect(confirmed == settled)
                        #expect(state.intents.count == fixture.intents.count)
                        #expect(state.timing.position == Double(iterations - 1))
                        if workload == "pending-options" { #expect(state.intents.last?.outcome == .sent) }
                        measurements.append([
                            "historyCount": historyCount, "intentCount": fixture.intents.count,
                            "workload": workload, "sample": sample, "cpuSeconds": cpu,
                            "wallSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                        ])
                    }
                }
            }
            let report = try JSONSerialization.data(
                withJSONObject: [
                    "version": 1, "iterations": iterations, "samples": samples, "measurements": measurements,
                ],
                options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_REDUCER_REPORT"])
            try report.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_QUEUE_EVIDENCE_REPORT"] != nil))
        func measureQueueIntentEvidence() throws {
            let iterations = 100
            let samples = 7
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var reports: [[String: Any]] = []
            for count in [64, 512, 5_000] {
                let entries = (0..<count).map { index in
                    QueueEntry(
                        uri: index == 0 || index == count - 1 ? "spotify:track:target" : "spotify:track:\(index)",
                        provider: "queue", uid: "uid-\(index)")
                }
                let observation = PlaybackEventEnvelope(
                    accountEpoch: 1, engineEpoch: 1, source: .engineQueue, receivedAt: now,
                    event: .queue(
                        PlaybackQueueSnapshot(
                            entries: entries, source: .connect, completeness: .complete,
                            revision: 2, receivedAt: now)))
                for workload in [
                    "append-present", "append-pending", "append-multiple", "remove-present", "remove-absent",
                ] {
                    var fixture = PlaybackIntent(
                        command: PendingPlaybackCommand(
                            id: UUID(), kind: .queue, expectedTransport: nil, startedAt: now),
                        baselineTrackURI: nil)
                    fixture.dispatchedAt = now
                    fixture.outcome = .sent
                    fixture.queueRevision = 1
                    switch workload {
                    case "append-present": fixture.queueMinimumCounts = ["spotify:track:target": 2]
                    case "append-pending": fixture.queueMinimumCounts = ["spotify:track:missing": 1]
                    case "append-multiple":
                        fixture.queueMinimumCounts = ["spotify:track:target": 2, "spotify:track:\(count / 2)": 1]
                    case "remove-present": fixture.removedQueueUIDs = ["uid-0"]
                    default: fixture.removedQueueUIDs = ["uid-missing"]
                    }
                    let confirms = workload != "append-pending" && workload != "remove-present"
                    var warmed = fixture
                    warmed.observe(observation)
                    #expect((warmed.outcome == .observedConfirmed) == confirms)
                    for sample in 0..<samples {
                        var confirmed = 0
                        let start = ContinuousClock.now
                        let cpuStart = try cpuSeconds()
                        for _ in 0..<iterations {
                            var intent = fixture
                            intent.observe(observation)
                            confirmed += intent.outcome == .observedConfirmed ? 1 : 0
                        }
                        let cpu = try cpuSeconds() - cpuStart
                        let duration = start.duration(to: .now).components
                        #expect(confirmed == (confirms ? iterations : 0))
                        reports.append([
                            "entryCount": count, "workload": workload, "sample": sample,
                            "cpuSeconds": cpu,
                            "wallSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                        ])
                    }
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["version": 1, "iterations": iterations, "samples": samples, "measurements": reports],
                options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_QUEUE_EVIDENCE_REPORT"])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func cpuSeconds() throws -> Double {
            var usage = rusage()
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
    }
#endif

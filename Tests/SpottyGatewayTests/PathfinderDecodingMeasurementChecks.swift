#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing
    @testable import SpottyGateway

    /// Synthetic, page-sized responses through the production decoder. Construction is untimed;
    /// optimized samples report CPU and process peak RSS without machine-dependent thresholds.
    struct PathfinderDecodingMeasurementTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_PATHFINDER_DECODING_REPORT"] != nil))
        func measureResponseDecoding() throws {
            let api = PartnerAPI()
            let iterations = 500
            var reports: [[String: Any]] = []
            let search = try searchBody(count: 30)
            let playlist = try playlistBody(count: 300)
            let error = Data(#"{"errors":[{"message":"fixture-error"}],"data":null}"#.utf8)
            let workloads: [(String, Data, Int, (Data) throws -> Int)] = [
                (
                    "search-30", search, 30,
                    { body in
                        let value: PathfinderResponse<PathfinderTrackResults> = try api.decode(
                            body, operation: .searchTracks)
                        return value.results?.tracksV2?.items?.count ?? 0
                    }
                ),
                (
                    "playlist-300", playlist, 300,
                    { body in
                        let value: PathfinderPlaylistResponse = try api.decode(body, operation: .fetchPlaylist)
                        return value.data?.playlistV2?.content?.items?.count ?? 0
                    }
                ),
                (
                    "graphql-error", error, 1,
                    { body in
                        do {
                            let _: PathfinderPlaylistResponse = try api.decode(body, operation: .fetchPlaylist)
                            return 0
                        } catch PartnerAPIError.graphQLErrors(PathfinderOperation.fetchPlaylist.name) {
                            return 1
                        }
                    }
                ),
            ]
            for (name, body, count, decode) in workloads {
                for _ in 0..<5 { _ = try decode(body) }
                for sample in 0..<3 {
                    var checksum = 0
                    let before = try cpuSeconds()
                    let started = ContinuousClock.now
                    for _ in 0..<iterations { checksum += try decode(body) }
                    let elapsed = started.duration(to: .now).components
                    let cpu = try cpuSeconds() - before
                    #expect(checksum == count * iterations)
                    var usage = rusage()
                    try #require(getrusage(RUSAGE_SELF, &usage) == 0)
                    reports.append([
                        "workload": name, "sample": sample, "inputBytes": body.count, "cpuSeconds": cpu,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                        "processPeakResidentBytes": usage.ru_maxrss,
                    ])
                }
            }
            let report = try JSONSerialization.data(
                withJSONObject: [
                    "version": 1, "iterations": iterations, "measurements": reports,
                    "limits":
                        "Synthetic optimized decoding only; process peak RSS is cumulative. No network or end-to-end latency claim.",
                ], options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_PATHFINDER_DECODING_REPORT"])
            try report.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func searchBody(count: Int) throws -> Data {
            let root = try #require(
                JSONSerialization.jsonObject(with: gatewayFixture(named: "search-tracks")) as? [String: Any])
            let data = try #require(root["data"] as? [String: Any])
            let search = try #require(data["searchV2"] as? [String: Any])
            let tracks = try #require(search["tracksV2"] as? [String: Any])
            let item = try #require((tracks["items"] as? [[String: Any]])?.first)
            return try JSONSerialization.data(
                withJSONObject: [
                    "data": [
                        "searchV2": ["tracksV2": ["items": Array(repeating: item, count: count), "totalCount": count]]
                    ]
                ], options: .sortedKeys)
        }

        private func playlistBody(count: Int) throws -> Data {
            let items = (0..<count).map { index -> [String: Any] in
                [
                    "uid": "fixture-occurrence-\(index)", "addedAt": ["isoString": "2026-09-01T00:00:00Z"],
                    "itemV2": [
                        "data": [
                            "__typename": "Track", "uri": "spotify:track:fixture-\(index)",
                            "name": "Fixture Track \(index)",
                            "trackNumber": index + 1, "discNumber": 1, "trackDuration": ["totalMilliseconds": 180000],
                            "albumOfTrack": [
                                "uri": "spotify:album:fixture", "name": "Fixture Album", "coverArt": ["sources": []],
                            ],
                            "artists": [
                                "items": [["uri": "spotify:artist:fixture", "profile": ["name": "Fixture Artist"]]]
                            ],
                        ]
                    ],
                ]
            }
            return try JSONSerialization.data(
                withJSONObject: [
                    "data": [
                        "playlistV2": [
                            "__typename": "Playlist", "uri": "spotify:playlist:fixture", "name": "Fixture Playlist",
                            "content": ["items": items, "totalCount": count],
                        ]
                    ]
                ], options: .sortedKeys)
        }

        private func cpuSeconds() throws -> Double {
            var usage = rusage()
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
    }
#endif

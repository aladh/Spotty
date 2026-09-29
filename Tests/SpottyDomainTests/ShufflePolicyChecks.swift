import Foundation
import SpottyDomain
import Testing

@Suite("Shuffle Policy")
struct ShufflePolicyTests {
    @Test(arguments: [0, 1])
    func trivialListsNeedNoHistoryOrRandomness(count: Int) {
        var generator = ShuffleGenerator()
        var reads = 0
        let order = ShufflePolicy.order(
            count: count,
            uri: { _ in
                reads += 1; return "track"
            }, history: [:], now: 0, generator: &generator)
        #expect(order == Array(0..<count))
        #expect(reads == 0)
        #expect(generator.state == 0)
    }

    @Test(arguments: [UInt64(1), 7, 123])
    func recentTrackSinksBehindUnplayedTrack(seed: UInt64) {
        var generator = ShuffleGenerator(state: seed)
        let uris = ["fresh", "unplayed"]
        let order = ShufflePolicy.order(
            count: 2, uri: { uris[$0] }, history: ["fresh": 9_000], now: 10_000, generator: &generator)
        #expect(order == [1, 0])
    }

    @Test
    func freshnessIsClampedAndWeightedByPosition() {
        let now = ShufflePolicy.freshnessWindow
        let uris = ["played", "unplayed"]
        for (playedAt, expected) in [(now, 1.0), (now / 2, 2.0), (0.0, 3.0), (-now, 3.0), (now + 60, 1.0)] {
            let score = ShufflePolicy.score([0, 1], uri: { uris[$0] }, history: ["played": playedAt], now: now)
            #expect(score == expected)
        }
        #expect(ShufflePolicy.score([1, 0], uri: { uris[$0] }, history: ["played": now], now: now) == 2)
        #expect(ShufflePolicy.score([0, 1], uri: { uris[$0] }, history: [:], now: now) == 3)
        #expect(ShufflePolicy.score([], uri: { uris[$0] }, history: [:], now: now) == 0)
    }

    @Test
    func retentionIncludesTheCutoffAndFuturePlays() {
        let now = 200.0 * 24 * 60 * 60
        let history = [
            "expired": 0.0, "recent": now - 60, "edge": now - ShufflePolicy.retention,
            "pastEdge": now - ShufflePolicy.retention - 1, "future": now + 60,
        ]
        let retained = ShufflePolicy.pruned(history, now: now)
        #expect(retained == history.filter { ["recent", "edge", "future"].contains($0.key) })
        #expect(ShufflePolicy.pruned([:], now: now).isEmpty)
    }

    @Test(arguments: ["empty", "unrelated", "expired", "equally-recent", "equally-half-fresh"])
    func equalFreshnessUsesOnlyTheFirstRandomOrder(mode: String) {
        let now = ShufflePolicy.freshnessWindow
        let uris = (0..<200).map { "track-\($0)" }
        let playedAt = mode == "expired" ? -now : mode == "equally-recent" ? now : now / 2
        let history: [String: TimeInterval] =
            mode == "empty"
            ? [:]
            : mode == "unrelated"
                ? ["elsewhere": now]
                : Dictionary(uniqueKeysWithValues: uris.map { ($0, playedAt) })
        var expectedGenerator = ShuffleGenerator(state: 99)
        let expected = Array(uris.indices).shuffled(using: &expectedGenerator)
        var generator = ShuffleGenerator(state: 99)
        let actual = ShufflePolicy.order(
            count: uris.count, uri: { uris[$0] }, history: history, now: now, generator: &generator)
        #expect(actual == expected)
        #expect(generator.state == expectedGenerator.state, "equal scores need no more random candidates")
    }

    @Test
    func largePlaylistReadsEachTrackHistoryAtMostOnce() {
        let count = 10_000
        var reads = [Int](repeating: 0, count: count)
        var generator = ShuffleGenerator()
        let order = ShufflePolicy.order(
            count: count,
            uri: {
                reads[$0] += 1; return "track-\($0)"
            },
            history: ["track-0": 100], now: 100, generator: &generator)
        #expect(reads.max() == 1)
        #expect(order.sorted() == Array(0..<count))
    }

    @Test(arguments: [UInt64(0), 1, 7, 99, 123])
    func mixedHistoryKeepsTheBestOfTheSameRandomCandidates(seed: UInt64) throws {
        let now = ShufflePolicy.freshnessWindow
        // Duplicate URIs retain distinct occurrences; expired and future timestamps clamp.
        let uris = ["recent", "unplayed", "half", "recent", "expired", "future", "unplayed"]
        let history = ["recent": now - 100, "half": now / 2, "expired": -now, "future": now + 60]
        var candidateGenerator = ShuffleGenerator(state: seed)
        let candidates = (0..<ShufflePolicy.candidateCount).map { _ in
            Array(uris.indices).shuffled(using: &candidateGenerator)
        }
        let scores = candidates.map { ShufflePolicy.score($0, uri: { uris[$0] }, history: history, now: now) }
        let bestScore = try #require(scores.max())
        let bestIndex = try #require(scores.firstIndex(of: bestScore))
        var generator = ShuffleGenerator(state: seed)
        let actual = ShufflePolicy.order(
            count: uris.count, uri: { uris[$0] }, history: history, now: now, generator: &generator)
        #expect(actual == candidates[bestIndex])
        #expect(actual.sorted() == Array(uris.indices))
        #expect(generator.state == candidateGenerator.state)
    }
}

/// Local deterministic random input, independent of clocks and system entropy.
private struct ShuffleGenerator: RandomNumberGenerator {
    var state: UInt64 = 0

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

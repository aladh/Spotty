import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@Suite("Connect queue observations")
@MainActor
struct ConnectQueueObservationTests {
    @Test(arguments: [false, true], [false, true])
    func oneObservationPreservesRawMutationEvidenceAndProjectsVisibleOccurrences(
        disallowSet: Bool, disallowRemove: Bool
    ) async throws {
        let next = [
            QueueProtocolTrack(
                uri: "spotify:track:duplicate", uid: "first", provider: "queue", metadata: ["fixture": "retained"],
                removed: ["removed"], blocked: ["blocked"],
                restrictions: ["disallow_skipping_next_reasons": ["reason"]],
                albumURI: "spotify:album:album", disallowReasons: ["restricted"], artistURI: "spotify:artist:artist"),
            QueueProtocolTrack(uri: "spotify:episode:hidden", uid: "episode", provider: "context"),
            QueueProtocolTrack(uri: "spotify:track:duplicate", uid: "second", provider: "context"),
            QueueProtocolTrack(uri: "spotify:delimiter", provider: "delimiter"),
            QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "autoplay", provider: "autoplay"),
        ]
        let prev = [QueueProtocolTrack(uri: "spotify:track:previous", uid: "previous", provider: "context")]
        let service = isolatedQueueService()
        await service.reset(accountEpoch: 5)
        let accepted = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 41, generation: 17, trackURI: "spotify:track:current", next: next, prev: prev,
                    queueRevision: "queue-token", disallowSetQueue: disallowSet,
                    disallowRemovingFromNextTracks: disallowRemove),
                accountEpoch: 5, fallbackTrackURI: "spotify:track:obsolete"))
        #expect(
            accepted.snapshot.entries == [
                QueueEntry(uri: "spotify:track:duplicate", provider: "queue", occurrence: 0, uid: "first"),
                QueueEntry(uri: "spotify:track:duplicate", provider: "context", occurrence: 1, uid: "second"),
            ])
        #expect(accepted.snapshot.contextURI == "spotify:track:current")
        #expect(accepted.snapshot.accountEpoch == 5)
        #expect(accepted.snapshot.revision == 41)
        #expect(accepted.snapshot.receivedAt == HarnessDates.fixed)
        #expect(accepted.snapshot.source == .connect)
        #expect(accepted.snapshot.completeness == .complete)
        #expect(
            accepted.mutation
                == QueueMutationSnapshot(
                    accountEpoch: 5, engineEpoch: 17, sourceRevision: 41, source: .connect, completeness: .complete,
                    provisional: false, next: next, prev: prev, queueRevision: "queue-token",
                    disallowSetQueue: disallowSet, disallowRemovingFromNextTracks: disallowRemove))
    }

    enum Ordering: CaseIterable { case absent, hiddenOnly, knownEmpty, visibleWithoutCurrent }

    @Test(arguments: Ordering.allCases)
    func provisionalInputRetainsDisplayButReplacesMutationAuthority(_ ordering: Ordering) async throws {
        let service = isolatedQueueService()
        await service.reset(accountEpoch: 1)
        let prior = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 1, trackURI: "spotify:track:current",
                    next: [QueueProtocolTrack(uri: "spotify:track:old", uid: "old", provider: "queue")]),
                accountEpoch: 1, fallbackTrackURI: nil))
        let next: [QueueProtocolTrack]
        switch ordering {
        case .absent, .knownEmpty: next = []
        case .hiddenOnly:
            next = [
                QueueProtocolTrack(uri: "spotify:episode:hidden", provider: "context"),
                QueueProtocolTrack(uri: "spotify:delimiter", provider: "delimiter"),
                QueueProtocolTrack(uri: "spotify:track:autoplay", provider: "autoplay"),
            ]
        case .visibleWithoutCurrent:
            next = [QueueProtocolTrack(uri: "spotify:track:new", uid: "new", provider: "queue")]
        }
        let provisional = ordering == .absent || ordering == .hiddenOnly
        let accepted = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 2, trackURI: ordering == .knownEmpty ? "spotify:track:current" : nil,
                    next: next, queueRevision: "new-token"),
                accountEpoch: 1, fallbackTrackURI: "spotify:track:current"))
        let expectedEntries =
            provisional
            ? prior.snapshot.entries
            : ordering == .knownEmpty
                ? []
                : [
                    QueueEntry(uri: "spotify:track:new", provider: "queue", uid: "new")
                ]
        #expect(accepted.snapshot.entries == expectedEntries)
        #expect(accepted.snapshot.contextURI == "spotify:track:current")
        #expect(accepted.snapshot.source == .connect)
        #expect(accepted.snapshot.completeness == .complete)
        #expect(accepted.snapshot.revision == (provisional ? 1 : 2))
        #expect(accepted.mutation.provisional == provisional)
        #expect(accepted.mutation.source == (provisional ? .provisional : .connect))
        #expect(accepted.mutation.completeness == (provisional ? .partial : .complete))
        #expect(accepted.mutation.sourceRevision == 2)
        #expect(accepted.mutation.next == next)
        #expect(accepted.mutation.queueRevision == "new-token")
    }

    @Test(arguments: [UInt64(7), 8])
    func staleOrEqualRevisionCannotReplaceAnyPartOfTheAcceptedObservation(_ revision: UInt64) async throws {
        let service = isolatedQueueService()
        await service.reset(accountEpoch: 3)
        let first = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: 8, generation: 9, trackURI: "spotify:track:current",
                    next: [QueueProtocolTrack(uri: "spotify:track:accepted", uid: "accepted", provider: "queue")],
                    queueRevision: "accepted-token", disallowSetQueue: true),
                accountEpoch: 3, fallbackTrackURI: nil))
        let stale = try #require(
            await service.acceptConnect(
                HarnessFixtures.queueState(
                    revision: revision, generation: 100, trackURI: "spotify:track:stale",
                    next: [QueueProtocolTrack(uri: "spotify:track:stale", uid: "stale", provider: "autoplay")],
                    queueRevision: "stale-token", disallowRemovingFromNextTracks: true),
                accountEpoch: 3, fallbackTrackURI: "spotify:track:stale"))
        #expect(stale.mutation == first.mutation)
        #expect(stale.snapshot.entries == first.snapshot.entries)
        #expect(stale.snapshot.contextURI == first.snapshot.contextURI)
        #expect(stale.snapshot.revision == first.snapshot.revision)
        #expect(stale.snapshot.receivedAt == first.snapshot.receivedAt)
    }
}

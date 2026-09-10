import Testing
import SpottyDomain
import Foundation

@Suite("Queue Mutation")
struct QueueMutationTests {
    @Test
    func testQueueMutation() {
        func entry(_ uri: String, provider: String = "queue", occurrence: Int, uid: String = "") -> QueueEntry {
            QueueEntry(uri: uri, provider: provider, occurrence: occurrence, uid: uid)
        }

        func protocolTrack(_ uri: String, provider: String = "queue", uid: String = "") -> QueueProtocolTrack {
            QueueProtocolTrack(uri: uri, uid: uid, provider: provider)
        }

        func snapshot(
            next: [QueueProtocolTrack],
            prev: [QueueProtocolTrack] = [protocolTrack("spotify:track:prev", provider: "context")],
            provisional: Bool = false,
            source: PlaybackQueueSource = .connect,
            completeness: PlaybackQueueCompleteness = .complete,
            accountEpoch: UInt64 = 1,
            engineEpoch: UInt64 = 2,
            disallowSetQueue: Bool = false,
            disallowRemoving: Bool = false
        ) -> QueueMutationSnapshot {
            QueueMutationSnapshot(
                accountEpoch: accountEpoch,
                engineEpoch: engineEpoch,
                sourceRevision: 4,
                source: source,
                completeness: completeness,
                provisional: provisional,
                next: next,
                prev: prev,
                queueRevision: "rev-4",
                disallowSetQueue: disallowSetQueue,
                disallowRemovingFromNextTracks: disallowRemoving
            )
        }

        let duplicate = "spotify:track:dup"
        let other = "spotify:track:other"
        let visible = [
            entry(duplicate, occurrence: 0, uid: "q0"),
            entry(duplicate, occurrence: 1, uid: "q1"),
            entry(other, occurrence: 2, uid: "q2"),
        ]
        let protocolNext = [
            protocolTrack(duplicate, uid: "q0"),
            protocolTrack(duplicate, uid: "q1"),
            protocolTrack(other, uid: "q2"),
            protocolTrack("spotify:delimiter", provider: "delimiter"),
            protocolTrack("spotify:track:autoplay", provider: "autoplay"),
        ]
        let remote = ConnectCommandRoute.remote(from: "mac", to: "speaker")

        do {
            #expect(
                (QueueProtocolProjection.upcoming(from: protocolNext).map(\.uid)) == (["q0", "q1", "q2"]),
                "upcoming projection stops at the delimiter")
            #expect(
                (QueueProtocolProjection.upcomingEntries(from: protocolNext).map(\.uid)) == (["q0", "q1", "q2"]),
                "upcoming entries preserve occurrence uids")
            let mixed = [
                protocolTrack("spotify:episode:ignored", provider: "context"),
                protocolTrack("spotify:track:first", uid: "q0"),
                protocolTrack("spotify:delimiter", provider: "delimiter"),
                protocolTrack("spotify:track:autoplay", provider: "autoplay"),
            ]
            #expect(
                (QueueProtocolProjection.upcoming(from: mixed).map(\.uri)) == (["spotify:track:first"]),
                "upcoming projection skips episodes and autoplay after the delimiter")
            #expect(
                (!QueueProtocolProjection.isPlayableTrackURI("spotify:episode:ignored")) == true,
                "episodes are not playable track URIs")
            #expect(
                (QueueProtocolProjection.isPlayableTrackURI("spotify:track:now")) == true, "track URIs are playable")
            #expect(
                (QueueProtocolProjection.matchesVisibleUpcoming(
                    protocolNext: protocolNext,
                    visible: visible
                )) == true, "visible Connect URIs match the upcoming projection")
            let removedSecondDuplicate = QueueProtocolProjection.removingUpcomingOccurrences(
                selectedIDs: [visible[1].id],
                visibleUpcoming: visible,
                protocolNext: protocolNext
            )
            #expect(
                (removedSecondDuplicate?.map(\.uid)) == (["q0", "q2", "", ""]),
                "duplicate URI removal keeps the first occurrence and autoplay")
            #expect(
                (removedSecondDuplicate?.map(\.uri))
                    == ([duplicate, other, "spotify:delimiter", "spotify:track:autoplay"]),
                "duplicate URI removal keeps protocol URIs in order")
            let removedBothDuplicates = QueueProtocolProjection.removingUpcomingOccurrences(
                selectedIDs: [visible[0].id, visible[1].id],
                visibleUpcoming: visible,
                protocolNext: protocolNext
            )
            #expect(
                (removedBothDuplicates?.map(\.uri)) == ([other, "spotify:delimiter", "spotify:track:autoplay"]),
                "multi-occurrence removal is ordered and keeps delimiter metadata")
            #expect(
                (QueueProtocolProjection.removingUpcomingOccurrences(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: [entry(other, occurrence: 0)],
                    protocolNext: protocolNext
                )) == nil, "URI-set selection cannot be used when visible identities drifted")
        }

        do {
            let tracks = [
                CatalogTrack(
                    id: "a", uri: duplicate, title: "A", artist: "", album: "",
                    duration: 1, artworkURL: nil, addedAt: nil
                ),
                CatalogTrack(
                    id: "b", uri: duplicate, title: "B", artist: "", album: "",
                    duration: 1, artworkURL: nil, addedAt: nil
                ),
                CatalogTrack(
                    id: "c", uri: other, title: "C", artist: "", album: "",
                    duration: 1, artworkURL: nil, addedAt: nil
                ),
            ]
            let ordered = QueueMutationSelection.orderedUpcoming(
                selectedIDs: [visible[2].id, visible[0].id],
                in: visible
            )
            #expect(
                (ordered.map(\.id)) == ([visible[0].id, visible[2].id]), "selection follows visible upcoming order")
            #expect(
                (QueueMutationSelection.addURIs(from: Array(tracks.prefix(2)))) == ([duplicate, duplicate]),
                "batch add keeps duplicate URIs from distinct rows")
        }

        do {
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 2,
                    isRemovalAllowed: true
                )) == (.removeUpcomingOccurrences), "Delete on an allowed upcoming selection removes occurrences")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 1,
                    isRemovalAllowed: true
                )) == (.removeUpcomingOccurrences), "Backspace uses the same native delete command")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 0,
                    isRemovalAllowed: true
                )) == nil, "Delete is not enabled without a selection")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 2,
                    isRemovalAllowed: false
                )) == nil, "Delete is not enabled when replacement is refused")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: false,
                    selectedUpcomingCount: 2,
                    isRemovalAllowed: true
                )) == nil, "unrelated keys are not queue removal")
        }

        do {
            let allowed = QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[1].id],
                visibleUpcoming: visible,
                nowPlayingID: "now",
                historyIDs: ["hist"],
                mutation: snapshot(next: protocolNext),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            )
            switch allowed {
            case let .success(replacement):
                #expect(
                    (replacement.prev.map(\.uri)) == (["spotify:track:prev"]), "allowed replacement keeps prev_tracks")
                #expect((replacement.removedCount) == (1), "allowed replacement reports one removal")
                #expect((replacement.queueRevision) == ("rev-4"), "allowed replacement preserves queue revision")
            case let .failure(reason):
                #expect((false) == true, "complete remote snapshot should be allowed: \(reason)")
            }

            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext),
                    route: remote,
                    isConnected: false,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.notConnected)), "disconnected removal is refused")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext),
                    route: .waitingForLocalIdentity,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.joiningConnect)), "joining Connect is refused")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext),
                    route: .local,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.localOwnerUnsupported)),
                "local owner is unsupported without a Spirc replacement export")
            #expect(
                (!LocalQueueReplacementCapability.isSupported
                    && LocalQueueReplacementCapability.evidence.contains("add_to_queue")
                    && LocalQueueReplacementCapability.evidence.contains("SetQueueCommand")) == true,
                "local replacement is documented as unsupported")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, provisional: true),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.provisional)), "provisional snapshots cannot be replaced")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, completeness: .partial),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.incompleteProvenance)), "partial provenance cannot be replaced")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, source: .webAPI),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.incompleteProvenance)),
                "web-api presentation provenance cannot replace Connect protocol tracks")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, disallowSetQueue: true),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.restricted)), "Spotify set_queue restrictions refuse replacement")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, disallowRemoving: true),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.restricted)), "Spotify next-track removal restrictions refuse replacement")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: ["now"],
                    visibleUpcoming: visible,
                    nowPlayingID: "now",
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.nowPlayingOrHistory)), "now-playing identity is not removable")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: ["hist"],
                    visibleUpcoming: visible,
                    nowPlayingID: "now",
                    historyIDs: ["hist"],
                    mutation: snapshot(next: protocolNext),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.nowPlayingOrHistory)), "history identity is not removable")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext, accountEpoch: 1),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 9,
                    engineEpoch: 2
                )) == (.failure(.staleIdentities)), "stale account epoch refuses replacement")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: protocolNext),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 99
                )) == (.failure(.staleIdentities)), "stale engine epoch refuses replacement")
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: nil,
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.incompleteProvenance)), "missing mutation snapshot is incomplete")

            let driftedUIDs = [
                protocolTrack(duplicate, uid: "q9"),
                protocolTrack(duplicate, uid: "q8"),
                protocolTrack(other, uid: "q7"),
                protocolTrack("spotify:delimiter", provider: "delimiter"),
                protocolTrack("spotify:track:autoplay", provider: "autoplay"),
            ]
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: driftedUIDs),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.staleIdentities)),
                "same URIs at the same indices with different Connect UIDs refuse the old selection")
            #expect(
                (visible[0].id
                    != QueueEntry(
                        uri: duplicate, provider: "queue", occurrence: 0, uid: "q9"
                    ).id) == true, "old UID-bearing identities do not survive a UID-only snapshot rotation")

            let duplicateUIDNext = [
                protocolTrack(duplicate, uid: "shared"),
                protocolTrack(other, uid: "shared"),
                protocolTrack("spotify:delimiter", provider: "delimiter"),
            ]
            let duplicateUIDVisible = [
                entry(duplicate, occurrence: 0, uid: "shared"),
                entry(other, occurrence: 1, uid: "shared"),
            ]
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [duplicateUIDVisible[0].id],
                    visibleUpcoming: duplicateUIDVisible,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: duplicateUIDNext),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.staleIdentities)),
                "duplicate Connect UIDs fail closed even when URIs and indices match")

            let webUnique = [entry("spotify:track:only", provider: "web-api", occurrence: 0)]
            let webUniqueProtocol = [
                protocolTrack("spotify:track:only", provider: "context", uid: "c1"),
                protocolTrack("spotify:delimiter", provider: "delimiter"),
            ]
            switch QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [webUnique[0].id],
                visibleUpcoming: webUnique,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: webUniqueProtocol),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ) {
            case let .success(replacement):
                #expect(
                    (replacement.next.map(\.uri)) == (["spotify:delimiter"]),
                    "unique-URI Web presentation can bind a unique Connect uid")
            case let .failure(reason):
                #expect((false) == true, "unique-URI Web fallback should be allowed: \(reason)")
            }

            let webDuplicates = [
                entry(duplicate, provider: "web-api", occurrence: 0),
                entry(duplicate, provider: "web-api", occurrence: 1),
            ]
            let webDuplicateProtocol = [
                protocolTrack(duplicate, uid: "q0"),
                protocolTrack(duplicate, uid: "q1"),
                protocolTrack("spotify:delimiter", provider: "delimiter"),
            ]
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [webDuplicates[0].id],
                    visibleUpcoming: webDuplicates,
                    nowPlayingID: nil,
                    historyIDs: [],
                    mutation: snapshot(next: webDuplicateProtocol),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.staleIdentities)),
                "Web presentation without UIDs cannot remove duplicate URI occurrences")
        }

        do {
            func expectAddFeedback(
                requested: Int,
                completed: Int,
                kind: QueueAddFeedbackKind,
                message: String,
                label: String
            ) {
                guard let actual = QueueAddFeedbackPolicy.evaluate(requested: requested, completed: completed) else {
                    #expect((false) == true, "\(label) produced feedback")
                    return
                }
                #expect((actual.kind) == (kind), "\(label) kind")
                #expect((actual.message) == (message), "\(label) message")
            }

            expectAddFeedback(
                requested: 1,
                completed: 1,
                kind: .success,
                message: "Queue request sent",
                label: "single add success"
            )
            expectAddFeedback(
                requested: 3,
                completed: 3,
                kind: .success,
                message: "Queue requests sent for 3 songs",
                label: "batch add success"
            )
            expectAddFeedback(
                requested: 3,
                completed: 0,
                kind: .failure,
                message: "Could not add those tracks to the queue.",
                label: "zero completed commands"
            )
            expectAddFeedback(
                requested: 5,
                completed: 2,
                kind: .informational,
                message: "Queue requests sent for 2 of 5 songs",
                label: "partial sequential add"
            )
            #expect(
                (QueueAddFeedbackPolicy.evaluate(requested: 2, completed: 3)) == nil,
                "invalid counts produce no message")
        }

        do {
            guard
                case let .success(firstReplacement) = QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[0].id],
                    visibleUpcoming: visible,
                    nowPlayingID: "now",
                    historyIDs: ["hist"],
                    mutation: snapshot(next: protocolNext),
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )
            else {
                #expect((false) == true, "first overlapping removal should be allowed")
                return
            }
            var committed = snapshot(next: protocolNext)
            committed.next = firstReplacement.next
            #expect(
                (QueueMutationPolicy.evaluateRemoval(
                    selectedIDs: [visible[1].id],
                    visibleUpcoming: visible,
                    nowPlayingID: "now",
                    historyIDs: ["hist"],
                    mutation: committed,
                    route: remote,
                    isConnected: true,
                    accountEpoch: 1,
                    engineEpoch: 2
                )) == (.failure(.incompleteProvenance)),
                "a second delete from the original visible list cannot restore the removed uid")
            #expect(
                (!firstReplacement.next.contains { $0.uid == "q0" }) == true,
                "the committed next list no longer contains the first removed uid")
        }
    }
}

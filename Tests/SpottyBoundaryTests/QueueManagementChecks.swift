import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private final class QueueLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackEngineResult
    private var storedOperations: [LocalPlaybackOperation] = []

    init(result: PlaybackEngineResult = .ok) {
        self.result = result
    }

    var operations: [LocalPlaybackOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }
    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        lock.lock()
        storedOperations.append(operation)
        lock.unlock()
        return result
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private enum QueueRemoteFailure: Error { case boom }

private actor QueueRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case failAfter(Int)
        case park
    }

    private let behavior: Behavior
    private var parked: CheckedContinuation<Void, Error>?
    private var parkID: UInt64 = 0
    private(set) var commands: [SpotifyConnectCommand] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var sendCount: Int { commands.count }

    func send(_ command: SpotifyConnectCommand, from _: String, to _: String) async throws {
        commands.append(command)
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw QueueRemoteFailure.boom
        case let .failAfter(limit):
            if commands.count > limit {
                throw QueueRemoteFailure.boom
            }
        case .park:
            parkID &+= 1
            let id = parkID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    parked?.resume(throwing: CancellationError())
                    parked = continuation
                }
            } onCancel: {
                Task { await self.completePark(id: id, success: false, cancelled: true) }
            }
        }
    }

    func completePark(success: Bool) {
        completePark(id: parkID, success: success, cancelled: false)
    }

    private func completePark(id: UInt64, success: Bool, cancelled: Bool) {
        guard id == parkID, let parked else { return }
        self.parked = nil
        if cancelled {
            parked.resume(throwing: CancellationError())
        } else if success {
            parked.resume()
        } else {
            parked.resume(throwing: QueueRemoteFailure.boom)
        }
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri, title: "Metadata", artist: "Artist", artworkURL: nil, duration: 180
        )
    }
}

private actor IdleQueueWeb: WebQueueClient {
    func queue() async throws -> [CatalogTrack] { throw URLError(.badServerResponse) }
}

private actor IdleQueuePreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private func isolatedQueueService(
    hook: (any QueueServiceHook)? = nil
) -> QueueService {
    QueueService(
        webQueue: IdleQueueWeb(),
        metadata: TrackMetadataService(remote: QueueRemoteClient(.succeed)),
        hook: hook
    )
}

private func connectEntry(_ uri: String, occurrence: Int = 0) -> QueueEntry {
    QueueEntry(uri: uri, provider: "connect", occurrence: occurrence)
}

private func queueEnvironment(
    local: any LocalPlaybackEngine = QueueLocalEngine(),
    remote: any RemotePlaybackClient,
    clock: any PlaybackClock = SystemPlaybackClock(),
    queueServiceHook: (any QueueServiceHook)? = nil
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleQueueWeb(),
        account: BoundaryIdleAccount(),
        audioOutput: BoundaryIdleAudio(),
        preferences: IdleQueuePreferences(),
        lifecycle: BoundaryIdleLifecycle(),
        clock: clock,
        catalog: BoundaryIdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: BoundaryIdleAttributes(),
        queueServiceHook: queueServiceHook
    )
}

@MainActor
private func seedReady(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
}

@MainActor
private func seedRemoteOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [
                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                ],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedLocalOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .owner(.local(PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedAuthoritativeQueue(_ player: PlaybackStore, revision: UInt64 = 4) async {
    let duplicate = "spotify:track:dup"
    let other = "spotify:track:other"
    let entries = [
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 0, uid: "q0"),
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 1, uid: "q1"),
        QueueEntry(uri: other, provider: "queue", occurrence: 2, uid: "q2"),
    ]
    let next = [
        QueueProtocolTrack(uri: duplicate, uid: "q0", provider: "queue"),
        QueueProtocolTrack(uri: duplicate, uid: "q1", provider: "queue"),
        QueueProtocolTrack(uri: other, uid: "q2", provider: "queue"),
        QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
        QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "a0", provider: "autoplay"),
    ]
    let prev = [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")]
    await player.queueService.reset(accountEpoch: player.accountEpoch)
    if let accepted = await player.queueService.acceptConnect(
        entries,
        accountEpoch: player.accountEpoch,
        sourceRevision: revision,
        contextURI: "spotify:track:now",
        engineEpoch: player.engineGeneration,
        protocolNext: next,
        protocolPrev: prev,
        queueRevision: "rev-\(revision)"
    ) {
        player.queueMutation = accepted.mutation
    }
    _ = player.send(
        .queue(
            PlaybackQueueSnapshot(
                entries: entries.map { PlaybackQueueItem($0) },
                source: .connect,
                completeness: .complete,
                revision: revision,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                contextURI: "spotify:track:now"
            )),
        source: .engineQueue,
        revision: revision,
        engineEpoch: player.engineGeneration,
        accountEpoch: player.accountEpoch
    )
}

@MainActor
private func yieldPasses(_ count: Int = 8) async {
    for _ in 0..<count { await Task.yield() }
}

private func jsonStringMap(_ value: Any?) -> [String: String] {
    if let typed = value as? [String: String] { return typed }
    guard let object = value as? [String: Any] else { return [:] }
    return object.reduce(into: [:]) { result, pair in
        if let string = pair.value as? String {
            result[pair.key] = string
        }
    }
}

@MainActor
private func invokeKeyboardQueueDelete(player: PlaybackStore, selectedIDs: Set<String>) {
    let selectedCount = QueueMutationSelection.orderedUpcoming(
        selectedIDs: selectedIDs,
        in: player.queueNextEntries
    ).count
    guard
        QueueMutationSelection.keyboardCommand(
            deleteOrBackspace: true,
            selectedUpcomingCount: selectedCount,
            isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: selectedIDs)
        ) == .removeUpcomingOccurrences
    else {
        return
    }
    player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
}

private func connectQueueEnvelope(
    sequence: UInt64,
    revision: UInt64,
    sessionGeneration: UInt64
) -> RustPlaybackEventEnvelope {
    RustPlaybackEventEnvelope(
        sequence: sequence,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
        event: .queue(connectQueueState(revision: revision, sessionGeneration: sessionGeneration))
    )
}

private func connectQueueState(revision: UInt64, sessionGeneration: UInt64) -> RustQueueState {
    let next = [
        ("spotify:track:dup", "q0"),
        ("spotify:track:other", "q2"),
    ]
    return RustQueueState(
        revision: revision,
        sessionGeneration: sessionGeneration,
        track: RustQueueState.Item(
            uri: "spotify:track:now",
            provider: "context",
            uid: "occ-now"
        ),
        protocolNextTracks: next.map {
            QueueProtocolTrack(uri: $0.0, uid: $0.1, provider: "queue")
        },
        protocolPrevTracks: [],
        queueRevision: "rev-\(revision)",
        disallowSetQueue: false,
        disallowRemovingFromNextTracks: false
    )
}

@Suite("Queue Management")
struct QueueManagementTests {
    @Test
    @MainActor
    func testQueueManagement() async {
        do {
            do {
                do {
                    let command = SpotifyConnectCommand.setQueue(
                        next: [
                            QueueProtocolTrack(
                                uri: "spotify:track:keep",
                                uid: "q0",
                                provider: "queue",
                                metadata: ["spotty.sentinel": "keep-me", "is_queued": "true"],
                                albumURI: "spotify:album:fixture",
                                artistURI: "spotify:artist:fixture"
                            ),
                            QueueProtocolTrack(
                                uri: "spotify:delimiter",
                                uid: "",
                                provider: "delimiter",
                                metadata: ["spotty.sentinel": "delimiter-keep"]
                            ),
                            QueueProtocolTrack(
                                uri: "spotify:track:autoplay",
                                uid: "a0",
                                provider: "autoplay",
                                metadata: ["spotty.sentinel": "autoplay-keep"]
                            ),
                        ],
                        prev: [
                            QueueProtocolTrack(
                                uri: "spotify:track:prev",
                                uid: "p0",
                                provider: "context",
                                metadata: ["spotty.sentinel": "prev-keep"],
                                removed: ["removed-reason"]
                            )
                        ],
                        queueRevision: "rev-9"
                    )
                    let encoded = try JSONEncoder().encode(command)
                    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                    #expect((object?["endpoint"] as? String) == ("set_queue"), "set_queue endpoint is encoded")
                    #expect((object?["queue_revision"] as? String) == ("rev-9"), "set_queue revision is encoded")
                    let next = object?["next_tracks"] as? [[String: Any]]
                    #expect((next?.first?["uid"] as? String) == ("q0"), "next_tracks keeps remaining occurrence uid")
                    #expect((next?[1]["uri"] as? String) == ("spotify:delimiter"), "next_tracks keeps delimiter")
                    #expect((next?.last?["uri"] as? String) == ("spotify:track:autoplay"), "next_tracks keeps autoplay")
                    let prev = object?["prev_tracks"] as? [[String: Any]]
                    #expect((prev?.first?["uri"] as? String) == ("spotify:track:prev"), "prev_tracks are preserved")
                    #expect(
                        (jsonStringMap(next?.first?["metadata"])["spotty.sentinel"] ?? "") == ("keep-me"),
                        "incoming metadata is not synthesized")
                    #expect(
                        (jsonStringMap(next?.first?["metadata"])["is_queued"] ?? "") == ("true"),
                        "queued is_queued survives only when present on the snapshot")
                    #expect(
                        (jsonStringMap(next?[1]["metadata"])["spotty.sentinel"] ?? "") == ("delimiter-keep"),
                        "delimiter sentinel metadata survives encode")
                    #expect(
                        (jsonStringMap(next?.last?["metadata"])["spotty.sentinel"] ?? "") == ("autoplay-keep"),
                        "autoplay sentinel metadata survives encode")
                    #expect(
                        (jsonStringMap(prev?.first?["metadata"])["spotty.sentinel"] ?? "") == ("prev-keep"),
                        "prev_tracks sentinel metadata survives encode")
                    #expect(
                        (next?.first?["album_uri"] as? String) == ("spotify:album:fixture"),
                        "next_tracks encodes album_uri"
                    )
                    #expect(
                        (next?.first?["artist_uri"] as? String) == ("spotify:artist:fixture"),
                        "next_tracks encodes artist_uri")
                    #expect(
                        (prev?.first?["removed"] as? [String] ?? []) == (["removed-reason"]),
                        "prev_tracks encodes removed")

                } catch {
                    Issue.record(
                        "\("set_queue encodes remaining next_tracks and required prev_tracks"): unexpected error \(error)"
                    )
                }
            }
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            player.addToQueue(uris: ["spotify:track:one", "spotify:track:one", "spotify:track:two"])
            #expect((await waitUntil { await remote.sendCount == 3 }) == true, "ordered add finished")
            let endpoints = await remote.commands.map(\.endpoint)
            #expect(
                (endpoints) == ([.addToQueue, .addToQueue, .addToQueue]),
                "multi-add sends add_to_queue in visible order, including duplicate URIs")
            #expect((feedback.message?.text) == ("Added 3 songs to Queue"), "multi-add reports a batch success")
            #expect((player.transientCommandError) == (nil), "multi-add success is not a playback notice")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.failAfter(2))
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            let before = player.queueNextEntries
            player.addToQueue(uris: ["spotify:track:one", "spotify:track:two", "spotify:track:three"])
            #expect((await waitUntil { feedback.message?.kind == .informational }) == true, "partial add finished")
            #expect((await remote.sendCount) == (3), "two commands completed before failure")
            #expect(
                (feedback.message?.text) == ("Added 2 of 3 songs to Queue"),
                "partial add reports completed versus requested")
            #expect((player.queueNextEntries) == (before), "partial add does not rewrite presentation")
            await player.shutdownForTermination()

            let none = QueueRemoteClient(.fail)
            let noneFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let nonePlayer = PlaybackStore(environment: queueEnvironment(remote: none), feedback: noneFeedback)
            seedRemoteOwner(nonePlayer)
            nonePlayer.addToQueue(uris: ["spotify:track:one", "spotify:track:two"])
            #expect((await waitUntil { noneFeedback.message?.kind == .failure }) == true, "zero-success add finished")
            #expect(
                (noneFeedback.message?.text) == ("Could not add those tracks to the queue."),
                "zero completed commands keep the batch failure message")
            await nonePlayer.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let secondDuplicate = player.queueNextEntries[1].id
            let before = player.queueNextEntries
            #expect((before.map(\.occurrence)) == ([0, 1, 2]), "projection keeps typed upcoming occurrences")
            #expect((before.map(\.uid)) == (["q0", "q1", "q2"]), "projection keeps occurrence uids")
            player.removeUpcomingQueueOccurrences(selectedIDs: [secondDuplicate])
            #expect((await waitUntil { await remote.sendCount == 1 }) == true, "set_queue was sent")
            let command = await remote.commands.first
            #expect((command?.endpoint) == (.setQueue), "removal uses set_queue")
            #expect(
                (command?.nextTracks?.map(\.uid)) == (["q0", "q2", "", "a0"]),
                "removal keeps the first duplicate occurrence")
            #expect((command?.prevTracks?.map(\.uid)) == (["p0"]), "removal preserves prev_tracks")
            #expect((player.queueNextEntries) == (before), "success does not locally rewrite presentation")
            #expect((feedback.message?.text) == ("Removed from Queue"), "removal reports through transient feedback")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let upcoming = player.queueNextEntries
            #expect(
                (player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])) == true,
                "Delete is enabled for a complete remote upcoming selection")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 1,
                    isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])
                )) == (.removeUpcomingOccurrences), "keyboard routing matches enablement")
            player.removeUpcomingQueueOccurrences(selectedIDs: ["now-playing"])
            #expect(
                (feedback.message?.text) == (QueueMutationRefusal.nowPlayingOrHistory.feedbackMessage),
                "now-playing cannot be removed")
            #expect((await remote.sendCount) == (0), "now-playing refusal does not send a command")
            player.removeUpcomingQueueOccurrences(selectedIDs: Set(player.history.entries.map(\.id)))
            #expect((await remote.sendCount == 0) == true, "empty history selection is a no-op or not a mutation")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let id = player.queueNextEntries[0].id
            let before = player.queueNextEntries

            player.queueMutation?.completeness = .partial
            player.removeUpcomingQueueOccurrences(selectedIDs: [id])
            #expect(
                (feedback.message?.text) == (QueueMutationRefusal.incompleteProvenance.feedbackMessage),
                "partial provenance explains and does not mutate")
            #expect((player.queueNextEntries) == (before), "partial provenance leaves presentation intact")

            player.queueMutation?.completeness = .complete
            player.queueMutation?.disallowSetQueue = true
            player.removeUpcomingQueueOccurrences(selectedIDs: [id])
            #expect(
                (feedback.message?.text) == (QueueMutationRefusal.restricted.feedbackMessage),
                "restricted snapshots explain and do not mutate")

            let localFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let local = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: localFeedback)
            seedLocalOwner(local)
            await seedAuthoritativeQueue(local)
            let localID = local.queueNextEntries[0].id
            let localBefore = local.queueNextEntries
            local.removeUpcomingQueueOccurrences(selectedIDs: [localID])
            #expect(
                (localFeedback.message?.text) == (QueueMutationRefusal.localOwnerUnsupported.feedbackMessage),
                "local owner is disabled with a typed explanation")
            #expect((await remote.sendCount) == (0), "local owner does not send set_queue")
            #expect((local.queueNextEntries) == (localBefore), "local owner leaves presentation intact")
            await player.shutdownForTermination()
            await local.shutdownForTermination()
        }

        do {
            let failing = QueueRemoteClient(.fail)
            let failFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let rejected = PlaybackStore(environment: queueEnvironment(remote: failing), feedback: failFeedback)
            seedRemoteOwner(rejected)
            await seedAuthoritativeQueue(rejected)
            let rejectedID = rejected.queueNextEntries[0].id
            let rejectedBefore = rejected.queueNextEntries
            rejected.removeUpcomingQueueOccurrences(selectedIDs: [rejectedID])
            #expect((await waitUntil { failFeedback.message?.kind == .failure }) == true, "rejected set_queue finished")
            #expect((rejected.queueNextEntries) == (rejectedBefore), "rejection does not rewrite presentation")
            #expect(
                (failFeedback.message?.text) == ("Spotify couldn’t update the queue."),
                "rejection uses a typed queue failure")
            await rejected.shutdownForTermination()

            let parked = QueueRemoteClient(.park)
            let cancelFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let cancelled = PlaybackStore(environment: queueEnvironment(remote: parked), feedback: cancelFeedback)
            seedRemoteOwner(cancelled)
            await seedAuthoritativeQueue(cancelled)
            let cancelID = cancelled.queueNextEntries[0].id
            let cancelBefore = cancelled.queueNextEntries
            cancelled.removeUpcomingQueueOccurrences(selectedIDs: [cancelID])
            #expect((await waitUntil { await parked.sendCount == 1 }) == true, "cancelled removal started")
            cancelled.effects.cancelAccountScoped()
            await parked.completePark(success: false)
            await yieldPasses()
            #expect((cancelFeedback.message) == nil, "cancelled removal reports no mutation feedback")
            #expect((cancelled.queueNextEntries) == (cancelBefore), "cancelled removal does not locally edit")
            await cancelled.shutdownForTermination()

            let staleRemote = QueueRemoteClient(.park)
            let staleFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let stale = PlaybackStore(environment: queueEnvironment(remote: staleRemote), feedback: staleFeedback)
            seedRemoteOwner(stale)
            await seedAuthoritativeQueue(stale)
            let staleID = stale.queueNextEntries[0].id
            stale.removeUpcomingQueueOccurrences(selectedIDs: [staleID])
            #expect((await waitUntil { await staleRemote.sendCount == 1 }) == true, "stale-account removal started")
            stale.accountStore.advanceEpoch()
            await staleRemote.completePark(success: true)
            await yieldPasses()
            #expect((staleFeedback.message) == nil, "stale-account removal reports no mutation feedback")
            await stale.shutdownForTermination()

            let missingFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let missing = PlaybackStore(
                environment: queueEnvironment(remote: QueueRemoteClient(.succeed)), feedback: missingFeedback)
            seedRemoteOwner(missing)
            await seedAuthoritativeQueue(missing)
            let beforeMissing = missing.queueNextEntries
            missing.removeUpcomingQueueOccurrences(selectedIDs: ["0-missing-spotify:track:nope"])
            #expect(
                (missingFeedback.message?.text) == (QueueMutationRefusal.staleIdentities.feedbackMessage),
                "stale identities explain and do not mutate")
            #expect((missing.queueNextEntries) == (beforeMissing), "stale identities leave presentation intact")
            await missing.shutdownForTermination()
        }

        do {
            let parked = QueueRemoteClient(.park)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: parked), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let firstID = player.queueNextEntries[0].id
            let secondID = player.queueNextEntries[1].id
            let before = player.queueNextEntries
            player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
            #expect((await waitUntil { await parked.sendCount == 1 }) == true, "first replacement started")
            #expect(
                (!player.canRemoveUpcomingQueue(selectedIDs: [secondID])) == true,
                "an in-flight replacement disables further removal")
            #expect(
                (QueueMutationSelection.keyboardCommand(
                    deleteOrBackspace: true,
                    selectedUpcomingCount: 1,
                    isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [secondID])
                )) == nil, "keyboard Delete is gated while a replacement is in flight")
            invokeKeyboardQueueDelete(player: player, selectedIDs: [secondID])
            player.removeUpcomingQueueOccurrences(selectedIDs: [secondID])
            await yieldPasses()
            #expect((await parked.sendCount) == (1), "a second in-flight removal does not send another set_queue")
            #expect((feedback.message) == nil, "a second in-flight removal does not toast")
            #expect((player.queueNextEntries) == (before), "in-flight overlap does not edit presentation")
            await parked.completePark(success: true)
            #expect(
                (await waitUntil { feedback.message?.text == "Removed from Queue" }) == true,
                "the first replacement finished")
            #expect((player.queueReplacementToken) == nil, "a finished replacement releases the in-flight gate")
            #expect(
                (player.queueMutation?.next.map(\.uid)) == (["q1", "q2", "", "a0"]),
                "committed mutation excludes the occurrence Spotify already dropped")
            #expect(
                (!player.canRemoveUpcomingQueue(selectedIDs: [firstID])) == true,
                "stale visible selection cannot remove until Connect reconciles")
            player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
            #expect(
                (feedback.message?.text) == (QueueMutationRefusal.incompleteProvenance.feedbackMessage),
                "a follow-up from the stale visible list fails closed")
            #expect((await parked.sendCount) == (1), "fail-closed follow-up does not send another set_queue")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let before = player.queueNextEntries
            let mutationBefore = player.queueMutation
            player.apply(
                ProvenanceQueueSnapshot(
                    accountEpoch: player.accountEpoch,
                    revision: 80,
                    source: .webAPI,
                    completeness: .complete,
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_080),
                    contextURI: "spotify:track:now",
                    entries: [
                        QueueEntry(uri: "spotify:track:reordered", provider: "web-api", occurrence: 0),
                        QueueEntry(uri: "spotify:track:dup", provider: "web-api", occurrence: 1),
                    ],
                    tracks: [
                        CatalogTrack(
                            id: "spotify:track:dup",
                            uri: "spotify:track:dup",
                            title: "Web Title",
                            artist: "Web Artist",
                            album: "",
                            duration: 180,
                            artworkURL: nil,
                            addedAt: nil
                        )
                    ]
                ),
                engineEpoch: player.engineGeneration
            )
            #expect(
                (player.queueNextEntries.map(\.uri)) == (before.map(\.uri)),
                "Web refresh does not reorder Connect upcoming entries")
            #expect(
                (player.queueNextEntries.map(\.uid)) == (before.map(\.uid)),
                "Web refresh does not replace Connect occurrence uids")
            #expect(
                (player.queueMutation) == (mutationBefore), "Web refresh does not replace the Connect mutation snapshot"
            )
            #expect(
                (player.canRemoveUpcomingQueue(selectedIDs: [before[0].id])) == true,
                "Connect mutation still matches the visible upcoming list")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let hook = QueueServiceTestHook()
            let player = PlaybackStore(
                environment: queueEnvironment(remote: remote, queueServiceHook: hook),
                feedback: feedback
            )
            seedRemoteOwner(player)
            await player.queueService.reset(accountEpoch: player.accountEpoch)
            await hook.parkNextConnectAccept()
            player.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 2,
                    sessionGeneration: player.engineGeneration
                )
            )
            #expect(
                (await waitUntil { await hook.connectAcceptIsParked() }) == true,
                "Connect accept is parked after callback admission")
            #expect((player.connectQueueCallback.revision) == (2), "callback admission records its dedupe watermark")
            #expect(
                (player.queueInspectorOrderingVersion) == (0), "callback admission does not restart inspector hydration"
            )

            let staleEntry = QueueEntry(uri: "spotify:track:stale", provider: "queue", occurrence: 0)
            let staleTrack = CatalogTrack(
                id: staleEntry.uri,
                uri: staleEntry.uri,
                title: "Stale",
                artist: "Artist",
                album: "",
                duration: 180,
                artworkURL: nil,
                addedAt: nil
            )
            let fallback = await player.queueService.refresh(
                fallbackEntries: [staleEntry],
                cachedTracks: [staleTrack],
                currentTrackURI: player.trackURI,
                accountEpoch: player.accountEpoch
            )
            if let fallback {
                player.apply(fallback, engineEpoch: player.engineGeneration)
            }
            #expect(
                (player.queueNextEntries.map(\.uri)) == ([staleEntry.uri]),
                "parked fallback publishes its stale ordering")
            #expect(
                (player.queueInspectorOrderingVersion) == (0),
                "fallback projection does not restart inspector hydration")

            await hook.resumeConnectAccept()
            #expect(
                (await waitUntil { player.queueInspectorOrderingVersion == 1 }) == true,
                "accepted Connect ordering advances the inspector token")
            #expect(
                (player.queueNextEntries.map(\.uri)) == (["spotify:track:dup", "spotify:track:other"]),
                "accepted Connect ordering replaces the earlier fallback")

            let acceptedVersion = player.queueInspectorOrderingVersion
            player.receive(
                connectQueueEnvelope(
                    sequence: 2,
                    revision: 3,
                    sessionGeneration: player.engineGeneration
                )
            )
            #expect(
                (await waitUntil { player.queueMutation?.sourceRevision == 3 }) == true,
                "same-ordering Connect redelivery is applied")
            #expect(
                (player.queueInspectorOrderingVersion) == (acceptedVersion),
                "same accepted ordering does not restart inspector hydration")
            await player.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            await player.restore()
            seedRemoteOwner(player)
            let mirroredGeneration = player.engineGeneration
            let payloadGeneration = mirroredGeneration + 1
            #expect(
                (payloadGeneration > mirroredGeneration) == true,
                "queue can arrive before playback has adopted the payload generation")

            player.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 1,
                    sessionGeneration: payloadGeneration
                )
            )
            #expect(
                (await waitUntil { player.state.engineEpoch == payloadGeneration }) == true,
                "G+1 queue adopts reducer engine epoch from the payload")
            #expect(
                (player.engineGeneration) == (payloadGeneration), "G+1 queue presentation stamps the payload generation"
            )
            #expect(
                (player.state.currentTrack?.uri) == ("spotify:track:now"),
                "G+1 queue presentation keeps the payload track URI")
            #expect(
                (await waitUntil { player.state.currentTrack?.title == "Metadata" }) == true,
                "G+1 queue hydrates catalog names after URI-only identity")
            #expect(
                (await waitUntil { player.queueMutation?.engineEpoch == payloadGeneration }) == true,
                "G+1 queue mutation snapshot uses the payload generation")
            #expect(
                (player.queueMutation?.engineEpoch == mirroredGeneration) == (false),
                "G+1 queue does not leave mutation on the stale mirror")
            #expect(
                (player.connectQueueCallback.generation) == (payloadGeneration),
                "callback watermark records the payload generation")
            #expect((player.connectQueueCallback.revision) == (1), "callback watermark records the payload revision")

            let afterFirst = player.connectQueueCallback
            let mutationAfterFirst = player.queueMutation
            let trackAfterFirst = player.state.currentTrack
            player.receive(
                connectQueueEnvelope(
                    sequence: 2,
                    revision: 1,
                    sessionGeneration: payloadGeneration
                )
            )
            await yieldPasses()
            #expect(
                (player.connectQueueCallback) == (afterFirst),
                "identical redelivery does not advance the callback watermark")
            #expect(
                (player.queueMutation) == (mutationAfterFirst),
                "identical redelivery does not replace mutation identity")
            #expect(
                (player.state.currentTrack) == (trackAfterFirst),
                "identical redelivery does not replace now-playing identity")

            player.receive(
                connectQueueEnvelope(
                    sequence: 3,
                    revision: 2,
                    sessionGeneration: mirroredGeneration
                )
            )
            await yieldPasses()
            #expect(
                (player.connectQueueCallback) == (afterFirst),
                "a stale generation does not advance the callback watermark")
            #expect(
                (player.queueMutation) == (mutationAfterFirst), "a stale generation does not replace mutation identity")
            #expect(
                (player.state.currentTrack) == (trackAfterFirst),
                "a stale generation does not replace now-playing identity"
            )
            await player.shutdownForTermination()

            let teardownFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let teardown = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: teardownFeedback)
            await teardown.restore()
            seedRemoteOwner(teardown)
            let teardownMirror = teardown.engineGeneration
            teardown.isTearingDown = true
            teardown.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 1,
                    sessionGeneration: teardownMirror + 1
                )
            )
            await yieldPasses()
            #expect(
                (teardown.state.engineEpoch) == (0), "teardown queue intake does not adopt the payload engine epoch")
            #expect((teardown.queueMutation) == nil, "teardown queue intake does not install mutation")
            #expect((teardown.state.currentTrack) == nil, "teardown queue intake does not install now-playing")
            #expect(
                (teardown.connectQueueCallback.generation) == (0),
                "teardown queue intake does not record callback identity"
            )
            await teardown.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let hook = QueueServiceTestHook()
            let player = PlaybackStore(
                environment: queueEnvironment(remote: remote, queueServiceHook: hook),
                feedback: feedback
            )
            seedRemoteOwner(player)
            await player.queueService.reset(accountEpoch: player.accountEpoch)
            await hook.parkNextConnectAccept()
            player.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 1,
                    sessionGeneration: player.engineGeneration
                )
            )
            #expect(
                (await waitUntil { await hook.connectAcceptIsParked() }) == true,
                "connect accept parked after actor hop")
            player.accountStore.advanceEpoch()
            player.engineGeneration &+= 1
            player.queueMutation = nil
            await hook.resumeConnectAccept()
            await yieldPasses()
            #expect(
                (player.queueMutation) == nil, "account and engine invalidation after accept does not restore mutation")
            #expect((player.queueNextEntries.isEmpty) == true, "invalidated accept does not populate presentation")

            await player.queueService.reset(accountEpoch: player.accountEpoch)
            await hook.parkNextConnectAccept()
            player.receive(
                connectQueueEnvelope(
                    sequence: 2,
                    revision: 2,
                    sessionGeneration: player.engineGeneration
                )
            )
            #expect((await waitUntil { await hook.connectAcceptIsParked() }) == true, "teardown accept parked")
            player.isTearingDown = true
            player.queueMutation = nil
            player.effects.cancelAccountScoped()
            await yieldPasses(20)
            #expect((player.queueMutation) == nil, "cancelled teardown accept does not restore mutation")
            await player.shutdownForTermination()
        }

        do {
            let parked = QueueRemoteClient(.park)
            let replacementFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let replacement = PlaybackStore(
                environment: queueEnvironment(remote: parked),
                feedback: replacementFeedback
            )
            seedRemoteOwner(replacement)
            await seedAuthoritativeQueue(replacement)
            let removalID = replacement.queueNextEntries[0].id
            replacement.removeUpcomingQueueOccurrences(selectedIDs: [removalID])
            #expect((await waitUntil { await parked.sendCount == 1 }) == true, "parked replacement started")
            replacement.cancelQueueRefresh()
            await yieldPasses()
            #expect((await parked.sendCount) == (1), "closing the inspector does not cancel set_queue")
            #expect((replacementFeedback.message) == nil, "inspector close does not toast a cancelled replacement")
            await parked.completePark(success: true)
            #expect(
                (await waitUntil { replacementFeedback.message?.text == "Removed from Queue" }) == true,
                "replacement still completes after inspector close")
            #expect(
                (replacement.queueMutation?.next.map(\.uid)) == (["q1", "q2", "", "a0"]),
                "inspector close did not drop the committed mutation")
            await replacement.shutdownForTermination()

            let acceptFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let acceptHook = QueueServiceTestHook()
            let accept = PlaybackStore(
                environment: queueEnvironment(remote: QueueRemoteClient(.succeed), queueServiceHook: acceptHook),
                feedback: acceptFeedback
            )
            seedRemoteOwner(accept)
            await accept.queueService.reset(accountEpoch: accept.accountEpoch)
            await acceptHook.parkNextConnectAccept()
            accept.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 1,
                    sessionGeneration: accept.engineGeneration
                )
            )
            #expect(
                (await waitUntil { await acceptHook.connectAcceptIsParked() }) == true,
                "connect accept parked before inspector close")
            accept.cancelQueueRefresh()
            await yieldPasses()
            #expect(
                (await acceptHook.connectAcceptIsParked()) == true,
                "closing the inspector does not cancel Connect intake")
            await acceptHook.resumeConnectAccept()
            #expect(
                (await waitUntil { accept.queueMutation?.next.map(\.uid) == ["q0", "q2"] }) == true,
                "Connect accept still applies after inspector close")
            await accept.shutdownForTermination()

            let teardownRemote = QueueRemoteClient(.park)
            let teardownFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let teardownHook = QueueServiceTestHook()
            let teardown = PlaybackStore(
                environment: queueEnvironment(remote: teardownRemote, queueServiceHook: teardownHook),
                feedback: teardownFeedback
            )
            seedRemoteOwner(teardown)
            await seedAuthoritativeQueue(teardown)
            teardown.removeUpcomingQueueOccurrences(selectedIDs: [teardown.queueNextEntries[0].id])
            #expect((await waitUntil { await teardownRemote.sendCount == 1 }) == true, "teardown replacement started")
            await teardownHook.parkNextConnectAccept()
            teardown.receive(
                connectQueueEnvelope(
                    sequence: 1,
                    revision: 8,
                    sessionGeneration: teardown.engineGeneration
                )
            )
            #expect((await waitUntil { await teardownHook.connectAcceptIsParked() }) == true, "teardown accept parked")
            teardown.queueMutation = nil
            teardown.effects.cancelAccountScoped()
            await yieldPasses(20)
            #expect((teardownFeedback.message) == nil, "account teardown cancels replacement feedback")
            await teardownRemote.completePark(success: true)
            await yieldPasses()
            #expect(
                (teardown.queueMutation) == nil,
                "account teardown does not restore replacement mutation from a cancelled task")
            await teardown.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let epochFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let epochHook = QueueServiceTestHook()
            let epochPlayer = PlaybackStore(
                environment: queueEnvironment(remote: remote, queueServiceHook: epochHook),
                feedback: epochFeedback
            )
            seedRemoteOwner(epochPlayer)
            await seedAuthoritativeQueue(epochPlayer)
            await epochHook.parkNextCommittedReplacement()
            epochPlayer.removeUpcomingQueueOccurrences(selectedIDs: [epochPlayer.queueNextEntries[0].id])
            #expect((await waitUntil { await remote.sendCount == 1 }) == true, "set_queue reached the remote")
            #expect(
                (await waitUntil { await epochHook.committedReplacementIsParked() }) == true,
                "committed replacement parked after the actor hop")
            epochPlayer.accountStore.advanceEpoch()
            epochPlayer.engineGeneration &+= 1
            epochPlayer.queueMutation = nil
            await epochHook.resumeCommittedReplacement()
            await yieldPasses()
            #expect((epochPlayer.queueMutation) == nil, "epoch invalidation after commit hop does not restore mutation")
            #expect((epochFeedback.message) == nil, "epoch invalidation after commit hop does not toast success")
            await epochPlayer.shutdownForTermination()

            let cancelRemote = QueueRemoteClient(.succeed)
            let cancelFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let cancelHook = QueueServiceTestHook()
            let cancelPlayer = PlaybackStore(
                environment: queueEnvironment(remote: cancelRemote, queueServiceHook: cancelHook),
                feedback: cancelFeedback
            )
            seedRemoteOwner(cancelPlayer)
            await seedAuthoritativeQueue(cancelPlayer)
            await cancelHook.parkNextCommittedReplacement()
            cancelPlayer.removeUpcomingQueueOccurrences(selectedIDs: [cancelPlayer.queueNextEntries[0].id])
            #expect(
                (await waitUntil { await cancelHook.committedReplacementIsParked() }) == true,
                "cancelled committed replacement parked")
            cancelPlayer.queueMutation = nil
            cancelPlayer.effects.cancelAccountScoped()
            await yieldPasses(20)
            #expect((cancelPlayer.queueMutation) == nil, "cancelled committed replacement does not restore mutation")
            #expect((cancelFeedback.message) == nil, "cancelled committed replacement does not toast")
            #expect(
                (cancelPlayer.queueReplacementToken) == nil,
                "cancelled committed replacement releases the in-flight gate")
            await cancelPlayer.shutdownForTermination()
        }

        do {
            let remote = QueueRemoteClient(.succeed)
            let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
            seedRemoteOwner(player)
            await seedAuthoritativeQueue(player)
            let allowedID = player.queueNextEntries[0].id
            invokeKeyboardQueueDelete(player: player, selectedIDs: [allowedID])
            #expect(
                (await waitUntil { await remote.sendCount == 1 }) == true, "allowed keyboard Delete sends set_queue")

            invokeKeyboardQueueDelete(player: player, selectedIDs: [])
            #expect((await remote.sendCount) == (1), "empty keyboard selection does not send another command")

            player.queueMutation?.disallowSetQueue = true
            let restrictedBefore = feedback.message?.text
            invokeKeyboardQueueDelete(player: player, selectedIDs: [player.queueNextEntries[1].id])
            #expect((await remote.sendCount) == (1), "restricted keyboard Delete does not send set_queue")
            #expect((feedback.message?.text) == (restrictedBefore), "restricted keyboard Delete does not toast")
            await player.shutdownForTermination()

            let localFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
            let local = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: localFeedback)
            seedLocalOwner(local)
            await seedAuthoritativeQueue(local)
            invokeKeyboardQueueDelete(player: local, selectedIDs: [local.queueNextEntries[0].id])
            #expect((await remote.sendCount) == (1), "local-owner keyboard Delete does not send set_queue")
            #expect((localFeedback.message) == nil, "local-owner keyboard Delete does not toast")
            await local.shutdownForTermination()
        }

        do {
            let service = isolatedQueueService()
            await service.reset(accountEpoch: 1)
            let accepted = await service.acceptConnect(
                [connectEntry("spotify:track:a")],
                accountEpoch: 1,
                sourceRevision: 1,
                contextURI: "spotify:track:now",
                engineEpoch: 7,
                protocolNext: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
                queueRevision: "rev-1"
            )
            #expect((accepted?.snapshot.revision) == (1), "nil hook acceptConnect returns the Connect revision")
            let committed = await service.recordCommittedReplacement(
                QueueReplacement(
                    next: [QueueProtocolTrack(uri: "spotify:track:b", uid: "q1", provider: "queue")],
                    prev: [],
                    queueRevision: "rev-2",
                    removedCount: 1
                ),
                accountEpoch: 1,
                engineEpoch: 7
            )
            #expect((committed?.next.first?.uid) == ("q1"), "nil hook recordCommittedReplacement updates protocol next")

            let acceptHook = QueueServiceTestHook()
            let acceptService = isolatedQueueService(hook: acceptHook)
            await acceptService.reset(accountEpoch: 1)
            await acceptHook.parkNextConnectAccept()
            let acceptTask = Task {
                await acceptService.acceptConnect(
                    [connectEntry("spotify:track:parked")],
                    accountEpoch: 1,
                    sourceRevision: 4,
                    contextURI: "spotify:track:now"
                )
            }
            let acceptParked = await waitUntil { await acceptHook.connectAcceptIsParked() }
            #expect((acceptParked) == true, "acceptConnect parks")
            if acceptParked {
                await acceptHook.resumeConnectAccept()
                await acceptHook.resumeConnectAccept()
                #expect(((await acceptTask.value)?.snapshot.revision) == (4), "acceptConnect applies after one resume")
                #expect((await acceptHook.connectAcceptIsParked()) == (false), "a second acceptConnect resume is inert")
            }

            await acceptHook.parkNextConnectAccept()
            let cancelledTask = Task {
                await acceptService.acceptConnect(
                    [connectEntry("spotify:track:cancel")],
                    accountEpoch: 1,
                    sourceRevision: 5,
                    contextURI: nil
                )
            }
            #expect(
                (await waitUntil { await acceptHook.connectAcceptIsParked() }) == true,
                "cancellable acceptConnect parks")
            cancelledTask.cancel()
            let acceptReleased = await waitUntil { await acceptHook.connectAcceptIsParked() == false }
            #expect((acceptReleased) == true, "cancellation does not leak an acceptConnect continuation")
            if acceptReleased {
                #expect((await cancelledTask.value) == nil, "cancelled parked acceptConnect does not apply")
            }

            let replaceHook = QueueServiceTestHook()
            let replaceService = isolatedQueueService(hook: replaceHook)
            await replaceService.reset(accountEpoch: 1)
            _ = await replaceService.acceptConnect(
                [connectEntry("spotify:track:a")],
                accountEpoch: 1,
                sourceRevision: 1,
                contextURI: nil,
                engineEpoch: 3,
                protocolNext: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
                queueRevision: "rev-1"
            )
            await replaceHook.parkNextCommittedReplacement()
            let replaceTask = Task {
                await replaceService.recordCommittedReplacement(
                    QueueReplacement(
                        next: [QueueProtocolTrack(uri: "spotify:track:b", uid: "q1", provider: "queue")],
                        prev: [],
                        queueRevision: "rev-2",
                        removedCount: 1
                    ),
                    accountEpoch: 1,
                    engineEpoch: 3
                )
            }
            #expect(
                (await waitUntil { await replaceHook.committedReplacementIsParked() }) == true,
                "recordCommittedReplacement parks")
            await replaceHook.resumeCommittedReplacement()
            await replaceHook.resumeCommittedReplacement()
            #expect(
                ((await replaceTask.value)?.next.first?.uid) == ("q1"),
                "recordCommittedReplacement commits after one resume")
            #expect(
                (await replaceHook.committedReplacementIsParked()) == (false), "a second replacement resume is inert")
        }

    }
}

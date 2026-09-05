import SpottyDomain
import Foundation
import OSLog

nonisolated struct ProvenanceQueueSnapshot: Sendable {
    let accountEpoch: UInt64
    let revision: UInt64
    let source: PlaybackQueueSource
    let completeness: PlaybackQueueCompleteness
    let receivedAt: Date
    let contextURI: String?
    let entries: [QueueEntry]
    let tracks: [CatalogTrack]
}

/// Pure precedence policy. A lower-quality or older snapshot cannot erase a more authoritative
/// queue; metadata from either snapshot can still enrich the retained ordering. Complete Connect
/// occurrence order wins over same-context Web API entry lists.
nonisolated func mergeQueueSnapshots(
    current: ProvenanceQueueSnapshot?,
    incoming: ProvenanceQueueSnapshot
) -> ProvenanceQueueSnapshot {
    guard let current, current.accountEpoch == incoming.accountEpoch else { return incoming }
    let ordering = mergePlaybackQueueSnapshots(
        current: current.domainSnapshot,
        incoming: incoming.domainSnapshot
    )
    var retainedURIs = Set(ordering.entries.map(\.uri))
    if let contextURI = ordering.contextURI { retainedURIs.insert(contextURI) }
    let metadata = Dictionary(
        (current.tracks + incoming.tracks)
            .lazy
            .filter { retainedURIs.contains($0.uri) }
            .map { ($0.uri, $0) },
        uniquingKeysWith: { _, newer in newer }
    )
    return ProvenanceQueueSnapshot(
        accountEpoch: current.accountEpoch,
        revision: ordering.revision,
        source: ordering.source,
        completeness: ordering.completeness,
        receivedAt: ordering.receivedAt,
        contextURI: ordering.contextURI,
        entries: ordering.entries.enumerated().map { index, item in
            QueueEntry(
                uri: item.uri,
                provider: item.provider,
                occurrence: item.occurrence,
                uid: preservedQueueOccurrenceUID(incoming: item, index: index, current: current)
            )
        },
        tracks: Array(metadata.values)
    )
}

/// Web/metadata snapshots often arrive without Connect uids. When the URI at the same
/// upcoming index still matches, keep the authoritative occurrence uid so selection
/// identity does not fall back to a lossy index/URI id.
private nonisolated func preservedQueueOccurrenceUID(
    incoming: PlaybackQueueItem,
    index: Int,
    current: ProvenanceQueueSnapshot
) -> String {
    if !incoming.uid.isEmpty { return incoming.uid }
    guard current.entries.indices.contains(index),
        current.entries[index].uri == incoming.uri
    else {
        return ""
    }
    return current.entries[index].uid
}

private extension ProvenanceQueueSnapshot {
    var domainSnapshot: PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            entries: entries.map { PlaybackQueueItem($0) },
            source: source,
            completeness: completeness,
            revision: revision,
            receivedAt: receivedAt,
            contextURI: contextURI
        )
    }
}

nonisolated struct AcceptedConnectQueue: Sendable {
    let snapshot: ProvenanceQueueSnapshot
    let mutation: QueueMutationSnapshot
}

/// Optional suspension points around reset, `acceptConnect`, and `recordCommittedReplacement`.
/// Production stores `nil` and does not `await`. Checks inject `QueueServiceTestHook`.
protocol QueueServiceHook: Sendable {
    func beforeReset() async
    func beforeAcceptConnect() async
    func beforeRecordCommittedReplacement() async
}

actor QueueService {
    private enum WebCapability {
        case unknown
        case available
        case unavailable
    }

    private let webQueue: any WebQueueClient
    private let metadata: TrackMetadataService
    private let clock: any PlaybackClock
    private let hook: (any QueueServiceHook)?
    private(set) var accountEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var lastConnectSourceRevision: UInt64 = 0
    private var contextURI: String?
    private var webCapability = WebCapability.unknown
    private var webRetryNotBefore: Date?
    private var snapshot: ProvenanceQueueSnapshot?
    private var mutation: QueueMutationSnapshot?

    init(
        webQueue: any WebQueueClient,
        metadata: TrackMetadataService,
        clock: any PlaybackClock = SystemPlaybackClock(),
        hook: (any QueueServiceHook)? = nil
    ) {
        self.webQueue = webQueue
        self.metadata = metadata
        self.clock = clock
        self.hook = hook
    }

    func reset(accountEpoch: UInt64) async {
        if let hook {
            await hook.beforeReset()
        }
        guard !Task.isCancelled else { return }
        self.accountEpoch = accountEpoch
        revision = 0
        lastConnectSourceRevision = 0
        contextURI = nil
        webCapability = .unknown
        webRetryNotBefore = nil
        snapshot = nil
        mutation = nil
        await metadata.reset()
    }

    func mutationSnapshot() -> QueueMutationSnapshot? { mutation }

    func recordCommittedReplacement(
        _ replacement: QueueReplacement,
        accountEpoch requestedEpoch: UInt64,
        engineEpoch: UInt64
    ) async -> QueueMutationSnapshot? {
        if let hook {
            // Production stores nil, so this await is check-only and does not hop the live actor.
            await hook.beforeRecordCommittedReplacement()
        }
        guard !Task.isCancelled else { return nil }
        guard requestedEpoch == accountEpoch else { return nil }
        guard var current = mutation, current.engineEpoch == engineEpoch else { return nil }
        current.next = replacement.next
        current.prev = replacement.prev
        current.queueRevision = replacement.queueRevision
        mutation = current
        return mutation
    }

    func acceptConnect(
        _ entries: [QueueEntry],
        accountEpoch requestedEpoch: UInt64,
        sourceRevision: UInt64? = nil,
        contextURI incomingContextURI: String?,
        provisional: Bool = false,
        engineEpoch: UInt64 = 0,
        protocolNext: [QueueProtocolTrack] = [],
        protocolPrev: [QueueProtocolTrack] = [],
        queueRevision: String = "",
        disallowSetQueue: Bool = false,
        disallowRemovingFromNextTracks: Bool = false
    ) async -> AcceptedConnectQueue? {
        if let hook {
            // Production stores nil, so this await is check-only and does not hop the live actor.
            await hook.beforeAcceptConnect()
        }
        guard !Task.isCancelled else { return nil }
        guard requestedEpoch == accountEpoch else { return nil }
        if let sourceRevision {
            guard sourceRevision > lastConnectSourceRevision else { return acceptedQueue() }
            lastConnectSourceRevision = sourceRevision
            revision = max(revision, sourceRevision)
        } else {
            revision &+= 1
        }
        contextURI = incomingContextURI
        let incoming = ProvenanceQueueSnapshot(
            accountEpoch: accountEpoch,
            revision: revision,
            source: provisional ? .provisional : .connect,
            completeness: entries.isEmpty && provisional ? .partial : .complete,
            receivedAt: clock.now(),
            contextURI: incomingContextURI,
            entries: entries,
            tracks: []
        )
        snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
        mutation = QueueMutationSnapshot(
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            sourceRevision: sourceRevision ?? revision,
            source: provisional ? .provisional : .connect,
            completeness: protocolNext.isEmpty && !entries.isEmpty ? .partial : (provisional ? .partial : .complete),
            provisional: provisional,
            next: protocolNext,
            prev: protocolPrev,
            queueRevision: queueRevision,
            disallowSetQueue: disallowSetQueue,
            disallowRemovingFromNextTracks: disallowRemovingFromNextTracks
        )
        return acceptedQueue()
    }

    func refresh(
        fallbackEntries: [QueueEntry],
        cachedTracks: [CatalogTrack] = [],
        currentTrackURI: String?,
        accountEpoch requestedEpoch: UInt64,
        onUpdate: @escaping @MainActor @Sendable (ProvenanceQueueSnapshot) async -> Void = { _ in }
    ) async -> ProvenanceQueueSnapshot? {
        let interval = SpottyLog.queueSignposter.beginInterval("Queue refresh")
        defer { SpottyLog.queueSignposter.endInterval("Queue refresh", interval) }
        guard requestedEpoch == accountEpoch else { return nil }
        contextURI = currentTrackURI
        let requestedContext = currentTrackURI

        if shouldRequestWebQueue {
            do {
                let tracks = try await webQueue.queue()
                guard requestedEpoch == accountEpoch, requestedContext == contextURI else { return nil }
                webCapability = .available
                webRetryNotBefore = nil
                revision &+= 1
                let incoming = ProvenanceQueueSnapshot(
                    accountEpoch: accountEpoch,
                    revision: revision,
                    source: .webAPI,
                    completeness: .complete,
                    receivedAt: clock.now(),
                    contextURI: requestedContext,
                    entries: tracks.enumerated().map {
                        QueueEntry(uri: $0.element.uri, provider: "web-api", occurrence: $0.offset)
                    },
                    tracks: tracks
                )
                snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
                SpottyLog.queue.info(
                    "Queue refreshed from Web API; entries=\(tracks.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
                )
                if let snapshot { await onUpdate(snapshot) }
                return snapshot
            } catch let error as SpotifyWebPlayerAPIError {
                let status = error.statusCode
                if [401, 403].contains(status ?? 0) {
                    webCapability = .unavailable
                } else if status == 429 {
                    // The desktop-client grant is commonly rate-limited at this documented Web
                    // endpoint. Fall back immediately, then avoid hammering it every time the
                    // inspector opens; a new account resets the cooldown.
                    webRetryNotBefore = clock.now().addingTimeInterval(5 * 60)
                }
                debugLog(
                    "QueueService",
                    "Web queue unavailable; HTTP=\(status.map(String.init) ?? "unknown"); using Connect fallback"
                )
            } catch {
                debugLog(
                    "QueueService",
                    "Web queue unavailable; error=\(String(describing: type(of: error))); using Connect fallback"
                )
            }
        }

        guard !Task.isCancelled, requestedEpoch == accountEpoch, requestedContext == contextURI else { return nil }
        let fallbackEntries = acceptedConnectOrdering(for: requestedContext)?.entries ?? fallbackEntries
        let wantedURIs = uniqueTrackURIs(in: fallbackEntries)
        let wantedSet = Set(wantedURIs)
        var hydrated = Dictionary(
            cachedTracks.lazy.filter { wantedSet.contains($0.uri) }.map { ($0.uri, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        guard
            let initial = updateFallbackSnapshot(
                entries: fallbackEntries,
                tracks: Array(hydrated.values),
                requestedEpoch: requestedEpoch,
                requestedContext: requestedContext
            )
        else { return nil }
        SpottyLog.queue.info(
            "Queue fallback started; entries=\(fallbackEntries.count, privacy: .public); cached=\(hydrated.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
        )
        await onUpdate(initial)

        let missing = wantedURIs.filter { hydrated[$0] == nil }
        guard !missing.isEmpty else { return snapshot }
        let hydrationInterval = SpottyLog.queueSignposter.beginInterval("Queue metadata hydration")
        defer { SpottyLog.queueSignposter.endInterval("Queue metadata hydration", hydrationInterval) }
        let maximumConcurrentRequests = 8
        await withTaskGroup(of: SpotifyConnectTrackMetadata?.self) { group in
            var pending = missing
            var scheduled = Set(missing)
            var nextRequest = 0
            for _ in 0..<min(maximumConcurrentRequests, missing.count) {
                let uri = pending[nextRequest]
                nextRequest += 1
                group.addTask { [metadata] in try? await metadata.metadata(for: uri) }
            }

            while let value = await group.next() {
                guard !Task.isCancelled,
                    requestedEpoch == accountEpoch,
                    requestedContext == contextURI
                else {
                    group.cancelAll()
                    return
                }
                if let value {
                    hydrated[value.uri] = Self.catalogTrack(from: value)
                    if let update = updateFallbackSnapshot(
                        entries: fallbackEntries,
                        tracks: Array(hydrated.values),
                        requestedEpoch: requestedEpoch,
                        requestedContext: requestedContext
                    ) {
                        await onUpdate(update)
                    }
                }
                let latestEntries = acceptedConnectOrdering(for: requestedContext)?.entries ?? fallbackEntries
                for uri in uniqueTrackURIs(in: latestEntries)
                where hydrated[uri] == nil && scheduled.insert(uri).inserted {
                    pending.append(uri)
                }
                if nextRequest < pending.count {
                    let uri = pending[nextRequest]
                    nextRequest += 1
                    group.addTask { [metadata] in try? await metadata.metadata(for: uri) }
                }
            }
        }
        SpottyLog.queue.info(
            "Queue fallback finished; hydrated=\(hydrated.count, privacy: .public)/\(wantedURIs.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
        )
        return snapshot
    }

    private func acceptedQueue() -> AcceptedConnectQueue? {
        guard let snapshot, let mutation else { return nil }
        return AcceptedConnectQueue(snapshot: snapshot, mutation: mutation)
    }

    private func uniqueTrackURIs(in entries: [QueueEntry]) -> [String] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard entry.uri.hasPrefix("spotify:track:"), seen.insert(entry.uri).inserted else {
                return nil
            }
            return entry.uri
        }
    }

    private func acceptedConnectOrdering(for context: String?) -> ProvenanceQueueSnapshot? {
        guard let mutation, !mutation.provisional,
            let snapshot, snapshot.source == .connect, snapshot.contextURI == context
        else { return nil }
        return snapshot
    }

    private func updateFallbackSnapshot(
        entries: [QueueEntry],
        tracks: [CatalogTrack],
        requestedEpoch: UInt64,
        requestedContext: String?
    ) -> ProvenanceQueueSnapshot? {
        guard !Task.isCancelled, requestedEpoch == accountEpoch, requestedContext == contextURI else { return nil }
        // Hydration can finish after a newer Connect event. It enriches metadata, not ordering.
        let ordering = acceptedConnectOrdering(for: requestedContext)
        let currentEntries = ordering?.entries ?? entries
        let knownURIs = Set(tracks.map(\.uri)).union(ordering?.tracks.map(\.uri) ?? [])
        let isHydrated = uniqueTrackURIs(in: currentEntries).allSatisfy { knownURIs.contains($0) }
        revision &+= 1
        let incoming = ProvenanceQueueSnapshot(
            accountEpoch: accountEpoch,
            revision: revision,
            source: .connect,
            completeness: ordering?.completeness ?? (isHydrated ? .complete : .partial),
            receivedAt: clock.now(),
            contextURI: requestedContext,
            entries: ordering?.entries ?? entries,
            tracks: tracks
        )
        snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
        return snapshot
    }

    private static func catalogTrack(from metadata: SpotifyConnectTrackMetadata) -> CatalogTrack {
        CatalogTrack(
            id: metadata.uri,
            uri: metadata.uri,
            title: metadata.title,
            artist: metadata.artist,
            album: "",
            duration: metadata.duration,
            artworkURL: metadata.artworkURL,
            addedAt: nil,
            artists: metadata.artists
        )
    }

    private var shouldRequestWebQueue: Bool {
        guard webCapability != .unavailable else { return false }
        guard let webRetryNotBefore else { return true }
        return clock.now() >= webRetryNotBefore
    }
}

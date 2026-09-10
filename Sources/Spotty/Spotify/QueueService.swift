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

nonisolated struct QueueRefreshDiagnostics: Codable, Sendable {
    var starts = 0
    var joins = 0
    var cancellations = 0
    var publications = 0
    var metadataResults = 0
}

actor QueueService {
    private enum HydrationResult: Sendable {
        case metadata(SpotifyConnectTrackMetadata?)
        case flush
    }

    private(set) var refreshDiagnostics = QueueRefreshDiagnostics()
    private struct RefreshKey: Equatable, Sendable {
        let accountEpoch: UInt64
        let contextURI: String?
        let fallbackEntries: [QueueEntry]
        let cachedTracks: [CatalogTrack]
    }

    private final class RefreshSubscriber: @unchecked Sendable {
        let callback: @MainActor @Sendable (ProvenanceQueueSnapshot) async -> Void
        private let lock = NSLock()
        private var active = true
        private var completed = false
        private var result: ProvenanceQueueSnapshot?
        private var continuation: CheckedContinuation<ProvenanceQueueSnapshot?, Never>?

        init(callback: @escaping @MainActor @Sendable (ProvenanceQueueSnapshot) async -> Void) {
            self.callback = callback
        }

        func complete(_ result: ProvenanceQueueSnapshot?) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            active = false
            self.result = result
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: result)
        }

        func wait() async -> ProvenanceQueueSnapshot? {
            await withCheckedContinuation { waiting in
                lock.lock()
                if completed {
                    let result = result
                    lock.unlock()
                    waiting.resume(returning: result)
                } else {
                    continuation = waiting
                    lock.unlock()
                }
            }
        }

        private var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func invoke(_ snapshot: ProvenanceQueueSnapshot) async {
            guard isActive else { return }
            let invocation = Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                await self.callback(snapshot)
            }
            await invocation.value
        }
    }

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
    private var refreshFlightID: UUID?
    private var refreshFlightKey: RefreshKey?
    private var refreshTask: Task<Void, Never>?
    private var refreshSubscribers: [UUID: RefreshSubscriber] = [:]

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
        cancelRefreshFlight()
        if let hook {
            await hook.beforeReset()
        }
        guard !Task.isCancelled else { return }
        cancelRefreshFlight()
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
            // Metadata publications advance the presentation counter independently of the
            // engine's wire revision. Fresh ordering still needs a strictly newer presentation
            // revision or PlaybackStore will reject it as a duplicate after enrichment.
            revision = max(revision &+ 1, sourceRevision)
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
        guard requestedEpoch == accountEpoch else { return nil }
        let key = RefreshKey(
            accountEpoch: requestedEpoch,
            contextURI: currentTrackURI,
            fallbackEntries: fallbackEntries,
            cachedTracks: cachedTracks
        )
        if refreshFlightKey != key {
            cancelRefreshFlight()
        }

        let flightID: UUID
        if let existingID = refreshFlightID {
            refreshDiagnostics.joins += 1
            flightID = existingID
        } else {
            refreshDiagnostics.starts += 1
            let createdID = UUID()
            refreshFlightID = createdID
            refreshFlightKey = key
            refreshTask = Task { [weak self, flightID = createdID] in
                guard let self else { return }
                let result = await self.performRefresh(
                    fallbackEntries: fallbackEntries,
                    cachedTracks: cachedTracks,
                    currentTrackURI: currentTrackURI,
                    accountEpoch: requestedEpoch,
                    onUpdate: { [weak self] update in
                        await self?.publishRefreshUpdate(update, flightID: flightID)
                    }
                )
                await self.finishRefreshFlight(flightID, result: result)
            }
            flightID = createdID
        }

        let subscriberID = UUID()
        let subscriber = RefreshSubscriber(callback: onUpdate)
        refreshSubscribers[subscriberID] = subscriber
        return await withTaskCancellationHandler {
            let result = await subscriber.wait()
            removeRefreshSubscriber(subscriberID, flightID: flightID)
            return Task.isCancelled ? nil : result
        } onCancel: {
            // Cancellation settles this caller immediately; it does not wait for the shared
            // request or a hop back to QueueService before releasing the caller's effect.
            subscriber.complete(nil)
            Task { [weak self] in
                await self?.removeRefreshSubscriber(subscriberID, flightID: flightID)
            }
        }
    }

    private func performRefresh(
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
                guard !Task.isCancelled,
                    requestedEpoch == accountEpoch,
                    requestedContext == contextURI
                else { return nil }
                var fallbackCachedTracks = (snapshot?.tracks ?? []) + cachedTracks
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
                guard let ordering = acceptedConnectOrdering(for: requestedContext) else {
                    return snapshot
                }
                fallbackCachedTracks.append(contentsOf: tracks)
                let knownURIs = Set(snapshot?.tracks.map(\.uri) ?? [])
                guard !uniqueTrackURIs(in: ordering.entries).allSatisfy(knownURIs.contains) else {
                    return snapshot
                }
                return await performFallbackRefresh(
                    fallbackEntries: fallbackEntries,
                    cachedTracks: fallbackCachedTracks,
                    currentTrackURI: currentTrackURI,
                    requestedEpoch: requestedEpoch,
                    requestedContext: requestedContext,
                    onUpdate: onUpdate
                )
            } catch let error as SpotifyWebPlayerAPIError {
                guard !Task.isCancelled,
                    requestedEpoch == accountEpoch,
                    requestedContext == contextURI
                else { return nil }
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
                guard !Task.isCancelled,
                    requestedEpoch == accountEpoch,
                    requestedContext == contextURI
                else { return nil }
                debugLog(
                    "QueueService",
                    "Web queue unavailable; error=\(String(describing: type(of: error))); using Connect fallback"
                )
            }
        }

        return await performFallbackRefresh(
            fallbackEntries: fallbackEntries,
            cachedTracks: cachedTracks,
            currentTrackURI: currentTrackURI,
            requestedEpoch: requestedEpoch,
            requestedContext: requestedContext,
            onUpdate: onUpdate
        )
    }

    private func performFallbackRefresh(
        fallbackEntries: [QueueEntry],
        cachedTracks: [CatalogTrack],
        currentTrackURI: String?,
        requestedEpoch: UInt64,
        requestedContext: String?,
        onUpdate: @escaping @MainActor @Sendable (ProvenanceQueueSnapshot) async -> Void
    ) async -> ProvenanceQueueSnapshot? {
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
        await withTaskGroup(of: HydrationResult.self) { group in
            var pending = missing
            var scheduled = Set(missing)
            var nextRequest = 0
            var activeRequests = 0
            var needsPublication = false
            var flushScheduled = false
            for _ in 0..<min(maximumConcurrentRequests, missing.count) {
                let uri = pending[nextRequest]
                nextRequest += 1
                activeRequests += 1
                group.addTask { [metadata] in .metadata(try? await metadata.metadata(for: uri)) }
            }

            while let result = await group.next() {
                guard !Task.isCancelled,
                    requestedEpoch == accountEpoch,
                    requestedContext == contextURI
                else {
                    group.cancelAll()
                    return
                }
                switch result {
                case let .metadata(value):
                    activeRequests -= 1
                    if let value {
                        refreshDiagnostics.metadataResults += 1
                        hydrated[value.uri] = Self.catalogTrack(from: value)
                        needsPublication = true
                    }
                case .flush:
                    flushScheduled = false
                    if needsPublication,
                        let update = updateFallbackSnapshot(
                            entries: fallbackEntries,
                            tracks: Array(hydrated.values),
                            requestedEpoch: requestedEpoch,
                            requestedContext: requestedContext)
                    {
                        needsPublication = false
                        SpottyLog.queueSignposter.emitEvent("Queue metadata batch")
                        await onUpdate(update)
                    }
                }
                let latestEntries = acceptedConnectOrdering(for: requestedContext)?.entries ?? fallbackEntries
                for uri in uniqueTrackURIs(in: latestEntries)
                where hydrated[uri] == nil && scheduled.insert(uri).inserted {
                    pending.append(uri)
                }
                while activeRequests < maximumConcurrentRequests, nextRequest < pending.count {
                    let uri = pending[nextRequest]
                    nextRequest += 1
                    activeRequests += 1
                    group.addTask { [metadata] in .metadata(try? await metadata.metadata(for: uri)) }
                }
                // One short timer exists only while metadata awaits publication. Ordering was
                // published immediately above; this bounds enrichment to 20 batches per second
                // and flushes a partial batch even while the remaining network requests stall.
                if needsPublication && !flushScheduled {
                    flushScheduled = true
                    group.addTask { [clock] in
                        try? await clock.sleep(seconds: 0.05)
                        return .flush
                    }
                }
            }
        }
        SpottyLog.queue.info(
            "Queue fallback finished; hydrated=\(hydrated.count, privacy: .public)/\(wantedURIs.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
        )
        return snapshot
    }

    var refreshSubscriberCount: Int { refreshSubscribers.count }

    private func publishRefreshUpdate(_ snapshot: ProvenanceQueueSnapshot, flightID: UUID) async {
        guard refreshFlightID == flightID else { return }
        refreshDiagnostics.publications += 1
        for subscriberID in Array(refreshSubscribers.keys) {
            guard refreshFlightID == flightID,
                let subscriber = refreshSubscribers[subscriberID]
            else { return }
            await subscriber.invoke(snapshot)
        }
    }

    private func removeRefreshSubscriber(_ subscriberID: UUID, flightID: UUID) {
        refreshSubscribers.removeValue(forKey: subscriberID)?.complete(nil)
        guard refreshFlightID == flightID else { return }
        // Keep a detached flight alive for replacement callers with identical inputs. A changed
        // context or fallback invalidates it through RefreshKey instead of silently reusing the
        // first caller's captured inputs.
    }

    private func finishRefreshFlight(_ flightID: UUID, result: ProvenanceQueueSnapshot?) {
        guard refreshFlightID == flightID else { return }
        refreshFlightID = nil
        refreshFlightKey = nil
        refreshTask = nil
        refreshSubscribers.values.forEach { $0.complete(result) }
        refreshSubscribers.removeAll()
    }

    private func cancelRefreshFlight() {
        if refreshTask != nil { refreshDiagnostics.cancellations += 1 }
        refreshTask?.cancel()
        refreshFlightID = nil
        refreshFlightKey = nil
        refreshTask = nil
        refreshSubscribers.values.forEach { $0.complete(nil) }
        refreshSubscribers.removeAll()
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

import SpottyDiagnostics
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog
import Synchronization

nonisolated struct ProvenanceQueueSnapshot: Sendable {
    let accountEpoch: UInt64
    let revision: UInt64
    let source: PlaybackQueueSource
    let completeness: PlaybackQueueCompleteness
    let receivedAt: Date
    let contextURI: String?
    let entries: [QueueEntry]
    let tracks: [CatalogTrack]

    init(
        accountEpoch: UInt64, revision: UInt64, source: PlaybackQueueSource,
        completeness: PlaybackQueueCompleteness, receivedAt: Date, contextURI: String?,
        entries: [QueueEntry], tracks: [CatalogTrack]
    ) {
        self.accountEpoch = accountEpoch
        self.revision = revision
        self.source = source
        self.completeness = completeness
        self.receivedAt = receivedAt
        self.contextURI = contextURI
        self.entries = entries
        self.tracks = tracks
    }
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
        entries: ordering.entries,
        tracks: Array(metadata.values)
    )
}

private extension ProvenanceQueueSnapshot {
    var domainSnapshot: PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            entries: entries,
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
/// Only Debug builds dispatch these hooks. Release contains no hook suspension points.
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

    private final class RefreshSubscriber: Sendable {
        private enum State: Sendable {
            case waiting(CheckedContinuation<ProvenanceQueueSnapshot?, Never>?)
            case completed(ProvenanceQueueSnapshot?)
        }

        let callback: @SessionRuntimeActor @Sendable (ProvenanceQueueSnapshot) async -> Void
        private let state = Mutex(State.waiting(nil))

        init(callback: @escaping @SessionRuntimeActor @Sendable (ProvenanceQueueSnapshot) async -> Void) {
            self.callback = callback
        }

        func complete(_ result: ProvenanceQueueSnapshot?) {
            let waiting = state.withLock { state -> CheckedContinuation<ProvenanceQueueSnapshot?, Never>? in
                guard case let .waiting(continuation) = state else { return nil }
                state = .completed(result)
                return continuation
            }
            waiting?.resume(returning: result)
        }

        func wait() async -> ProvenanceQueueSnapshot? {
            await withCheckedContinuation { waiting in
                let result = state.withLock { state -> Result<ProvenanceQueueSnapshot?, Never>? in
                    switch state {
                    case .waiting:
                        state = .waiting(waiting)
                        return nil
                    case let .completed(result):
                        return .success(result)
                    }
                }
                if let result { waiting.resume(with: result) }
            }
        }

        private var isActive: Bool {
            state.withLock { state in
                if case .waiting = state { return true }
                return false
            }
        }

        func invoke(_ snapshot: ProvenanceQueueSnapshot) async {
            guard isActive else { return }
            let invocation = Task { @SessionRuntimeActor [weak self] in
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
    /// Identity, input, worker and callers enter and leave ownership together. An empty
    /// subscriber set is still useful work that a matching caller can rejoin.
    private struct RefreshFlight: Sendable {
        let id: UUID
        let key: RefreshKey
        let task: Task<Void, Never>
        var subscribers: [UUID: RefreshSubscriber] = [:]

        func complete(_ result: ProvenanceQueueSnapshot?) {
            subscribers.values.forEach { $0.complete(result) }
        }

        func cancel() {
            task.cancel()
            complete(nil)
        }
    }

    private var refreshFlight: RefreshFlight?

    #if DEBUG
        /// Capture while a dependency is parked. Joining this exact task survives slot reset
        /// and proves the worker finished its owner calls, unlike subscriber completion.
        var refreshWorkerTask: Task<Void, Never>? { refreshFlight?.task }
    #endif

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

    deinit {
        refreshFlight?.cancel()
    }

    func reset(accountEpoch requestedEpoch: UInt64) async {
        // A retired or already-cancelled caller cannot disturb the current account's flight.
        guard !Task.isCancelled, requestedEpoch >= accountEpoch else { return }
        cancelRefreshFlight()
        #if DEBUG
            if let hook {
                await hook.beforeReset()
            }
        #endif
        guard !Task.isCancelled, requestedEpoch >= accountEpoch else { return }
        cancelRefreshFlight()
        accountEpoch = requestedEpoch
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
        #if DEBUG
            if let hook {
                await hook.beforeRecordCommittedReplacement()
            }
        #endif
        guard !Task.isCancelled else { return nil }
        guard requestedEpoch == accountEpoch else { return nil }
        guard var current = mutation, current.engineEpoch == engineEpoch else { return nil }
        current.next = replacement.next
        current.prev = replacement.prev
        current.queueRevision = replacement.queueRevision
        mutation = current
        return mutation
    }

    /// Derive presentation and mutation provenance from one decoded observation. Callers cannot
    /// pair visible rows with another protocol ordering or substitute its revision/generation.
    func acceptConnect(
        _ observation: RustQueueState,
        accountEpoch requestedEpoch: UInt64,
        fallbackTrackURI: String?
    ) async -> AcceptedConnectQueue? {
        #if DEBUG
            if let hook {
                await hook.beforeAcceptConnect()
            }
        #endif
        guard !Task.isCancelled else { return nil }
        guard requestedEpoch == accountEpoch else { return nil }
        guard observation.revision > lastConnectSourceRevision else { return acceptedQueue() }
        lastConnectSourceRevision = observation.revision
        // Metadata publications advance the presentation counter independently of the
        // engine's wire revision. Fresh ordering still needs a strictly newer presentation
        // revision or PlaybackStore will reject it as a duplicate after enrichment.
        revision = max(revision &+ 1, observation.revision)
        let entries = QueueProtocolProjection.upcomingEntries(from: observation.protocolNextTracks)
        let provisional = observation.track == nil && entries.isEmpty
        let incomingContextURI = observation.track?.uri ?? fallbackTrackURI
        contextURI = incomingContextURI
        let incoming = ProvenanceQueueSnapshot(
            accountEpoch: accountEpoch,
            revision: revision,
            source: provisional ? .provisional : .connect,
            completeness: provisional ? .partial : .complete,
            receivedAt: clock.now(),
            contextURI: incomingContextURI,
            entries: entries,
            tracks: []
        )
        snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
        mutation = QueueMutationSnapshot(
            accountEpoch: accountEpoch,
            engineEpoch: observation.sessionGeneration,
            sourceRevision: observation.revision,
            source: provisional ? .provisional : .connect,
            completeness: provisional ? .partial : .complete,
            provisional: provisional,
            next: observation.protocolNextTracks,
            prev: observation.protocolPrevTracks,
            queueRevision: observation.queueRevision,
            disallowSetQueue: observation.disallowSetQueue,
            disallowRemovingFromNextTracks: observation.disallowRemovingFromNextTracks
        )
        return acceptedQueue()
    }

    func refresh(
        fallbackEntries: [QueueEntry],
        cachedTracks: [CatalogTrack] = [],
        currentTrackURI: String?,
        accountEpoch requestedEpoch: UInt64,
        onUpdate: @escaping @SessionRuntimeActor @Sendable (ProvenanceQueueSnapshot) async -> Void = { _ in }
    ) async -> ProvenanceQueueSnapshot? {
        guard !Task.isCancelled, requestedEpoch == accountEpoch else { return nil }
        let key = RefreshKey(
            accountEpoch: requestedEpoch,
            contextURI: currentTrackURI,
            fallbackEntries: fallbackEntries,
            cachedTracks: cachedTracks
        )
        if refreshFlight?.key != key {
            cancelRefreshFlight()
        }

        if refreshFlight != nil {
            refreshDiagnostics.joins += 1
        } else {
            refreshDiagnostics.starts += 1
            let createdID = UUID()
            let worker = RefreshWorker(
                owner: self, flightID: createdID, key: key, webQueue: webQueue, metadata: metadata, clock: clock)
            // Installation cannot suspend; the worker's actor entrance sees the whole flight.
            refreshFlight = RefreshFlight(id: createdID, key: key, task: Task { await worker.run() })
        }

        let subscriberID = UUID()
        let subscriber = RefreshSubscriber(callback: onUpdate)
        refreshFlight?.subscribers[subscriberID] = subscriber
        return await withTaskCancellationHandler {
            let result = await subscriber.wait()
            removeRefreshSubscriber(subscriberID)
            return Task.isCancelled ? nil : result
        } onCancel: {
            // Cancellation settles this caller immediately; it does not wait for the shared
            // request or a hop back to QueueService before releasing the caller's effect.
            subscriber.complete(nil)
            Task { [weak self] in
                await self?.removeRefreshSubscriber(subscriberID)
            }
        }
    }

    /// Only the worker waits on dependencies. Actor entrances commit or read current authority
    /// without suspension, so an ignored dependency cannot keep a discarded service alive.
    private struct RefreshWorker: Sendable {
        weak var owner: QueueService?
        let flightID: UUID
        let key: RefreshKey
        let webQueue: any WebQueueClient
        let metadata: TrackMetadataService
        let clock: any PlaybackClock

        func run() async {
            let interval = SpottyLog.queueSignposter.beginInterval("Queue refresh")
            defer { SpottyLog.queueSignposter.endInterval("Queue refresh", interval) }
            let result = await refresh()
            await owner?.finishRefreshFlight(flightID, key: key, result: result)
        }

        private func refresh() async -> ProvenanceQueueSnapshot? {
            guard let requestsWeb = await owner?.beginRefresh(flightID, key: key) else { return nil }
            var webResult: Result<[CatalogTrack], any Error>?
            if requestsWeb {
                do { webResult = .success(try await webQueue.queue()) } catch { webResult = .failure(error) }
            }
            guard let webPhase = await owner?.acceptWebResult(webResult, flightID: flightID, key: key) else {
                return nil
            }
            if let publication = webPhase.publication { await publish(publication) }
            // Publication can suspend while Connect changes. Decide hydration only afterwards.
            guard let plan = await owner?.prepareHydration(webPhase, flightID: flightID, key: key) else {
                return nil
            }
            switch plan {
            case let .finished(snapshot): return snapshot
            case let .hydrate(seed):
                await publish(seed.initial)
                await hydrate(seed)
                return await owner?.currentRefreshSnapshot(flightID, key: key)
            }
        }

        private func publish(_ snapshot: ProvenanceQueueSnapshot) async {
            guard let subscribers = await owner?.subscribersForPublication(flightID, key: key) else { return }
            // An entered callback finishes normally; removed subscribers skip invocation even
            // when an earlier callback suspended. No actor instance waits for either case.
            for subscriber in subscribers {
                guard await owner?.isCurrentRefresh(flightID, key: key) == true else { return }
                await subscriber.invoke(snapshot)
            }
        }

        private func hydrate(_ seed: HydrationSeed) async {
            // A new URI can arrive during the initial callback even when the original queue
            // needed no metadata. Read current ordering before deciding that work is complete.
            guard let entries = await owner?.hydrationEntries(flightID, key: key, baseline: seed.entries) else {
                return
            }
            let wantedURIs = QueueService.uniqueTrackURIs(in: entries)
            var hydrated = seed.hydrated
            let missing = wantedURIs.filter { hydrated[$0] == nil }
            guard !missing.isEmpty else { return }
            let interval = SpottyLog.queueSignposter.beginInterval("Queue metadata hydration")
            defer { SpottyLog.queueSignposter.endInterval("Queue metadata hydration", interval) }
            let maximumConcurrentRequests = 8
            await withTaskGroup(of: HydrationResult.self) { group in
                var pending = missing
                var scheduled = Set(missing)
                var scannedEntries = entries
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
                    var receivedMetadata = false
                    switch result {
                    case let .metadata(value):
                        activeRequests -= 1
                        if let value {
                            receivedMetadata = true
                            hydrated[value.uri] = QueueService.catalogTrack(from: value)
                            needsPublication = true
                        }
                    case .flush:
                        flushScheduled = false
                        if needsPublication {
                            guard
                                let update = await owner?.commitHydration(
                                    Array(hydrated.values), baseline: seed.entries, flightID: flightID, key: key)
                            else { group.cancelAll(); return }
                            needsPublication = false
                            SpottyLog.queueSignposter.emitEvent("Queue metadata batch")
                            await publish(update)
                        }
                    }
                    guard
                        let latestEntries = await owner?.hydrationEntries(
                            flightID, key: key, baseline: seed.entries, receivedMetadata: receivedMetadata)
                    else { group.cancelAll(); return }
                    if latestEntries != scannedEntries {
                        for uri in QueueService.uniqueTrackURIs(in: latestEntries)
                        where hydrated[uri] == nil && scheduled.insert(uri).inserted {
                            pending.append(uri)
                        }
                    }
                    // Retain the latest immutable array even for equal values, so later
                    // completions compare shared storage instead of rescanning the queue.
                    scannedEntries = latestEntries
                    while activeRequests < maximumConcurrentRequests, nextRequest < pending.count {
                        let uri = pending[nextRequest]
                        nextRequest += 1
                        activeRequests += 1
                        group.addTask { [metadata] in .metadata(try? await metadata.metadata(for: uri)) }
                    }
                    // At most one short timer while metadata awaits publication, including
                    // a partial batch when another network request remains stalled.
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
                "Queue fallback finished; hydrated=\(hydrated.count, privacy: .public)/\(wantedURIs.count, privacy: .public); epoch=\(key.accountEpoch, privacy: .public)"
            )
        }
    }

    private struct WebPhase {
        let publication: ProvenanceQueueSnapshot?
        let cachedTracks: [CatalogTrack]
    }

    private struct HydrationSeed {
        let initial: ProvenanceQueueSnapshot
        let entries: [QueueEntry]
        let hydrated: [String: CatalogTrack]
    }

    private enum HydrationPlan {
        case finished(ProvenanceQueueSnapshot?)
        case hydrate(HydrationSeed)
    }

    private func beginRefresh(_ flightID: UUID, key: RefreshKey) -> Bool? {
        guard !Task.isCancelled, refreshFlight?.id == flightID, accountEpoch == key.accountEpoch else { return nil }
        contextURI = key.contextURI
        return shouldRequestWebQueue
    }

    private func isCurrentRefresh(_ flightID: UUID, key: RefreshKey) -> Bool {
        !Task.isCancelled && refreshFlight?.id == flightID
            && accountEpoch == key.accountEpoch && contextURI == key.contextURI
    }

    private func acceptWebResult(
        _ result: Result<[CatalogTrack], any Error>?, flightID: UUID, key: RefreshKey
    ) -> WebPhase? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        switch result {
        case let .success(tracks):
            let cached = (snapshot?.tracks ?? []) + key.cachedTracks + tracks
            webCapability = .available
            webRetryNotBefore = nil
            revision &+= 1
            let incoming = ProvenanceQueueSnapshot(
                accountEpoch: accountEpoch, revision: revision, source: .webAPI, completeness: .complete,
                receivedAt: clock.now(), contextURI: key.contextURI,
                entries: tracks.enumerated().map {
                    QueueEntry(uri: $0.element.uri, provider: "web-api", occurrence: $0.offset)
                }, tracks: tracks)
            snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
            SpottyLog.queue.info(
                "Queue refreshed from Web API; entries=\(tracks.count, privacy: .public); epoch=\(key.accountEpoch, privacy: .public)"
            )
            return WebPhase(publication: snapshot, cachedTracks: cached)
        case let .failure(error as WebQueueFailure):
            let status = error.statusCode
            if [401, 403].contains(status ?? 0) {
                webCapability = .unavailable
            } else if status == 429 {
                // Avoid hammering a rate-limited endpoint when the inspector reopens.
                // A new account resets this cooldown; retired failures cannot establish it.
                webRetryNotBefore = clock.now().addingTimeInterval(5 * 60)
            }
            debugLog(
                "QueueService",
                "Web queue unavailable; HTTP=\(status.map(String.init) ?? "unknown"); using Connect fallback")
        case let .failure(error):
            debugLog(
                "QueueService",
                "Web queue unavailable; error=\(String(describing: type(of: error))); using Connect fallback")
        case nil: break
        }
        return WebPhase(publication: nil, cachedTracks: key.cachedTracks)
    }

    private func prepareHydration(_ web: WebPhase, flightID: UUID, key: RefreshKey) -> HydrationPlan? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        let ordering = acceptedConnectOrdering(for: key.contextURI)
        if web.publication != nil {
            guard let ordering else { return .finished(snapshot) }
            let knownURIs = Set(snapshot?.tracks.map(\.uri) ?? [])
            if Self.uniqueTrackURIs(in: ordering.entries).allSatisfy(knownURIs.contains) {
                return .finished(snapshot)
            }
        }
        let entries = ordering?.entries ?? key.fallbackEntries
        let wanted = Set(Self.uniqueTrackURIs(in: entries))
        let hydrated = Dictionary(
            web.cachedTracks.lazy.filter { wanted.contains($0.uri) }.map { ($0.uri, $0) },
            uniquingKeysWith: { _, newer in newer })
        guard let initial = commitHydration(Array(hydrated.values), baseline: entries, flightID: flightID, key: key)
        else {
            return nil
        }
        SpottyLog.queue.info(
            "Queue fallback started; entries=\(entries.count, privacy: .public); cached=\(hydrated.count, privacy: .public); epoch=\(key.accountEpoch, privacy: .public)"
        )
        return .hydrate(HydrationSeed(initial: initial, entries: entries, hydrated: hydrated))
    }

    private func hydrationEntries(
        _ flightID: UUID, key: RefreshKey, baseline: [QueueEntry], receivedMetadata: Bool = false
    ) -> [QueueEntry]? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        if receivedMetadata { refreshDiagnostics.metadataResults += 1 }
        return acceptedConnectOrdering(for: key.contextURI)?.entries ?? baseline
    }

    private func commitHydration(
        _ tracks: [CatalogTrack], baseline: [QueueEntry], flightID: UUID, key: RefreshKey
    ) -> ProvenanceQueueSnapshot? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        return updateFallbackSnapshot(
            entries: baseline, tracks: tracks,
            requestedEpoch: key.accountEpoch, requestedContext: key.contextURI)
    }

    private func currentRefreshSnapshot(_ flightID: UUID, key: RefreshKey) -> ProvenanceQueueSnapshot? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        return snapshot
    }

    var refreshSubscriberCount: Int { refreshFlight?.subscribers.count ?? 0 }

    private func subscribersForPublication(_ flightID: UUID, key: RefreshKey) -> [RefreshSubscriber]? {
        guard isCurrentRefresh(flightID, key: key) else { return nil }
        refreshDiagnostics.publications += 1
        return refreshFlight.map { Array($0.subscribers.values) }
    }

    private func removeRefreshSubscriber(_ subscriberID: UUID) {
        refreshFlight?.subscribers.removeValue(forKey: subscriberID)?.complete(nil)
        // Keep a detached flight alive for replacement callers with identical inputs. A changed
        // context or fallback invalidates it through RefreshKey instead of silently reusing the
        // first caller's captured inputs.
    }

    private func finishRefreshFlight(_ flightID: UUID, key: RefreshKey, result: ProvenanceQueueSnapshot?) {
        guard let flight = refreshFlight, flight.id == flightID else { return }
        let result = isCurrentRefresh(flightID, key: key) ? result : nil
        refreshFlight = nil
        flight.complete(result)
    }

    private func cancelRefreshFlight() {
        guard let flight = refreshFlight else { return }
        refreshFlight = nil
        refreshDiagnostics.cancellations += 1
        flight.cancel()
    }

    private func acceptedQueue() -> AcceptedConnectQueue? {
        guard let snapshot, let mutation else { return nil }
        return AcceptedConnectQueue(snapshot: snapshot, mutation: mutation)
    }

    private static func uniqueTrackURIs(in entries: [QueueEntry]) -> [String] {
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
        let isHydrated = Self.uniqueTrackURIs(in: currentEntries).allSatisfy { knownURIs.contains($0) }
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
            album: metadata.albumItem?.title ?? "",
            duration: metadata.duration,
            artworkURL: metadata.artworkURL,
            addedAt: nil,
            artists: metadata.artists,
            albumItem: metadata.albumItem
        )
    }

    private var shouldRequestWebQueue: Bool {
        guard webCapability != .unavailable else { return false }
        guard let webRetryNotBefore else { return true }
        return clock.now() >= webRetryNotBefore
    }
}

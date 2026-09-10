import Foundation

/// A bounded snapshot of fan-out pressure. Counters saturate instead of wrapping, so a long
/// lived engine cannot turn diagnostics into a false negative after `UInt64` overflow.
nonisolated struct EngineEventFanoutDiagnostics: Sendable, Equatable {
    let coalescedCount: UInt64
    let overflowCount: UInt64
    let resynchronizationCount: UInt64
    let pendingCount: Int
    let maximumPendingCount: Int
    let subscriberCount: Int
    let queuedEnvelopeCount: Int
}

/// Process-local fan-out for typed engine control events.
///
/// Sequence assignment and delivery are one owner. The fan-out does not use an `AsyncStream`
/// buffering policy for event storage: each subscriber is a pull-based stream backed by a fixed
/// mailbox. This matters because `bufferingNewest` can silently evict a terminal observation
/// while a playback consumer is stalled. Replaceable timing samples coalesce only when their
/// identity and semantic state match. A full mailbox or claimant queue is recovered with an
/// explicit resynchronization envelope, so pressure cannot silently turn into stale state.
nonisolated final class EngineEventFanout: @unchecked Sendable {
    private static let pendingLimit = 64
    private static let subscriberMailboxLimit = 64

    private let lock = NSLock()
    private let clock: any PlaybackClock
    private var subscribers: [UUID: SubscriberMailbox] = [:]
    private var pending: [PreparedEnvelope] = []
    private var sequence: UInt64 = 0
    private var delivering = false
    private var latestGeneration: [EventSlot: UInt64] = [:]
    private var latestEnvelopes: [EventSlot: RustPlaybackEventEnvelope] = [:]
    private var coalescedCount: UInt64 = 0
    private var overflowCount: UInt64 = 0
    private var resynchronizationCount: UInt64 = 0
    private var maximumPendingCount = 0
    private var previousConnectionLifecycle: ConnectionLifecycleIdentity?

    init(clock: any PlaybackClock) {
        self.clock = clock
    }

    /// `onStart` runs after the mailbox is installed and the lock is released, matching the
    /// engine's "subscribe before synchronous registration" rule. `onTermination` is also
    /// invoked without the fan-out lock held.
    func events(
        onStart: (@Sendable () -> Void)? = nil,
        onTermination: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<RustPlaybackEventEnvelope> {
        let id = UUID()
        let mailbox = SubscriberMailbox(capacity: Self.subscriberMailboxLimit)
        let lease = SubscriberLease(id: id, owner: self, mailbox: mailbox, onTermination: onTermination)
        let stream = AsyncStream<RustPlaybackEventEnvelope>(
            unfolding: { await lease.next() },
            onCancel: { [weak lease] in lease?.cancel() }
        )

        lock.lock()
        subscribers[id] = mailbox
        lock.unlock()

        onStart?()
        return stream
    }

    /// Assigns an envelope and queues it before invoking `afterPrepare`. The callback is useful
    /// to force concurrent assignment order in tests. It must not wait for this drain to finish if
    /// it also calls `emit`.
    func emit(_ event: RustPlaybackEvent, afterPrepare: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let envelope = nextEnvelopeLocked(event)
        let classification = classificationLocked(event)
        rememberLatestLocked(envelope)
        enqueueLocked(PreparedEnvelope(envelope: envelope, classification: classification))
        let claimedDelivery = !delivering
        if claimedDelivery {
            delivering = true
        }
        lock.unlock()

        afterPrepare?()

        guard claimedDelivery else { return }
        deliverPending()
    }

    func diagnostics() -> EngineEventFanoutDiagnostics {
        lock.lock()
        let mailboxes = Array(subscribers.values)
        let snapshot = EngineEventFanoutDiagnostics(
            coalescedCount: coalescedCount,
            overflowCount: overflowCount,
            resynchronizationCount: resynchronizationCount,
            pendingCount: pending.count,
            maximumPendingCount: maximumPendingCount,
            subscriberCount: subscribers.count,
            queuedEnvelopeCount: mailboxes.reduce(into: 0) { $0 += $1.count() }
        )
        lock.unlock()
        return snapshot
    }

    fileprivate func removeSubscriber(_ id: UUID) {
        lock.lock()
        let mailbox = subscribers.removeValue(forKey: id)
        lock.unlock()
        mailbox?.finish()
    }

    private func nextEnvelopeLocked(_ event: RustPlaybackEvent) -> RustPlaybackEventEnvelope {
        sequence &+= 1
        return RustPlaybackEventEnvelope(
            sequence: sequence,
            receivedAt: clock.now(),
            event: event
        )
    }

    private func rememberLatestLocked(_ envelope: RustPlaybackEventEnvelope) {
        guard !envelope.event.isResynchronization else { return }
        let slot = envelope.event.slot
        let generation = envelope.event.sessionGeneration
        if let previous = latestEnvelopes[slot] {
            let previousGeneration = previous.event.sessionGeneration
            if generation > previousGeneration
                || (generation == previousGeneration && envelope.event.sourceRevision > previous.event.sourceRevision)
            {
                latestEnvelopes[slot] = envelope
            }
        } else {
            latestEnvelopes[slot] = envelope
        }
    }

    private func enqueueLocked(_ prepared: PreparedEnvelope) {
        switch prepared.classification {
        case let .replaceable(key):
            if let previous = pending.last, previous.classification == .replaceable(key) {
                // Remove before appending. Replacing in place would put a newer sequence before
                // an already queued event and violate the process-wide order contract.
                if prepared.envelope.event.sourceRevision >= previous.envelope.event.sourceRevision {
                    pending.removeLast()
                    pending.append(prepared)
                }
                increment(&coalescedCount)
                return
            }
            guard pending.count < Self.pendingLimit else {
                enqueueResynchronizationLocked(generation: prepared.envelope.event.sessionGeneration)
                return
            }
            pending.append(prepared)
        case .critical:
            guard pending.count < Self.pendingLimit else {
                enqueueResynchronizationLocked(generation: prepared.envelope.event.sessionGeneration)
                return
            }
            pending.append(prepared)
        }
        maximumPendingCount = max(maximumPendingCount, pending.count)
    }

    private func enqueueResynchronizationLocked(generation: UInt64) {
        increment(&overflowCount)
        if let index = pending.firstIndex(where: { $0.envelope.event.isResynchronization }) {
            let existing = pending[index].envelope
            let mergedGeneration = max(existing.event.sessionGeneration, generation)
            pending[index] = recoveryMarkerLocked(
                sequence: existing.sequence,
                receivedAt: existing.receivedAt,
                minimumGeneration: mergedGeneration
            )
            return
        }

        let mergedGeneration = max(
            generation,
            pending.map { $0.envelope.event.sessionGeneration }.max() ?? generation
        )

        // Every pending item is either obsolete replaceable work or a fact that can no longer be
        // proven complete to this consumer. Clearing the claimant queue and fencing it with one
        // marker keeps memory bounded and makes recovery an explicit store decision.
        pending.removeAll(keepingCapacity: true)
        pending.append(
            recoveryMarkerLocked(
                sequence: nextSequenceLocked(),
                receivedAt: clock.now(),
                minimumGeneration: mergedGeneration
            )
        )
        increment(&resynchronizationCount)
        maximumPendingCount = max(maximumPendingCount, pending.count)
    }

    private func nextSequenceLocked() -> UInt64 {
        sequence &+= 1
        return sequence
    }

    private func recoveryMarkerLocked(
        sequence: UInt64,
        receivedAt: Date,
        minimumGeneration: UInt64
    ) -> PreparedEnvelope {
        let generation = max(
            minimumGeneration,
            latestEnvelopes.values.map { $0.event.sessionGeneration }.max() ?? minimumGeneration
        )
        var snapshots = latestEnvelopes.values.filter { $0.event.sessionGeneration == generation }
        snapshots.sort { $0.sequence < $1.sequence }
        let event = RustPlaybackEvent.resynchronizationRequired(
            sessionGeneration: generation,
            snapshots: snapshots
        )
        return PreparedEnvelope(
            envelope: RustPlaybackEventEnvelope(sequence: sequence, receivedAt: receivedAt, event: event),
            classification: .critical
        )
    }

    private func classificationLocked(_ event: RustPlaybackEvent) -> DeliveryClassification {
        let slot = event.slot
        let generation = event.sessionGeneration
        let generationChanged = latestGeneration[slot].map { $0 != generation } ?? false
        if latestGeneration[slot].map({ generation > $0 }) ?? true {
            latestGeneration[slot] = generation
        }

        switch event {
        case let .playback(state):
            guard !generationChanged, !state.trackUnavailable, !state.audioKeyRefused else {
                return .critical
            }
            return .replaceable(
                .playback(
                    PlaybackTimingIdentity(
                        generation: state.sessionGeneration,
                        trackURI: state.trackURI,
                        contextURI: state.contextURI,
                        isPlaying: state.isPlaying,
                        isPaused: state.isPaused,
                        durationMS: state.durationMS,
                        shuffle: state.shuffle,
                        repeatTrack: state.repeatTrack,
                        repeatContext: state.repeatContext,
                        isActiveDevice: state.isActiveDevice
                    )
                ))
        case let .queue(state):
            guard !generationChanged else { return .critical }
            return .replaceable(.queue(state.sessionGeneration))
        case let .connection(state):
            let lifecycle = ConnectionLifecycleIdentity(
                generation: state.sessionGeneration,
                sessionConnected: state.sessionConnected,
                spircReady: state.spircReady,
                isActiveDevice: state.isActiveDevice,
                resumePending: state.resumePending,
                deviceID: state.deviceID
            )
            let changed = lifecycleChanged(lifecycle)
            guard
                !generationChanged,
                state.lastError == nil,
                !state.credentialsRejected,
                !changed
            else { return .critical }
            return .replaceable(.connection(lifecycle))
        case let .devices(state):
            guard !generationChanged else { return .critical }
            return .replaceable(.devices(state.sessionGeneration))
        case let .cluster(state):
            guard !generationChanged, !stateContainsCriticalFailure(state) else { return .critical }
            return .replaceable(.cluster(ClusterIdentity(state)))
        case .resynchronizationRequired:
            return .critical
        }
    }

    private func lifecycleChanged(_ lifecycle: ConnectionLifecycleIdentity) -> Bool {
        defer { previousConnectionLifecycle = lifecycle }
        guard let previousConnectionLifecycle else { return false }
        return previousConnectionLifecycle != lifecycle
    }

    private func stateContainsCriticalFailure(_ state: RustConnectClusterState) -> Bool {
        if let connection = state.connection,
            connection.lastError != nil || connection.credentialsRejected || connection.resumePending
        {
            return true
        }
        if let playback = state.playback, playback.trackUnavailable || playback.audioKeyRefused {
            return true
        }
        return false
    }

    private func deliverPending() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                delivering = false
                lock.unlock()
                return
            }

            let item = pending.removeFirst()
            let targets = Array(subscribers.values)

            // Preflight mailbox capacity while the fan-out lock is held. Consumers can only
            // remove work between this check and offer(), which makes a planned marker safe;
            // producers cannot insert a later sequence ahead of it.
            var overflowing: [(SubscriberMailbox, UInt64)] = []
            var plans: [(SubscriberMailbox, PreparedEnvelope)] = []
            for mailbox in targets {
                if let generation = mailbox.overflowGeneration(for: item) {
                    overflowing.append((mailbox, generation))
                } else {
                    plans.append((mailbox, item))
                }
            }
            if !overflowing.isEmpty {
                let generation = overflowing.map(\.1).max() ?? item.envelope.event.sessionGeneration
                let marker = recoveryMarkerLocked(
                    // The original item is fenced at its place in the ordered stream. Do not
                    // allocate a later sequence that would follow future survivors.
                    sequence: item.envelope.sequence,
                    receivedAt: item.envelope.receivedAt,
                    minimumGeneration: generation
                )
                increment(&overflowCount)
                increment(&resynchronizationCount)
                plans.append(contentsOf: overflowing.map { ($0.0, marker) })
            }
            lock.unlock()

            for (mailbox, planned) in plans {
                switch mailbox.offer(planned) {
                case .delivered, .enqueued:
                    break
                case .coalesced:
                    lock.lock()
                    increment(&coalescedCount)
                    lock.unlock()
                case .overflow:
                    // The preflight can only become more permissive when a consumer pulls. Keep
                    // this defensive path bounded by replacing the mailbox with the same marker.
                    let generation = planned.envelope.event.sessionGeneration
                    lock.lock()
                    let fallback = recoveryMarkerLocked(
                        sequence: planned.envelope.sequence,
                        receivedAt: planned.envelope.receivedAt,
                        minimumGeneration: generation
                    )
                    increment(&overflowCount)
                    increment(&resynchronizationCount)
                    lock.unlock()
                    mailbox.forceMarker(fallback)
                }
            }
        }
    }

    private func increment(_ counter: inout UInt64) {
        if counter != .max { counter += 1 }
    }
}

private enum EventSlot: Hashable, Sendable {
    case playback
    case queue
    case connection
    case devices
    case cluster
}

private struct PlaybackTimingIdentity: Hashable, Sendable {
    let generation: UInt64
    let trackURI: String
    let contextURI: String?
    let isPlaying: Bool
    let isPaused: Bool
    let durationMS: Int64
    let shuffle: Bool
    let repeatTrack: Bool
    let repeatContext: Bool
    let isActiveDevice: Bool
}

private struct ConnectionLifecycleIdentity: Hashable, Sendable {
    let generation: UInt64
    let sessionConnected: Bool
    let spircReady: Bool
    let isActiveDevice: Bool
    let resumePending: Bool
    let deviceID: String?
}

private struct ClusterIdentity: Hashable, Sendable {
    let generation: UInt64
    let source: UInt8
    let localDeviceID: String?
    let activeDeviceID: String?
    let devices: [DeviceIdentity]
    let connection: ConnectionLifecycleIdentity?
    let playback: PlaybackTimingIdentity?
    let queueRevision: String?

    init(_ state: RustConnectClusterState) {
        generation = state.sessionGeneration
        source = state.source
        localDeviceID = state.localDeviceID
        activeDeviceID = state.devices.activeDeviceID
        devices = state.devices.devices.map { DeviceIdentity(id: $0.id, name: $0.name, type: $0.type) }
        if let connection = state.connection {
            self.connection = ConnectionLifecycleIdentity(
                generation: connection.sessionGeneration,
                sessionConnected: connection.sessionConnected,
                spircReady: connection.spircReady,
                isActiveDevice: connection.isActiveDevice,
                resumePending: connection.resumePending,
                deviceID: connection.deviceID
            )
        } else {
            self.connection = nil
        }
        if let playback = state.playback {
            self.playback = PlaybackTimingIdentity(
                generation: playback.sessionGeneration,
                trackURI: playback.trackURI,
                contextURI: playback.contextURI,
                isPlaying: playback.isPlaying,
                isPaused: playback.isPaused,
                durationMS: playback.durationMS,
                shuffle: playback.shuffle,
                repeatTrack: playback.repeatTrack,
                repeatContext: playback.repeatContext,
                isActiveDevice: playback.isActiveDevice
            )
        } else {
            self.playback = nil
        }
        queueRevision = state.queue?.queueRevision
    }
}

private struct DeviceIdentity: Hashable, Sendable {
    let id: String
    let name: String
    let type: String
}

private enum DeliveryClassification: Equatable, Sendable {
    case replaceable(CoalescingKey)
    case critical
}

private enum CoalescingKey: Hashable, Sendable {
    case playback(PlaybackTimingIdentity)
    case queue(UInt64)
    case connection(ConnectionLifecycleIdentity)
    case devices(UInt64)
    case cluster(ClusterIdentity)
}

private struct PreparedEnvelope: Sendable {
    let envelope: RustPlaybackEventEnvelope
    let classification: DeliveryClassification
}

extension RustPlaybackEvent {
    fileprivate var slot: EventSlot {
        switch self {
        case .playback: return .playback
        case .queue: return .queue
        case .connection: return .connection
        case .devices: return .devices
        case .cluster: return .cluster
        case .resynchronizationRequired: return .cluster
        }
    }

    var sessionGeneration: UInt64 {
        switch self {
        case let .playback(state): return state.sessionGeneration
        case let .queue(state): return state.sessionGeneration
        case let .connection(state): return state.sessionGeneration
        case let .devices(state): return state.sessionGeneration
        case let .cluster(state): return state.sessionGeneration
        case let .resynchronizationRequired(sessionGeneration, _): return sessionGeneration
        }
    }

    var isResynchronization: Bool {
        if case .resynchronizationRequired = self { return true }
        return false
    }

    var sourceRevision: UInt64 {
        switch self {
        case let .playback(state): return state.revision
        case let .queue(state): return state.revision
        case let .connection(state): return state.revision
        case let .devices(state): return state.revision
        case let .cluster(state): return state.revision
        case .resynchronizationRequired: return 0
        }
    }
}

private final class SubscriberMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var queue: [PreparedEnvelope] = []
    private var waiter: CheckedContinuation<RustPlaybackEventEnvelope?, Never>?
    private var finished = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    func next() async -> RustPlaybackEventEnvelope? {
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<RustPlaybackEventEnvelope?, Never>) in
                    lock.lock()
                    if let prepared = queue.first {
                        queue.removeFirst()
                        lock.unlock()
                        continuation.resume(returning: prepared.envelope)
                    } else if finished {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else if waiter == nil {
                        waiter = continuation
                        lock.unlock()
                    } else {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.finish()
            })
    }

    func count() -> Int {
        lock.lock()
        let count = queue.count
        lock.unlock()
        return count
    }

    /// Returns the generation to fence when the incoming item cannot fit. A nil result means
    /// the item can be delivered or coalesced without loss.
    func overflowGeneration(for prepared: PreparedEnvelope) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        if waiter != nil { return nil }
        if case let .replaceable(key) = prepared.classification,
            let previous = queue.last, previous.classification == .replaceable(key)
        {
            return nil
        }
        guard queue.count >= capacity else { return nil }
        return max(
            prepared.envelope.event.sessionGeneration,
            queue.map { $0.envelope.event.sessionGeneration }.max() ?? prepared.envelope.event.sessionGeneration
        )
    }

    enum OfferResult {
        case delivered
        case enqueued
        case coalesced
        case overflow
    }

    func offer(_ prepared: PreparedEnvelope) -> OfferResult {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return .delivered
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: prepared.envelope)
            return .delivered
        }
        if case let .replaceable(key) = prepared.classification,
            let previous = queue.last, previous.classification == .replaceable(key)
        {
            if prepared.envelope.event.sourceRevision >= previous.envelope.event.sourceRevision {
                queue.removeLast()
                queue.append(prepared)
            }
            lock.unlock()
            return .coalesced
        }
        guard queue.count < capacity else {
            lock.unlock()
            return .overflow
        }
        queue.append(prepared)
        lock.unlock()
        return .enqueued
    }

    func forceMarker(_ marker: PreparedEnvelope) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let waiting = waiter
        waiter = nil
        queue.removeAll(keepingCapacity: true)
        if waiting == nil {
            queue.append(marker)
        }
        lock.unlock()
        waiting?.resume(returning: marker.envelope)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        queue.removeAll(keepingCapacity: false)
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }
}

/// Keeps the fan-out registration tied to the returned stream's lifetime. `AsyncStream` invokes
/// `onCancel` for task cancellation, but a consumer can also simply drop a stream after breaking
/// its loop. The stream's unfolding closure owns this lease; its deinit closes both registrations.
private final class SubscriberLease: @unchecked Sendable {
    private let id: UUID
    private weak var owner: EngineEventFanout?
    private let mailbox: SubscriberMailbox
    private let onTermination: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var cancelled = false

    init(
        id: UUID,
        owner: EngineEventFanout,
        mailbox: SubscriberMailbox,
        onTermination: (@Sendable () -> Void)?
    ) {
        self.id = id
        self.owner = owner
        self.mailbox = mailbox
        self.onTermination = onTermination
    }

    func next() async -> RustPlaybackEventEnvelope? {
        await mailbox.next()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        owner?.removeSubscriber(id)
        mailbox.finish()
        onTermination?()
    }

    deinit {
        cancel()
    }
}

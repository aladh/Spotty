import Foundation
import SpottyDomain
import Synchronization

/// A bounded snapshot of fan-out pressure. Counters saturate instead of wrapping, so a long
/// lived engine cannot turn diagnostics into a false negative after `UInt64` overflow.
public nonisolated struct EngineEventFanoutDiagnostics: Sendable, Equatable {
    public let coalescedCount: UInt64
    public let overflowCount: UInt64
    public let resynchronizationCount: UInt64
    public let pendingCount: Int
    public let maximumPendingCount: Int
    public let subscriberCount: Int
    public let queuedEnvelopeCount: Int

    public init(
        coalescedCount: UInt64,
        overflowCount: UInt64,
        resynchronizationCount: UInt64,
        pendingCount: Int,
        maximumPendingCount: Int,
        subscriberCount: Int,
        queuedEnvelopeCount: Int
    ) {
        self.coalescedCount = coalescedCount
        self.overflowCount = overflowCount
        self.resynchronizationCount = resynchronizationCount
        self.pendingCount = pendingCount
        self.maximumPendingCount = maximumPendingCount
        self.subscriberCount = subscriberCount
        self.queuedEnvelopeCount = queuedEnvelopeCount
    }
}

/// Process-local fan-out for typed engine control events.
///
/// Sequence assignment and delivery are one owner. The fan-out does not use an `AsyncStream`
/// buffering policy for event storage: each subscriber is a pull-based stream backed by a fixed
/// mailbox. This matters because `bufferingNewest` can silently evict a terminal observation
/// while a playback consumer is stalled. Replaceable timing samples coalesce only when their
/// identity and semantic state match. A full mailbox or claimant queue is recovered with an
/// explicit resynchronization envelope, so pressure cannot silently turn into stale state.
public nonisolated final class EngineEventFanout: Sendable {
    private static let pendingLimit = 64
    private static let subscriberMailboxLimit = 64

    private struct State: Sendable {
        let clock: any PlaybackClock
        var subscribers: [UUID: SubscriberMailbox] = [:]
        var pending: [PreparedEnvelope] = []
        var sequence: UInt64 = 0
        var delivering = false
        var latestGeneration: [EventSlot: UInt64] = [:]
        var latestEnvelopes: [EventSlot: RustPlaybackEventEnvelope] = [:]
        var coalescedCount: UInt64 = 0
        var overflowCount: UInt64 = 0
        var resynchronizationCount: UInt64 = 0
        var maximumPendingCount = 0
        var previousConnectionLifecycle: ConnectionLifecycleIdentity?

        mutating func nextEnvelope(_ event: RustPlaybackEvent) -> RustPlaybackEventEnvelope {
            return RustPlaybackEventEnvelope(
                sequence: nextSequence(),
                receivedAt: clock.now(),
                event: event
            )
        }

        mutating func rememberLatest(_ envelope: RustPlaybackEventEnvelope) {
            guard !envelope.event.isResynchronization else { return }
            let slot = envelope.event.slot
            let generation = envelope.event.sessionGeneration
            if let previous = latestEnvelopes[slot] {
                let previousGeneration = previous.event.sessionGeneration
                if generation > previousGeneration
                    || (generation == previousGeneration
                        && envelope.event.sourceRevision > previous.event.sourceRevision)
                {
                    latestEnvelopes[slot] = envelope
                }
            } else {
                latestEnvelopes[slot] = envelope
            }
        }

        mutating func enqueue(_ prepared: PreparedEnvelope) {
            if case let .replaceable(key) = prepared.classification,
                let previous = pending.last, previous.classification == .replaceable(key)
            {
                // Remove before appending to preserve the process-wide sequence order.
                if prepared.envelope.event.sourceRevision >= previous.envelope.event.sourceRevision {
                    pending.removeLast()
                    pending.append(prepared)
                }
                Self.increment(&coalescedCount)
                return
            }
            guard pending.count < EngineEventFanout.pendingLimit else {
                enqueueResynchronization(generation: prepared.envelope.event.sessionGeneration)
                return
            }
            pending.append(prepared)
            maximumPendingCount = max(maximumPendingCount, pending.count)
        }

        mutating func enqueueResynchronization(generation: UInt64) {
            Self.increment(&overflowCount)
            if let index = pending.firstIndex(where: { $0.envelope.event.isResynchronization }) {
                let existing = pending[index].envelope
                let mergedGeneration = max(existing.event.sessionGeneration, generation)
                pending[index] = recoveryMarker(
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
                recoveryMarker(
                    sequence: nextSequence(),
                    receivedAt: clock.now(),
                    minimumGeneration: mergedGeneration
                )
            )
            Self.increment(&resynchronizationCount)
            maximumPendingCount = max(maximumPendingCount, pending.count)
        }

        mutating func nextSequence() -> UInt64 {
            sequence &+= 1
            return sequence
        }

        func recoveryMarker(
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

        mutating func classification(_ event: RustPlaybackEvent) -> DeliveryClassification {
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
                return .replaceable(.queue(QueueIdentity(state)))
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
                return .replaceable(.devices(DevicesIdentity(state)))
            case let .cluster(state):
                guard !generationChanged, !stateContainsCriticalFailure(state) else { return .critical }
                return .replaceable(.cluster(ClusterIdentity(state)))
            case .resynchronizationRequired:
                return .critical
            }
        }

        mutating func lifecycleChanged(_ lifecycle: ConnectionLifecycleIdentity) -> Bool {
            defer { previousConnectionLifecycle = lifecycle }
            guard let previousConnectionLifecycle else { return false }
            return previousConnectionLifecycle != lifecycle
        }

        func stateContainsCriticalFailure(_ state: RustConnectClusterState) -> Bool {
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

        /// Preflight capacity under the fan-out lock. Consumers can only remove work before
        /// delivery, and producers cannot insert a later sequence ahead of this batch.
        mutating func nextDelivery() -> [(SubscriberMailbox, PreparedEnvelope)]? {
            guard !pending.isEmpty else {
                delivering = false
                return nil
            }
            let item = pending.removeFirst()
            var overflowing: [(SubscriberMailbox, UInt64)] = []
            var plans: [(SubscriberMailbox, PreparedEnvelope)] = []
            for mailbox in subscribers.values {
                if let generation = mailbox.overflowGeneration(for: item) {
                    overflowing.append((mailbox, generation))
                } else {
                    plans.append((mailbox, item))
                }
            }
            if !overflowing.isEmpty {
                let generation = overflowing.map(\.1).max() ?? item.envelope.event.sessionGeneration
                let marker = recoveryMarker(
                    // Fence the original item at its position, before future survivors.
                    sequence: item.envelope.sequence, receivedAt: item.envelope.receivedAt,
                    minimumGeneration: generation)
                Self.increment(&overflowCount)
                Self.increment(&resynchronizationCount)
                plans.append(contentsOf: overflowing.map { ($0.0, marker) })
            }
            return plans
        }

        static func increment(_ counter: inout UInt64) {
            if counter != .max { counter += 1 }
        }
    }

    private let state: Mutex<State>

    public init(clock: any PlaybackClock) {
        state = Mutex(State(clock: clock))
    }

    /// Install the mailbox before registration can publish synchronous snapshots. Lifecycle
    /// callbacks, continuations, and delivery always run outside the fan-out lock.
    public func events(
        onStart: (@Sendable () -> Void)? = nil,
        onTermination: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<RustPlaybackEventEnvelope> {
        let id = UUID()
        let mailbox = SubscriberMailbox(capacity: Self.subscriberMailboxLimit)
        let lease = SubscriberLease(id: id, owner: self, mailbox: mailbox, onTermination: onTermination)
        let stream = AsyncStream<RustPlaybackEventEnvelope>(
            unfolding: { await lease.next() },
            onCancel: { [weak lease] in lease?.cancel() })
        state.withLock { $0.subscribers[id] = mailbox }
        onStart?()
        return stream
    }

    /// Assign and queue before invoking the test scheduling hook. A reentrant hook may emit,
    /// but must not wait for this drain to finish.
    public func emit(_ event: RustPlaybackEvent, afterPrepare: (@Sendable () -> Void)? = nil) {
        let claimedDelivery = state.withLock { state in
            let envelope = state.nextEnvelope(event)
            let classification = state.classification(event)
            state.rememberLatest(envelope)
            state.enqueue(PreparedEnvelope(envelope: envelope, classification: classification))
            guard !state.delivering else { return false }
            state.delivering = true
            return true
        }
        afterPrepare?()
        if claimedDelivery { deliverPending() }
    }

    public func diagnostics() -> EngineEventFanoutDiagnostics {
        state.withLock { state in
            EngineEventFanoutDiagnostics(
                coalescedCount: state.coalescedCount,
                overflowCount: state.overflowCount,
                resynchronizationCount: state.resynchronizationCount,
                pendingCount: state.pending.count,
                maximumPendingCount: state.maximumPendingCount,
                subscriberCount: state.subscribers.count,
                queuedEnvelopeCount: state.subscribers.values.reduce(into: 0) { $0 += $1.count() })
        }
    }

    fileprivate func removeSubscriber(_ id: UUID) {
        let mailbox = state.withLock { $0.subscribers.removeValue(forKey: id) }
        mailbox?.finish()
    }

    private func deliverPending() {
        while let plans = state.withLock({ $0.nextDelivery() }) {
            for (mailbox, planned) in plans {
                switch mailbox.offer(planned) {
                case .delivered, .enqueued:
                    break
                case .coalesced:
                    state.withLock { State.increment(&$0.coalescedCount) }
                case .overflow:
                    // Preflight can only become more permissive when a consumer pulls. Keep
                    // this defensive path bounded by replacing the mailbox with the same marker.
                    let fallback = state.withLock { state in
                        let marker = state.recoveryMarker(
                            sequence: planned.envelope.sequence,
                            receivedAt: planned.envelope.receivedAt,
                            minimumGeneration: planned.envelope.event.sessionGeneration)
                        State.increment(&state.overflowCount)
                        State.increment(&state.resynchronizationCount)
                        return marker
                    }
                    mailbox.forceMarker(fallback)
                }
            }
        }
    }
}

private enum EventSlot: Hashable, Sendable {
    case playback
    case queue
    case connection
    case devices
    case cluster
}

private struct PlaybackTimingIdentity: Equatable, Sendable {
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

private struct QueueItemIdentity: Equatable, Sendable {
    let uri: String
    let provider: String
    let uid: String

    init(_ item: RustQueueState.Item) {
        uri = item.uri
        provider = item.provider
        uid = item.uid
    }
}

private struct QueueIdentity: Equatable, Sendable {
    let generation: UInt64
    let track: QueueItemIdentity?
    let protocolNextTracks: [QueueProtocolTrack]
    let protocolPrevTracks: [QueueProtocolTrack]
    let queueRevision: String
    let disallowSetQueue: Bool
    let disallowRemovingFromNextTracks: Bool

    init(_ state: RustQueueState) {
        generation = state.sessionGeneration
        track = state.track.map(QueueItemIdentity.init)
        protocolNextTracks = state.protocolNextTracks
        protocolPrevTracks = state.protocolPrevTracks
        queueRevision = state.queueRevision
        disallowSetQueue = state.disallowSetQueue
        disallowRemovingFromNextTracks = state.disallowRemovingFromNextTracks
    }
}

private struct ConnectionLifecycleIdentity: Equatable, Sendable {
    let generation: UInt64
    let sessionConnected: Bool
    let spircReady: Bool
    let isActiveDevice: Bool
    let resumePending: Bool
    let deviceID: String?
}

private struct ClusterIdentity: Equatable, Sendable {
    let generation: UInt64
    let source: UInt8
    let localDeviceID: String?
    let activeDeviceID: String?
    let devices: [DeviceIdentity]
    let connection: ConnectionLifecycleIdentity?
    let playback: PlaybackTimingIdentity?
    let queue: QueueIdentity?

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
        queue = state.queue.map(QueueIdentity.init)
    }
}

private struct DeviceIdentity: Equatable, Sendable {
    let id: String
    let name: String
    let type: String
}

private struct DevicesIdentity: Equatable, Sendable {
    let generation: UInt64
    let activeDeviceID: String
    let devices: [DeviceIdentity]

    init(_ state: RustDevicesState) {
        generation = state.sessionGeneration
        activeDeviceID = state.activeDeviceID
        devices = state.devices.map { DeviceIdentity(id: $0.id, name: $0.name, type: $0.type) }
    }
}

private enum DeliveryClassification: Equatable, Sendable {
    case replaceable(CoalescingKey)
    case critical
}

private enum CoalescingKey: Equatable, Sendable {
    case playback(PlaybackTimingIdentity)
    case queue(QueueIdentity)
    case connection(ConnectionLifecycleIdentity)
    case devices(DevicesIdentity)
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

    public var sessionGeneration: UInt64 {
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

private final class SubscriberMailbox: Sendable {
    private typealias Continuation = CheckedContinuation<RustPlaybackEventEnvelope?, Never>

    private struct State: Sendable {
        var queue: [PreparedEnvelope] = []
        var waiter: Continuation?
        var finished = false
    }

    private enum Read {
        case waiting
        case ready(RustPlaybackEventEnvelope?)
    }

    private let state = Mutex(State())
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func next() async -> RustPlaybackEventEnvelope? {
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation {
                    (continuation: Continuation) in
                    let read = state.withLock { state -> Read in
                        if !state.queue.isEmpty {
                            return .ready(state.queue.removeFirst().envelope)
                        }
                        guard !state.finished, state.waiter == nil else { return .ready(nil) }
                        state.waiter = continuation
                        return .waiting
                    }
                    if case let .ready(envelope) = read { continuation.resume(returning: envelope) }
                }
            },
            onCancel: { [weak self] in
                self?.finish()
            })
    }

    func count() -> Int { state.withLock { $0.queue.count } }

    /// Returns the generation to fence when the incoming item cannot fit. A nil result means
    /// the item can be delivered or coalesced without loss.
    func overflowGeneration(for prepared: PreparedEnvelope) -> UInt64? {
        state.withLock { state in
            guard !state.finished, state.waiter == nil else { return nil }
            if case let .replaceable(key) = prepared.classification,
                let previous = state.queue.last, previous.classification == .replaceable(key)
            {
                return nil
            }
            guard state.queue.count >= capacity else { return nil }
            return max(
                prepared.envelope.event.sessionGeneration,
                state.queue.map { $0.envelope.event.sessionGeneration }.max()
                    ?? prepared.envelope.event.sessionGeneration
            )
        }
    }

    enum OfferResult {
        case delivered
        case enqueued
        case coalesced
        case overflow
    }

    func offer(_ prepared: PreparedEnvelope) -> OfferResult {
        let (result, waiter) = state.withLock { state -> (OfferResult, Continuation?) in
            guard !state.finished else { return (.delivered, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (.delivered, waiter)
            }
            if case let .replaceable(key) = prepared.classification,
                let previous = state.queue.last, previous.classification == .replaceable(key)
            {
                if prepared.envelope.event.sourceRevision >= previous.envelope.event.sourceRevision {
                    state.queue.removeLast()
                    state.queue.append(prepared)
                }
                return (.coalesced, nil)
            }
            guard state.queue.count < capacity else { return (.overflow, nil) }
            state.queue.append(prepared)
            return (.enqueued, nil)
        }
        waiter?.resume(returning: prepared.envelope)
        return result
    }

    func forceMarker(_ marker: PreparedEnvelope) {
        let waiting = state.withLock { state -> Continuation? in
            guard !state.finished else { return nil }
            let waiting = state.waiter
            state.waiter = nil
            state.queue.removeAll(keepingCapacity: true)
            if waiting == nil { state.queue.append(marker) }
            return waiting
        }
        waiting?.resume(returning: marker.envelope)
    }

    func finish() {
        let waiting = state.withLock { state -> Continuation? in
            guard !state.finished else { return nil }
            state.finished = true
            state.queue.removeAll(keepingCapacity: false)
            let waiting = state.waiter
            state.waiter = nil
            return waiting
        }
        waiting?.resume(returning: nil)
    }
}

/// Keeps the fan-out registration tied to the returned stream's lifetime. `AsyncStream` invokes
/// `onCancel` for task cancellation, but a consumer can also simply drop a stream after breaking
/// its loop. The stream's unfolding closure owns this lease; its deinit closes both registrations.
private final class SubscriberLease: Sendable {
    private let removeSubscriber: @Sendable () -> Void
    private let mailbox: SubscriberMailbox
    private let onTermination: (@Sendable () -> Void)?
    private let cancelled = Mutex(false)

    init(
        id: UUID,
        owner: EngineEventFanout,
        mailbox: SubscriberMailbox,
        onTermination: (@Sendable () -> Void)?
    ) {
        removeSubscriber = { [weak owner] in owner?.removeSubscriber(id) }
        self.mailbox = mailbox
        self.onTermination = onTermination
    }

    func next() async -> RustPlaybackEventEnvelope? {
        await mailbox.next()
    }

    func cancel() {
        let shouldCancel = cancelled.withLock { cancelled in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        removeSubscriber()
        mailbox.finish()
        onTermination?()
    }

    deinit {
        cancel()
    }
}

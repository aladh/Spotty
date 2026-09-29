import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
@testable import SpottySessionRuntime
@testable import SpottyCore

/// Boundary tests seed exact reducer/engine interleavings. These adapters keep that privileged
/// access out of the shipping MainActor facade while executing every mutation on runtime isolation.
@MainActor
extension PlaybackStore {
    /// Inspection reads runtime authority directly; it must not flush a desktop publication.
    var state: PlaybackState {
        let runtime = runtime
        return SessionRuntimeActor.sync { runtime.state }
    }

    var accountStore: AccountStore {
        AccountStore(raw: withRuntime { $0.accountStore }, didMutate: { [weak self] in self?.withRuntime { _ in } })
    }

    var effects: PlaybackEffectRegistry {
        PlaybackEffectRegistry(
            raw: withRuntime { $0.effects }, didMutate: { [weak self] in self?.withRuntime { _ in } })
    }

    var coordinator: PlaybackCoordinator { withRuntime { $0.coordinator } }
    var queueService: QueueService { withRuntime { $0.queueService } }
    var lastRemoteDeviceID: String? {
        get { withRuntime { $0.lastRemoteDeviceID } }
    }
    var shuffleHistoryCache: [String: TimeInterval] { withRuntime { $0.shuffleHistoryCache } }
    var rehydratedSessionGeneration: UInt64? { withRuntime { $0.rehydratedSessionGeneration } }
    var queueReplacementToken: UUID? { withRuntime { $0.queueReplacementToken } }
    var connectQueueCallback: ConnectQueueCallbackWatermark { withRuntime { $0.connectQueueCallback } }
    var queueMutation: QueueMutationSnapshot? {
        get { withRuntime { $0.queueMutation } }
        set { withRuntime { $0.queueMutation = newValue } }
    }
    var hasReceivedPlaybackSnapshot: Bool {
        get { withRuntime { $0.hasReceivedPlaybackSnapshot } }
        set { withRuntime { $0.hasReceivedPlaybackSnapshot = newValue } }
    }

    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        accountEpoch: UInt64? = nil,
        receivedAt: Date? = nil
    ) -> Bool {
        withRuntime {
            $0.send(
                event, source: source, revision: revision, engineEpoch: engineEpoch,
                accountEpoch: accountEpoch, receivedAt: receivedAt)
        }
    }

    func receive(_ envelope: RustPlaybackEventEnvelope) { withRuntime { $0.receive(envelope) } }
    func receive(_ cluster: RustConnectClusterState, receivedAt: Date) {
        withRuntime { $0.receive(cluster, receivedAt: receivedAt) }
    }
    func receive(_ state: RustPlaybackState, revision: UInt64, receivedAt: Date) {
        withRuntime { $0.receive(state, revision: revision, receivedAt: receivedAt) }
    }
    func receive(_ state: RustConnectionState, revision: UInt64, receivedAt: Date) {
        withRuntime { $0.receive(state, revision: revision, receivedAt: receivedAt) }
    }
    func receive(_ devices: [ConnectDevice], revision: UInt64, engineEpoch: UInt64) {
        withRuntime { $0.receive(devices, revision: revision, engineEpoch: engineEpoch) }
    }
    func acceptsConnectQueueCallback(generation: UInt64?, revision: UInt64?) -> Bool {
        withRuntime { $0.acceptsConnectQueueCallback(generation: generation, revision: revision) }
    }
    @discardableResult
    func apply(_ snapshot: ProvenanceQueueSnapshot, engineEpoch: UInt64) -> Bool {
        withRuntime { $0.apply(snapshot, engineEpoch: engineEpoch) }
    }
    @discardableResult
    func setTiming(
        position: TimeInterval, duration: TimeInterval? = nil, anchoredAt: Date? = nil,
        accountEpoch: UInt64? = nil, engineEpoch: UInt64? = nil
    ) -> Bool {
        withRuntime {
            $0.setTiming(
                position: position, duration: duration, anchoredAt: anchoredAt,
                accountEpoch: accountEpoch, engineEpoch: engineEpoch)
        }
    }
    func recordPlayed(_ uri: String) { withRuntime { $0.recordPlayed(uri) } }
    func showTransientCommandError(_ message: String) { withRuntime { $0.showTransientCommandError(message) } }
    func endSession(clearGrant: Bool, finalPhase: PlaybackSessionPhase) async {
        await runtime.endSession(clearGrant: clearGrant, finalPhase: finalPhase)
        withRuntime { _ in }
    }
    /// Queue tests use real reducer admission rather than an ownerless dispatch capability.
    func makeQueueDispatchPermit() -> PlaybackDispatchPermit? {
        withRuntime { runtime in
            let command = PendingPlaybackCommand(
                id: UUID(), kind: .queue, expectedTransport: nil, startedAt: HarnessDates.fixed)
            guard
                runtime.send(
                    .queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)), source: .command)
            else { return nil }
            return runtime.makePlaybackDispatchPermit(intentID: command.id, ifStillWanted: { true })
        }
    }

    func submitCommand(
        _ request: PlaybackSessionRuntime.CommandRequest,
        failureMessage: String,
        dispatchGuard: PlaybackSessionRuntime.DispatchGuard? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        withRuntime {
            $0.submitCommand(
                request, failureMessage: failureMessage, dispatchGuard: dispatchGuard,
                completion: { [weak self] accepted in
                    Task { @MainActor [weak self] in
                        self?.withRuntime { _ in }
                        completion(accepted)
                    }
                })
        }
    }

}

@MainActor
final class AccountStore {
    let raw: SpottySessionRuntime.AccountStore
    private let didMutate: @MainActor () -> Void

    init(raw: SpottySessionRuntime.AccountStore, didMutate: @escaping @MainActor () -> Void = {}) {
        self.raw = raw
        self.didMutate = didMutate
    }
    var phase: PlaybackSessionPhase { SessionRuntimeActor.sync { raw.phase } }
    var requiresReauthentication: Bool { SessionRuntimeActor.sync { raw.requiresReauthentication } }
    var epoch: UInt64 { SessionRuntimeActor.sync { raw.epoch } }
    var onPhaseChange: (@MainActor (PlaybackSessionPhase) -> Void)? {
        { [self] phase in
            SessionRuntimeActor.sync { raw.onPhaseChange?(phase) }
            didMutate()
        }
    }
    func advanceEpoch() {
        SessionRuntimeActor.sync { raw.advanceEpoch() }
        didMutate()
    }
}

@MainActor
final class PlaybackEffectRegistry {
    let raw: SpottySessionRuntime.PlaybackEffectRegistry
    private let didMutate: @MainActor () -> Void

    init(raw: SpottySessionRuntime.PlaybackEffectRegistry, didMutate: @escaping @MainActor () -> Void = {}) {
        self.raw = raw
        self.didMutate = didMutate
    }
    func settlement(of id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        SessionRuntimeActor.sync { raw.settlement(of: id) }.map {
            PlaybackEffectSettlement(raw: $0, didSettle: didMutate)
        }
    }
    func settlements() -> [PlaybackEffectID: PlaybackEffectSettlement] {
        SessionRuntimeActor.sync { raw.settlements() }.mapValues {
            PlaybackEffectSettlement(raw: $0, didSettle: didMutate)
        }
    }
    @discardableResult
    func cancel(_ id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        let result = SessionRuntimeActor.sync { raw.cancel(id) }
        didMutate()
        return result.map { PlaybackEffectSettlement(raw: $0, didSettle: didMutate) }
    }
    @discardableResult
    func cancelAccountScoped() -> [PlaybackEffectID: PlaybackEffectSettlement] {
        let result = SessionRuntimeActor.sync { raw.cancelAccountScoped() }
        didMutate()
        return result.mapValues { PlaybackEffectSettlement(raw: $0, didSettle: didMutate) }
    }

}

/// Waiting a runtime task also consumes its final value publication on the test's UI actor.
/// This preserves exact registration identity without assuming cross-executor delivery order.
struct PlaybackEffectSettlement: Sendable {
    let raw: SpottySessionRuntime.PlaybackEffectSettlement
    let didSettle: @MainActor @Sendable () -> Void
    func wait() async {
        await raw.wait()
        await didSettle()
    }
}

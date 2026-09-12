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
        set { withRuntime { $0.lastRemoteDeviceID = newValue } }
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
    func receive(
        _ state: RustQueueState, revision: UInt64, mayAdoptPlaybackIdentity: Bool = true,
        accountEpoch: UInt64? = nil, engineEpoch: UInt64? = nil
    ) {
        withRuntime {
            $0.receive(
                state, revision: revision, mayAdoptPlaybackIdentity: mayAdoptPlaybackIdentity,
                accountEpoch: accountEpoch, engineEpoch: engineEpoch)
        }
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
    func setRepeatMode(_ mode: RepeatMode) { withRuntime { $0.setRepeatMode(mode) } }
    func setRepeat(mode: RepeatMode, flags: RepeatFlags) { withRuntime { $0.setRepeat(mode: mode, flags: flags) } }
    func recordPlayed(_ uri: String) { withRuntime { $0.recordPlayed(uri) } }
    func showTransientCommandError(_ message: String) { withRuntime { $0.showTransientCommandError(message) } }
    func handleGrantRevocation() async {
        await runtime.handleGrantRevocation()
        withRuntime { _ in }
    }
    func endSession(clearGrant: Bool, finalPhase: PlaybackSessionPhase) async {
        await runtime.endSession(clearGrant: clearGrant, finalPhase: finalPhase)
        withRuntime { _ in }
    }
    func makePlaybackDispatchPermit(
        commandID: UUID? = nil, intentID: UUID? = nil,
        ifStillWanted: @escaping @SessionRuntimeActor @Sendable () -> Bool
    ) -> PlaybackDispatchPermit? {
        withRuntime {
            $0.makePlaybackDispatchPermit(commandID: commandID, intentID: intentID, ifStillWanted: ifStillWanted)
        }
    }

    func performCommand(
        _ action: String, expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil, expectedTrack: CurrentTrack? = nil,
        expectedShuffle: Bool? = nil, expectedRepeatFlags: RepeatFlags? = nil,
        expectedOwner: PlaybackOwner? = nil, operation: LocalPlaybackOperation,
        kind: PlaybackCommandKind = .transport,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        withRuntime {
            $0.performCommand(
                action, expecting: expectedPlaybackState, expectedTiming: expectedTiming,
                expectedTrack: expectedTrack, expectedShuffle: expectedShuffle,
                expectedRepeatFlags: expectedRepeatFlags, expectedOwner: expectedOwner,
                operation: operation, kind: kind
            ) { [weak self] accepted in
                Task { @MainActor [weak self] in
                    self?.withRuntime { _ in }
                    completion(accepted)
                }
            }
        }
    }
    func performRoutedCommand(
        _ action: String, kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil, expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil, expectedShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil, expectedOwner: PlaybackOwner? = nil,
        local: LocalPlaybackOperation, remote command: SpotifyConnectCommand,
        dispatchGuard: PlaybackSessionRuntime.DispatchGuard? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        withRuntime {
            $0.performRoutedCommand(
                action, kind: kind, expecting: expectedPlaybackState,
                expectedTiming: expectedTiming, expectedTrack: expectedTrack,
                expectedShuffle: expectedShuffle, expectedRepeatFlags: expectedRepeatFlags,
                expectedOwner: expectedOwner, local: local, remote: command,
                dispatchGuard: dispatchGuard
            ) { [weak self] accepted in
                Task { @MainActor [weak self] in
                    self?.withRuntime { _ in }
                    completion(accepted)
                }
            }
        }
    }
    func performRoutedOperation(
        _ action: String, kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil, expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil, expectedShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil, expectedOwner: PlaybackOwner? = nil,
        local: LocalPlaybackOperation,
        remote: @escaping @Sendable (any RemotePlaybackClient, String, String) async throws -> Void,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        withRuntime {
            $0.performRoutedOperation(
                action, kind: kind, expecting: expectedPlaybackState,
                expectedTiming: expectedTiming, expectedTrack: expectedTrack,
                expectedShuffle: expectedShuffle, expectedRepeatFlags: expectedRepeatFlags,
                expectedOwner: expectedOwner, local: local, remote: remote
            ) { [weak self] accepted in
                Task { @MainActor [weak self] in
                    self?.withRuntime { _ in }
                    completion(accepted)
                }
            }
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
    convenience init(environment: PlaybackEnvironment, coordinator: PlaybackCoordinator) {
        self.init(
            raw: SessionRuntimeActor.sync {
                SpottySessionRuntime.AccountStore(environment: environment, coordinator: coordinator)
            })
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
    func restore() async { await raw.restore(); didMutate() }
}

@MainActor
final class PlaybackEffectRegistry {
    nonisolated static let accountDrainTimeoutNanoseconds = SpottySessionRuntime.PlaybackEffectRegistry
        .accountDrainTimeoutNanoseconds
    let raw: SpottySessionRuntime.PlaybackEffectRegistry
    private let didMutate: @MainActor () -> Void

    init(raw: SpottySessionRuntime.PlaybackEffectRegistry, didMutate: @escaping @MainActor () -> Void = {}) {
        self.raw = raw
        self.didMutate = didMutate
    }
    convenience init() { self.init(raw: SessionRuntimeActor.sync { SpottySessionRuntime.PlaybackEffectRegistry() }) }
    func settlement(of id: PlaybackEffectID) -> PlaybackEffectSettlement? {
        SessionRuntimeActor.sync { raw.settlement(of: id) }.map {
            PlaybackEffectSettlement(raw: $0, didSettle: didMutate)
        }
    }
    func replace(
        _ id: PlaybackEffectID, with task: Task<Void, Never>, registration: PlaybackEffectRegistration? = nil,
        onCancel: (@SessionRuntimeActor () -> Void)? = nil
    ) {
        SessionRuntimeActor.sync { raw.replace(id, with: task, registration: registration, onCancel: onCancel) }
        didMutate()
    }
    func complete(_ id: PlaybackEffectID, registration: PlaybackEffectRegistration) {
        SessionRuntimeActor.sync { raw.complete(id, registration: registration) }
        didMutate()
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
    func cancelAccountScopedAndDrain(timeoutNanoseconds: UInt64 = accountDrainTimeoutNanoseconds) async
        -> PlaybackEffectDrainReport
    {
        let result = await raw.cancelAccountScopedAndDrain(timeoutNanoseconds: timeoutNanoseconds)
        didMutate()
        return result
    }
    func drain(
        _ settlements: [PlaybackEffectID: PlaybackEffectSettlement],
        timeoutNanoseconds: UInt64 = accountDrainTimeoutNanoseconds
    ) async -> PlaybackEffectDrainReport {
        await raw.drain(settlements.mapValues(\.raw), timeoutNanoseconds: timeoutNanoseconds)
    }
}

@MainActor
final class PlaybackPreferenceWriter {
    private let raw: SpottySessionRuntime.PlaybackPreferenceWriter
    init(preferences: any PlaybackPreferences) {
        raw = SessionRuntimeActor.sync { SpottySessionRuntime.PlaybackPreferenceWriter(preferences: preferences) }
    }
    @discardableResult
    func submit(epoch: UInt64, _ write: @escaping @Sendable (any PlaybackPreferences) async -> Void) -> Task<
        Void, Never
    > {
        SessionRuntimeActor.sync { raw.submit(epoch: epoch, write) }
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

import SpottyDiagnostics
//
//  PlaybackSessionRuntime+Session.swift
//  Spotty
//
//  The one session-teardown orchestration. AccountStore supplies narrow account primitives;
//  coalescing, ordering, and presentation cleanup live here.
//

import SpottyGateway
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation

extension PlaybackSessionRuntime {
    package func restore(expectedAccountEpoch: UInt64) async -> Bool {
        guard accountEpoch == expectedAccountEpoch else { return false }
        await restore()
        return true
    }

    package func logout(expectedAccountEpoch: UInt64) async -> Bool {
        guard accountEpoch == expectedAccountEpoch else { return false }
        await logout()
        return true
    }

    package func restore() async {
        guard lifecycle.acceptsWork else { return }
        let lifetime = playbackLifetime
        startLifetimeEffectsIfNeeded()
        let queueServiceBootstrap = effects.settlement(of: .queueServiceBootstrap)
        let preferencesRestore = effects.settlement(of: .preferencesRestore)
        await queueServiceBootstrap?.wait()
        guard stillCurrent(lifetime, scope: .account) else { return }
        await accountStore.restore()
        await preferencesRestore?.wait()
    }

    package func connect() {
        guard lifecycle.acceptsWork else { return }
        accountStore.connect()
    }

    package func reauthorize() {
        guard lifecycle.acceptsWork else { return }
        accountStore.reauthorize()
    }

    package func cancelConnect() {
        accountStore.cancelConnect()
    }

    package func logout() async {
        await endSession(clearGrant: true, finalPhase: .signedOut)
    }

    func handleGrantRevocation(_ revocation: AccountGrantRevocation) async {
        guard await accountStore.acceptsGrantRevocation(revocation) else { return }
        accountStore.markCredentialRejection()
        await endSession(
            clearGrant: false,
            finalPhase: .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
        )
    }

    /// The single account-teardown orchestration.
    ///
    /// Ordering guarantees, in this exact order: the account epoch advances before any reducer
    /// send, catalog update, queue reset, or effect invalidation, so every observer sees the
    /// already-advanced identity; and there is no suspension between the final intent comparison
    /// and releasing the teardown gate, so a later request either coalesces into this teardown or
    /// starts a genuinely new session boundary.
    func endSession(clearGrant: Bool, finalPhase: Phase) async {
        guard !lifecycle.isTerminating else { return }
        feedback.dismiss()
        guard
            let retirement = lifecycle.endAccount(
                SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase),
                prepare: prepareAccountRetirement
            )
        else { return }
        if !retirement.started {
            // Upgrade the visible result immediately, but keep the existing epoch and teardown.
            send(.reset(session: retirement.intent.finalPhase), source: .account)
            accountStore.publishPhase(retirement.intent.finalPhase)
        }
        await retirement.task.value
    }

    private func prepareAccountRetirement(_ cumulative: SessionTeardownIntent) -> Task<Void, Never> {
        invalidatePlaybackDispatchPermits()
        // Advance AccountStore.epoch before any reducer send, catalog update, queue reset,
        // or effect invalidation so every observer uses that already-advanced identity.
        let staleConnectionTask = accountStore.invalidateAccountIdentity()
        accountStore.publishPhase(cumulative.finalPhase)
        // Account shutdown can run while the runtime drains effects and clears presentation.
        let accountTeardown = Task { [accountStore] in
            await accountStore.performAccountTeardown(
                staleConnectionTask: staleConnectionTask,
                intent: cumulative
            )
        }
        // Commit the new engine identity before synchronous cancellation handlers inspect it.
        send(.reset(session: cumulative.finalPhase), source: .account, engineEpoch: engineGeneration &+ 1)
        preferenceState.retireAccount(to: accountEpoch)
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        let cancelledEffects = effects.cancelAccountScoped()
        hasReceivedPlaybackSnapshot = false
        catalogMetadata.reset()
        history.reset()
        queueMutation = nil
        queueReplacementToken = nil

        return Task { [weak self] in
            guard let self else { return }
            let drain = await self.effects.drain(cancelledEffects)
            self.report(effectDrain: drain, during: "account teardown")
            await self.completeEndSession(accountTeardown: accountTeardown)
        }
    }

    private func completeEndSession(
        accountTeardown: Task<SessionTeardownIntent, Never>
    ) async {
        await queueService.reset(accountEpoch: accountEpoch)
        var appliedIntent = await accountTeardown.value
        preferenceState.clearHistory()
        await preferenceState.flush()

        var clearedRemoteDevice = false
        while let desiredIntent = lifecycle.intent {
            if desiredIntent != appliedIntent {
                appliedIntent = await accountStore.applyStrongerIntent(
                    applied: appliedIntent,
                    desired: desiredIntent
                )
                continue
            }

            if desiredIntent.clearGrant, !clearedRemoteDevice {
                preferenceState.forgetRemoteDevice()
                await preferenceState.flush()
                clearedRemoteDevice = true
                continue
            }

            // There is no suspension between this final comparison and releasing the gate, so a
            // request either coalesces above or starts a genuinely new session boundary afterward.
            let completed = lifecycle.completeAccount() ?? desiredIntent
            send(.session(completed.finalPhase), source: .account)
            publish()
            return
        }
    }

    private func report(effectDrain: PlaybackEffectDrainReport, during operation: String) {
        guard !effectDrain.didSettleAll else { return }
        SpottyLog.account.warning(
            "\(operation, privacy: .public) continued with \(effectDrain.timedOut.count, privacy: .public) account effect(s) still unsettled"
        )
    }

    /// Performs the one process-termination shutdown. Streaming credentials remain intact for the
    /// next launch; account logout is a separate operation. It uses the same account primitives
    /// as `endSession` so there is still only one teardown owner.
    package func shutdownForTermination() async {
        let task = lifecycle.terminate(prepare: prepareTermination)
        await task.value
    }

    private func prepareTermination(_ accountRetirement: Task<Void, Never>?) -> Task<Void, Never> {
        preferenceState.prepareForTermination()
        var cancelledEffects: [PlaybackEffectID: PlaybackEffectSettlement] = [:]
        for id in [PlaybackEffectID.engineEvents, .grantRevocations, .lifecycle] {
            if let settlement = effects.cancel(id) {
                cancelledEffects[id] = settlement
            }
        }
        if let accountRetirement {
            // Sign-out already owns engine shutdown and durable credential removal. Quit
            // must join that owner before AppKit may end the process, and still retire the
            // process subscriptions that ordinary account teardown keeps alive.
            publish()
            return Task {
                let drain = await effects.drain(cancelledEffects)
                report(effectDrain: drain, during: "process termination")
                await accountRetirement.value
                await preferenceState.flush()
            }
        }
        feedback.dismiss()
        invalidatePlaybackDispatchPermits()
        let staleConnectionTask = accountStore.invalidateAccountIdentity()
        accountStore.publishPhase(.signedOut)
        send(.reset(session: .signedOut), source: .account, engineEpoch: engineGeneration &+ 1)
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        cancelledEffects.merge(effects.cancelAccountScoped()) { current, _ in current }
        return Task {
            let drain = await effects.drain(cancelledEffects)
            report(effectDrain: drain, during: "process termination")
            await accountStore.completeShutdownForTermination(staleConnectionTask: staleConnectionTask)
            await preferenceState.flush()
        }
    }
}

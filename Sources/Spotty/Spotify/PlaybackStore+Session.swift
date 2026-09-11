//
//  PlaybackStore+Session.swift
//  Spotty
//
//  The one session-teardown orchestration. AccountStore supplies narrow account primitives;
//  coalescing, ordering, and presentation cleanup live here.
//

import SpottyDomain
import Foundation

extension PlaybackStore {
    func restore() async {
        guard terminationGate.allowsCommands else { return }
        startLifetimeEffectsIfNeeded()
        let queueServiceBootstrap = effects.settlement(of: .queueServiceBootstrap)
        let preferencesRestore = effects.settlement(of: .preferencesRestore)
        await queueServiceBootstrap?.wait()
        guard terminationGate.allowsCommands else { return }
        await accountStore.restore()
        await preferencesRestore?.wait()
    }

    func connect() {
        guard !isTearingDown else { return }
        accountStore.connect()
    }

    func reauthorize() {
        guard !isTearingDown else { return }
        accountStore.reauthorize()
    }

    func cancelConnect() {
        accountStore.cancelConnect()
    }

    func logout() async {
        await endSession(clearGrant: true, finalPhase: .signedOut)
    }

    func handleGrantRevocation() async {
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
        guard terminationGate.allowsCommands else { return }
        feedback.dismiss()
        let (shouldStart, cumulative) = teardown.request(
            SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        )

        if !shouldStart {
            // Upgrade the visible result immediately, but keep the existing epoch and teardown.
            send(.reset(session: cumulative.finalPhase), source: .account)
            accountStore.publishPhase(cumulative.finalPhase)
            await teardown.awaitActive()
            return
        }

        isTearingDown = true
        accountStore.isTearingDown = true
        invalidatePlaybackDispatchPermits()
        // Advance AccountStore.epoch before any reducer send, catalog update, queue reset,
        // or effect invalidation so every observer uses that already-advanced identity.
        let staleConnectionTask = accountStore.invalidateAccountIdentity()
        accountStore.publishPhase(cumulative.finalPhase)
        // The account-side shutdown runs concurrently with presentation cleanup, the effect
        // drain, and the queue reset, exactly as the previous two-owner split did.
        let accountTeardown = Task { [accountStore] in
            await accountStore.performAccountTeardown(
                staleConnectionTask: staleConnectionTask,
                intent: cumulative
            )
        }
        engineGeneration &+= 1
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        let cancelledEffects = effects.cancelAccountScoped()
        hasReceivedPlaybackSnapshot = false
        catalog.reset()
        history.reset()
        queueMutation = nil
        queueReplacementToken = nil
        shuffleHistoryCache = [:]
        send(.reset(session: cumulative.finalPhase), source: .account)

        let task = Task { [weak self] in
            guard let self else { return }
            let drain = await self.effects.drain(cancelledEffects)
            self.report(effectDrain: drain, during: "account teardown")
            await self.completeEndSession(accountTeardown: accountTeardown)
        }
        teardown.setActiveTask(task)
        await task.value
    }

    private func completeEndSession(
        accountTeardown: Task<SessionTeardownIntent, Never>
    ) async {
        await queueService.reset(accountEpoch: accountEpoch)
        var appliedIntent = await accountTeardown.value
        await preferenceWriter.submit(epoch: accountEpoch) { await $0.setShuffleHistory([:]) }.value

        var clearedRemoteDevice = false
        while let desiredIntent = teardown.intent {
            if desiredIntent != appliedIntent {
                appliedIntent = await accountStore.applyStrongerIntent(
                    applied: appliedIntent,
                    desired: desiredIntent
                )
                continue
            }

            if desiredIntent.clearGrant, !clearedRemoteDevice {
                lastRemoteDeviceID = nil
                await preferenceWriter.submit(epoch: accountEpoch) { await $0.setLastRemoteDeviceID(nil) }.value
                clearedRemoteDevice = true
                continue
            }

            // There is no suspension between this final comparison and releasing the gate, so a
            // request either coalesces above or starts a genuinely new session boundary afterward.
            let completed = teardown.complete() ?? desiredIntent
            send(.session(completed.finalPhase), source: .account)
            releaseTeardownGate()
            return
        }

        // Defensive recovery for an impossible externally-cleared coalescer.
        teardown.setActiveTask(nil)
        releaseTeardownGate()
    }

    private func releaseTeardownGate() {
        isTearingDown = false
        accountStore.isTearingDown = false
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
    func shutdownForTermination() async {
        guard terminationGate.begin() else { return }
        guard !isTearingDown else { return }
        feedback.dismiss()
        isTearingDown = true
        accountStore.isTearingDown = true
        invalidatePlaybackDispatchPermits()
        let staleConnectionTask = accountStore.invalidateAccountIdentity()
        accountStore.publishPhase(.signedOut)
        engineGeneration &+= 1
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        var cancelledEffects = effects.cancelAccountScoped()
        for id in [PlaybackEffectID.engineEvents, .grantRevocations, .lifecycle] {
            if let settlement = effects.cancel(id) {
                cancelledEffects[id] = settlement
            }
        }
        send(.reset(session: .signedOut), source: .account)
        let drain = await effects.drain(cancelledEffects)
        report(effectDrain: drain, during: "process termination")
        await accountStore.completeShutdownForTermination(staleConnectionTask: staleConnectionTask)
    }
}

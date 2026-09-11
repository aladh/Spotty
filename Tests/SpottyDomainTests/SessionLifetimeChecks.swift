import Testing
import SpottyDomain
import Foundation

@Suite("Session Lifetime")
struct SessionLifetimeTests {
    @Test
    func sessionTeardownIntentsMergeIntoTheStrongerRequest() {
        let revoked = SessionTeardownIntent(
            clearGrant: false,
            finalPhase: .failed("expired")
        )
        let logout = SessionTeardownIntent(clearGrant: true, finalPhase: .signedOut)

        var revocationFirst = SessionTeardownCoalescer()
        #expect((revocationFirst.request(revoked)) == true, "first request owns the teardown")
        #expect((!revocationFirst.request(logout)) == true, "overlapping logout joins the existing teardown")
        #expect((revocationFirst.intent?.clearGrant) == (true), "logout upgrades grant clearing")
        #expect((revocationFirst.intent?.finalPhase) == (.signedOut), "logout wins the final phase")
        #expect((revocationFirst.complete()) == (logout), "completion returns the cumulative intent")
        #expect((!revocationFirst.isActive) == true, "completion releases the single-flight gate")
        #expect((revocationFirst.request(revoked)) == true, "a later boundary can start")

        var logoutFirst = SessionTeardownCoalescer()
        #expect((logoutFirst.request(logout)) == true, "logout can own the teardown")
        #expect((!logoutFirst.request(revoked)) == true, "late revocation is coalesced")
        #expect((logoutFirst.intent) == (logout), "revocation cannot downgrade grant clearing")
    }

    @Test
    func accountScopedRequestIdentitiesGateResultsByLifetime() {
        let captured = AccountScopedRequestIdentity(
            requestID: 7,
            accountEpoch: 3,
            sessionRevision: 11
        )
        #expect(
            (captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )) == true, "current result is accepted")
        #expect(
            (!captured.isCurrent(
                requestID: 8,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )) == true, "superseded request result is rejected")
        #expect(
            (!captured.isCurrent(
                requestID: 7,
                accountEpoch: 4,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )) == true, "previous account result is rejected")
        #expect(
            (!captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 13,
                isAvailable: true,
                isCancelled: false
            )) == true, "result from before a disconnect-reconnect cycle is rejected")
        #expect(
            (!captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: false,
                isCancelled: false
            )) == true, "unavailable session rejects results")
        #expect(
            (!captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: true
            )) == true, "cancelled task rejects results")
    }

    @Test
    func cancellationIsRecognizedAcrossErrorShapes() {
        #expect((isCancellation(CancellationError())) == true, "CancellationError is cancellation")
        #expect((isCancellation(URLError(.cancelled))) == true, "URLError.cancelled is cancellation")
        #expect(
            (!isCancellation(URLError(.badServerResponse))) == true,
            "a failed catalog transport is not cancellation")
        enum CatalogCheckFailure: Error { case unavailable }
        #expect((!isCancellation(CatalogCheckFailure.unavailable)) == true, "an ordinary error is not cancellation")
    }

    @Test
    func connectQueueCallbackWatermarkTracksGenerationAndRevision() {
        var watermark = ConnectQueueCallbackWatermark()
        #expect(
            (watermark.accept(generation: 2, revision: 4, engineEpoch: 1)) == true,
            "the first callback is accepted before the engine epoch catches up")
        #expect((watermark.generation) == (2), "the callback generation is stored independently")
        #expect((watermark.revision) == (4), "the callback revision is stored")

        let afterFirst = watermark
        #expect(
            (!watermark.accept(generation: 2, revision: 4, engineEpoch: 1)) == true,
            "a duplicate revision in the same generation is rejected")
        #expect((watermark) == (afterFirst), "a rejected duplicate does not clear the watermark")
        #expect(
            (!watermark.accept(generation: 2, revision: 3, engineEpoch: 1)) == true,
            "an older revision in the same generation is rejected")
        #expect((watermark) == (afterFirst), "an older revision does not reopen the generation")

        #expect(
            (!watermark.accept(generation: 2, revision: 1, engineEpoch: 2)) == true,
            "adopting the same engine epoch later does not reset the watermark")
        #expect((watermark) == (afterFirst), "the watermark survives the engine epoch catching up")
        #expect(
            (watermark.accept(generation: 2, revision: 5, engineEpoch: 2)) == true,
            "a newer revision in the stored generation is still accepted")

        #expect(
            (!watermark.accept(generation: 1, revision: 9, engineEpoch: 2)) == true,
            "a previous engine generation is rejected after a newer callback generation")
        #expect(
            (watermark.accept(generation: 3, revision: 0, engineEpoch: 2)) == true,
            "a newer callback generation starts a fresh revision namespace")
        #expect((watermark.generation) == (3), "the new callback generation is recorded")
        #expect((watermark.revision) == (0), "the new generation accepts its initial zero revision")
        #expect(
            (!watermark.accept(generation: 3, revision: 0, engineEpoch: 2)) == true,
            "a duplicate zero revision in the same generation is rejected")
        #expect(
            (watermark.accept(generation: 3, revision: 1, engineEpoch: 2)) == true,
            "the new generation can advance after its zero revision")
        #expect((watermark.revision) == (1), "the new generation accepts a restarted revision")

        watermark.reset()
        #expect(
            (watermark.accept(generation: nil, revision: 9, engineEpoch: 4)) == true,
            "a missing generation still records revision against a later engine epoch")
        #expect((watermark.generation) == (0), "the unstamped generation leaves the previous generation at zero")
        #expect((watermark.revision) == (9), "the recorded revision would block a later restarted callback")
        watermark.reset()
        #expect((watermark.generation) == (0), "reset clears the callback generation")
        #expect((watermark.revision) == (0), "reset clears the callback revision")
        #expect(
            (!watermark.accept(generation: 2, revision: 1, engineEpoch: 3)) == true,
            "a later engine epoch rejects a stale callback generation")
        #expect(
            (watermark.accept(generation: 3, revision: 1, engineEpoch: 3)) == true,
            "a callback matching the later engine epoch is accepted")
    }

    @Test
    func playbackCommandAdmissionRefusesTeardownAndDuplicates() {
        #expect(
            (playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: true,
                hasPendingCommandForKind: false
            )) == true, "an idle live session admits a command")
        #expect(
            (!playbackCommandShouldAdmit(
                isTearingDown: true,
                allowsCommands: true,
                hasPendingCommandForKind: false
            )) == true, "teardown refuses admission")
        #expect(
            (!playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: false,
                hasPendingCommandForKind: false
            )) == true, "a started termination gate refuses admission")
        #expect(
            (!playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: true,
                hasPendingCommandForKind: true
            )) == true, "a pending command of the same kind refuses admission")
    }

    @Test
    func commandFollowUpFollowsAcceptanceAndOutcome() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        func followUp(
            finishAccepted: Bool,
            succeeded: Bool,
            reconnect: Bool = false,
            kind: PlaybackCommandKind = .transport,
            pending: UUID? = nil,
            resolution: PlaybackTransportCommandResolution? = nil,
            account: UInt64 = 1,
            engine: UInt64 = 1,
            currentAccount: UInt64 = 1,
            currentEngine: UInt64 = 1,
            tearingDown: Bool = false
        ) -> PlaybackCommandFollowUp {
            playbackCommandFollowUp(
                finishAccepted: finishAccepted,
                operationSucceeded: succeeded,
                requiresReconnect: reconnect,
                commandKind: kind,
                pendingCommandID: pending,
                finishedCommandResolution: resolution,
                capturedLifetime: PlaybackLifetime(
                    accountEpoch: account,
                    engineGeneration: engine
                ),
                currentLifetime: PlaybackLifetime(
                    accountEpoch: currentAccount,
                    engineGeneration: currentEngine
                ),
                isTearingDown: tearingDown
            )
        }

        #expect(
            (followUp(finishAccepted: true, succeeded: true)) == (.reportSuccess),
            "an accepted success reports success"
        )
        #expect(
            (followUp(finishAccepted: true, succeeded: false, reconnect: true))
                == (.reportFailure(reconnect: true)),
            "an accepted reconnect-required failure reports reconnect")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, reconnect: true, resolution: .confirmed))
                == (.reportSuccess),
            "a matching snapshot then successful finish still reports success")
        #expect(
            (followUp(finishAccepted: false, succeeded: false, reconnect: false, resolution: .confirmed))
                == (.reportSuccess),
            "already-reconciled transport success with an ordinary failure reports success")
        #expect(
            (followUp(finishAccepted: false, succeeded: false, reconnect: true, resolution: .confirmed))
                == (.reconnectAfterReconciledSuccess),
            "already-reconciled transport success with a reconnect-required failure keeps presentation and reconnects"
        )
        #expect(
            (followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .options)) == (.inert),
            "a non-transport kind with no pending command stays inert")
        #expect(
            (followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .seek)) == (.inert),
            "a late seek finish after pending was cleared stays inert")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, reconnect: true, currentEngine: 2)) == (.inert),
            "engine-epoch invalidation stays inert")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, reconnect: true, currentAccount: 2)) == (.inert),
            "account-epoch invalidation stays inert")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, pending: other)) == (.inert),
            "a superseded id stays inert")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, tearingDown: true)) == (.inert),
            "teardown stays inert")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                resolution: .confirmed
            )) == (.reportSuccess), "a confirmed play target still reports success after an ordinary late failure")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .confirmed
            )) == (.reconnectAfterReconciledSuccess),
            "a confirmed play target keeps presentation but reconnects after a reconnect-required failure")
        #expect(
            (followUp(finishAccepted: false, succeeded: true, reconnect: true, resolution: .confirmed))
                == (.reportSuccess), "a confirmed command that succeeded never reconnects")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .superseded
            )) == (.inert), "a superseded play target stays inert after a late failure")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                pending: other,
                resolution: .superseded
            )) == (.inert), "a superseded play stays inert after a later pause is pending")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .superseded
            )) == (.inert), "a superseded play stays inert after a later pause cleared pending")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .transfer,
                resolution: .confirmed
            )) == (.reportSuccess), "a confirmed transfer still reports success after an ordinary late failure")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: true,
                reconnect: true,
                kind: .transfer,
                resolution: .superseded
            )) == (.inert), "a superseded transfer stays inert after an accepted coordinator result")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                pending: other,
                resolution: .confirmed
            )) == (.reportSuccess),
            "a confirmed play still reports success (ordinary failure) while a later pause is pending")
        #expect(
            (followUp(finishAccepted: true, succeeded: false, reconnect: true))
                == (.reportFailure(reconnect: true)),
            "consume-only acceptance without a captured resolution still reports failure")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .confirmed,
                currentEngine: 2
            )) == (.inert), "a confirmed play is inert after an engine-epoch invalidation")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                resolution: .confirmed,
                tearingDown: true
            )) == (.inert), "a confirmed play is inert during teardown")
        #expect(
            (followUp(finishAccepted: true, succeeded: false, reconnect: true, kind: .options))
                == (.reportFailure(reconnect: true)),
            "options reconnect-required after an accepted finish reports reconnect")
        #expect(
            (followUp(finishAccepted: true, succeeded: false, reconnect: true, kind: .transfer))
                == (.reportFailure(reconnect: true)),
            "transfer reconnect-required after an accepted finish reports reconnect")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .options,
                resolution: .confirmed
            )) == (.reportSuccess), "a confirmed shuffle still reports success after an ordinary late failure")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .options,
                pending: other,
                resolution: .confirmed
            )) == (.reportSuccess),
            "a confirmed shuffle still reports success (ordinary failure) while a later options command is pending")
        #expect(
            (followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                kind: .options,
                resolution: .confirmed,
                currentEngine: 2
            )) == (.inert), "a confirmed shuffle is inert after an engine-epoch invalidation")
        #expect(
            (followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .options)) == (.inert),
            "an options finish without a captured resolution stays inert when pending is gone")
    }

    @Test
    func cancelledCommandsSettleOnlyWithinTheirOwnLifetime() {
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-00000000009A")!
        func shouldSettle(
            pending: UUID? = commandID,
            cancelled: UUID = commandID,
            account: UInt64 = 1,
            engine: UInt64 = 1,
            currentAccount: UInt64 = 1,
            currentEngine: UInt64 = 1,
            tearingDown: Bool = false
        ) -> Bool {
            playbackCommandShouldSettleOrdinaryCancellation(
                pendingCommandID: pending,
                cancelledCommandID: cancelled,
                capturedLifetime: PlaybackLifetime(
                    accountEpoch: account,
                    engineGeneration: engine
                ),
                currentLifetime: PlaybackLifetime(
                    accountEpoch: currentAccount,
                    engineGeneration: currentEngine
                ),
                isTearingDown: tearingDown
            )
        }

        #expect((shouldSettle()) == true, "a matching same-lifetime cancel settles")
        #expect((!shouldSettle(pending: nil)) == true, "a missing pending command stays inert")
        #expect((!shouldSettle(pending: other)) == true, "a newer pending command stays inert")
        #expect((!shouldSettle(cancelled: other)) == true, "a different cancelled id stays inert")
        #expect((!shouldSettle(currentEngine: 2)) == true, "engine-epoch invalidation stays inert")
        #expect((!shouldSettle(currentAccount: 2)) == true, "account-epoch invalidation stays inert")
        #expect((!shouldSettle(tearingDown: true)) == true, "teardown stays inert")
    }

    @Test
    func undispatchedCommandsSettleOnlyWithinTheirOwnLifetime() {
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-00000000009B")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-00000000009C")!
        func shouldSettle(
            pending: UUID? = commandID,
            undispatched: UUID = commandID,
            account: UInt64 = 1,
            engine: UInt64 = 1,
            currentAccount: UInt64 = 1,
            currentEngine: UInt64 = 1,
            tearingDown: Bool = false
        ) -> Bool {
            playbackCommandShouldSettleUndispatched(
                pendingCommandID: pending,
                undispatchedCommandID: undispatched,
                capturedLifetime: PlaybackLifetime(
                    accountEpoch: account,
                    engineGeneration: engine
                ),
                currentLifetime: PlaybackLifetime(
                    accountEpoch: currentAccount,
                    engineGeneration: currentEngine
                ),
                isTearingDown: tearingDown
            )
        }

        #expect((shouldSettle()) == true, "a matching same-lifetime undispatched command settles")
        #expect((!shouldSettle(pending: nil)) == true, "a missing pending command stays inert")
        #expect((!shouldSettle(pending: other)) == true, "a newer pending command stays inert")
        #expect((!shouldSettle(undispatched: other)) == true, "a different undispatched id stays inert")
        #expect((!shouldSettle(currentEngine: 2)) == true, "engine-epoch invalidation stays inert")
        #expect((!shouldSettle(currentAccount: 2)) == true, "account-epoch invalidation stays inert")
        #expect((!shouldSettle(tearingDown: true)) == true, "teardown stays inert")
    }
}

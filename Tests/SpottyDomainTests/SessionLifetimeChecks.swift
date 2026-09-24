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
        let lifetime = PlaybackLifetime(accountEpoch: 1, engineGeneration: 1)
        let cases:
            [(
                accepted: Bool,
                succeeded: Bool,
                reconnect: Bool,
                resolution: PlaybackTransportCommandResolution?,
                expected: PlaybackCommandFollowUp
            )] = [
                (true, true, false, nil, .reportSuccess),
                (true, false, false, nil, .reportFailure(reconnect: false)),
                (true, false, true, nil, .reportFailure(reconnect: true)),
                (false, true, false, nil, .inert),
                (false, false, true, nil, .inert),
                (false, true, true, .confirmed, .reportSuccess),
                (false, false, false, .confirmed, .reportSuccess),
                (false, false, true, .confirmed, .reconnectAfterReconciledSuccess),
                (true, false, false, .confirmed, .reportSuccess),
                (true, false, true, .confirmed, .reconnectAfterReconciledSuccess),
                (true, false, true, .superseded, .inert),
                (true, true, true, .superseded, .inert),
            ]

        for test in cases {
            #expect(
                playbackCommandFollowUp(
                    finishAccepted: test.accepted,
                    operationSucceeded: test.succeeded,
                    requiresReconnect: test.reconnect,
                    finishedCommandResolution: test.resolution,
                    capturedLifetime: lifetime,
                    currentLifetime: lifetime,
                    isTearingDown: false
                ) == test.expected
            )
        }
    }

    @Test
    func invalidatedCommandFollowUpsStayInertRegardlessOfResolution() {
        let captured = PlaybackLifetime(accountEpoch: 1, engineGeneration: 1)
        let invalidations: [(current: PlaybackLifetime, tearingDown: Bool)] = [
            (PlaybackLifetime(accountEpoch: 2, engineGeneration: 1), false),
            (PlaybackLifetime(accountEpoch: 1, engineGeneration: 2), false),
            (captured, true),
        ]
        let resolutions: [PlaybackTransportCommandResolution?] = [nil, .confirmed, .superseded]

        for invalidation in invalidations {
            for resolution in resolutions {
                for succeeded in [true, false] {
                    #expect(
                        playbackCommandFollowUp(
                            finishAccepted: true,
                            operationSucceeded: succeeded,
                            requiresReconnect: true,
                            finishedCommandResolution: resolution,
                            capturedLifetime: captured,
                            currentLifetime: invalidation.current,
                            isTearingDown: invalidation.tearingDown
                        ) == .inert
                    )
                }
            }
        }
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

import SpottyTestSupport
import Foundation
import Testing
import Synchronization
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Keymaster Persistence")
struct KeymasterPersistenceTests {
    @Test @MainActor
    func explicitClearInvalidatesAnAlreadyQueuedRevocation() async throws {
        let session = KeymasterSession(
            store: GatewayGrantStore(), refresher: { _ in throw KeymasterAuthError.grantRevoked },
            cookieCleanup: {})
        var notifications = session.grantRevocations().makeAsyncIterator()
        try await session.adopt(gatewayTokens(expiresAt: .distantPast))
        await #expect(throws: KeymasterSessionError.grantRevoked) { try await session.accessToken() }
        let notification = try #require(await notifications.next())
        #expect(await session.isCurrent(notification))
        #expect(await session.isCurrent(AccountGrantRevocation()) == false)

        #expect(await session.clear())

        #expect(await session.isCurrent(notification) == false)
    }

    @Test @MainActor func slowRevocationReadersRetainOnlyOnePendingInvalidation() async throws {
        var session: KeymasterSession? = KeymasterSession(
            store: GatewayGrantStore(), refresher: { _ in throw KeymasterAuthError.grantRevoked },
            cookieCleanup: {})
        let stream = try #require(session).grantRevocations()
        for _ in 0..<4 {
            try await session?.adopt(gatewayTokens(expiresAt: .distantPast))
            await #expect(throws: KeymasterSessionError.grantRevoked) { try await session?.accessToken() }
        }
        session = nil

        var delivered = 0
        for await _ in stream { delivered += 1 }
        #expect(delivered == 1)
    }

    @Test @MainActor func disposingSessionFinishesRetainedRevocationReaders() async throws {
        var session: KeymasterSession? = KeymasterSession(store: GatewayGrantStore(), cookieCleanup: {})
        let stream = try #require(session).grantRevocations()
        weak let owner = session
        var finished = false
        let reader = Task {
            for await _ in stream {}
            finished = true
        }
        defer { reader.cancel() }

        session = nil

        #expect(owner == nil)
        try await requireEventually(description: "disposed credential session finishes retained revocation readers") {
            finished
        }
        await reader.value
    }

    @Test(arguments: [false, true]) @MainActor
    func completedRemovalSurvivesFailedAdoption(removed: Bool) async throws {
        let store = GatedPersistenceStore(
            failClear: !removed, parkClear: true, failReplacementSave: true)
        defer { store.releaseFirstSave(); store.releaseClear() }
        store.releaseFirstSave()
        let cookies = Mutex(0)
        let session = KeymasterSession(store: store, cookieCleanup: { cookies.withLock { $0 += 1 } })
        let old = persistenceGrant(access: "old", refresh: "old-refresh")
        try await session.adopt(old)
        let removal = Task { await session.clear() }
        defer { removal.cancel() }
        try await requireEventually { store.hasEnteredClear }
        let clearingGeneration = await session.credentialGeneration
        let adoption = Task {
            try await session.adopt(persistenceGrant(access: "replacement", refresh: "replacement-refresh"))
        }
        defer { adoption.cancel() }
        try await requireEventually { await session.credentialGeneration != clearingGeneration }

        store.releaseClear()
        #expect(await removal.value == removed)
        await #expect(throws: GatewayGrantStore.Failure.saveRejected) { try await adoption.value }

        #expect(await session.grantState == (removed ? .absent : .removalFailed))
        #expect(await session.hasGrant == false)
        #expect(store.stored == (removed ? nil : old))
        // A new authorization began; its cookies cannot be distinguished from the old jar.
        #expect(cookies.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedRotationSaveRetriesPersistenceWithoutSpendingTheOldTokenAgain(forced: Bool) async throws {
        let store = GatewayGrantStore()
        let spent = Mutex<[String]>([])
        let session = KeymasterSession(
            store: store,
            refresher: { refresh in
                let count = spent.withLock { values in
                    values.append(refresh)
                    return values.count
                }
                return persistenceGrant(access: "rotated-\(count)", refresh: "replacement-\(count)")
            }, cookieCleanup: {})
        try await session.adopt(
            persistenceGrant(access: "original-access", refresh: "original-refresh", expiresAt: .distantPast))
        store.failSaves = true
        for _ in 0..<2 {
            await #expect(throws: GatewayGrantStore.Failure.saveRejected) {
                if forced {
                    _ = try await session.refreshIgnoringExpiry(rejected: "original-access")
                } else {
                    _ = try await session.accessToken()
                }
            }
        }
        store.failSaves = false

        let token =
            if forced { try await session.refreshIgnoringExpiry(rejected: "original-access") } else {
                try await session.accessToken()
            }

        #expect(token == "rotated-1")
        #expect(spent.withLock { $0 } == ["original-refresh"])
        #expect(store.stored?.refreshToken == "replacement-1")
    }

    @Test(arguments: [false, true]) @MainActor
    func pendingRotationSurvivesFailedAdoptionAndMarkerWrites(markReauthentication: Bool) async throws {
        let store = GatewayGrantStore()
        let spends = Mutex(0)
        let rotated = persistenceGrant(access: "rotated", refresh: "rotated-refresh")
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                spends.withLock { $0 += 1 }
                return rotated
            }, cookieCleanup: {})
        try await session.adopt(
            persistenceGrant(access: "old", refresh: "old-refresh", expiresAt: .distantPast))
        store.failSaves = true
        await #expect(throws: GatewayGrantStore.Failure.saveRejected) { try await session.accessToken() }

        if markReauthentication {
            await session.markReauthenticationRequired()
        } else {
            await #expect(throws: GatewayGrantStore.Failure.saveRejected) {
                try await session.adopt(persistenceGrant(access: "unsaved-sign-in", refresh: "unsaved-sign-in-refresh"))
            }
        }
        store.failSaves = false

        #expect(try await session.accessToken() == rotated.accessToken)
        #expect(spends.withLock { $0 } == 1)
        #expect(store.stored?.refreshToken == rotated.refreshToken)
        #expect(store.stored?.requiresReauthentication == markReauthentication)
        #expect(await session.reauthenticationRequired() == markReauthentication)
    }

    @Test(arguments: [false, true]) @MainActor
    func accountReplacementOwnsPersistenceAfterALateRotationSaveFailure(adopt: Bool) async throws {
        let original = persistenceGrant(access: "old", refresh: "old-refresh", expiresAt: .distantPast)
        let store = GatedPersistenceStore(stored: original, failFirstSave: true)
        defer { store.releaseFirstSave(); store.releaseClear() }
        let session = KeymasterSession(
            store: store,
            refresher: { _ in persistenceGrant(access: "stale-rotation", refresh: "stale-rotation-refresh") },
            cookieCleanup: {})
        let generation = await session.credentialGeneration
        let refresh = Task { try await session.accessToken(expectedGeneration: generation) }
        defer { refresh.cancel() }
        try await requireEventually { store.hasEnteredFirstSave }
        let replacement = persistenceGrant(access: "new-account", refresh: "new-account-refresh")
        let transition = Task {
            if adopt { try await session.adopt(replacement) } else { #expect(await session.clear()) }
        }
        defer { transition.cancel() }
        try await requireEventually { await session.credentialGeneration != generation }

        store.releaseFirstSave()
        await #expect(throws: KeymasterSessionError.noGrant) { try await refresh.value }
        try await transition.value

        if adopt {
            #expect(try await session.accessToken() == replacement.accessToken)
            #expect(store.stored == replacement)
        } else {
            await #expect(throws: KeymasterSessionError.noGrant) { try await session.accessToken() }
            #expect(store.stored == nil)
        }
    }

    @Test @MainActor
    func lateRemovalFailureDoesNotFenceAReplacementGrantOrClearItsCookies() async throws {
        let store = GatedPersistenceStore(failClear: true)
        defer { store.releaseFirstSave(); store.releaseClear() }
        store.releaseFirstSave()
        let cookies = Mutex(0)
        let session = KeymasterSession(store: store, cookieCleanup: { cookies.withLock { $0 += 1 } })
        try await session.adopt(persistenceGrant(access: "old", refresh: "old-refresh"))
        let removal = Task { await session.clear() }
        defer { removal.cancel() }
        try await requireEventually { store.hasEnteredClear }
        let clearingGeneration = await session.credentialGeneration
        let replacement = persistenceGrant(access: "replacement", refresh: "replacement-refresh")
        let adoption = Task { try await session.adopt(replacement) }
        defer { adoption.cancel() }
        try await requireEventually { await session.credentialGeneration != clearingGeneration }

        store.releaseClear()
        #expect(await removal.value == false)
        try await adoption.value

        #expect(await session.retryGrantState() == .available)
        #expect(try await session.accessToken() == replacement.accessToken)
        #expect(store.stored == replacement)
        #expect(cookies.withLock { $0 } == 0)
    }

    @Test
    func testWorkerOrdersOverlappingDurableWrites() async throws {
        let store = GatedPersistenceStore()
        defer { store.releaseFirstSave(); store.releaseClear() }
        let worker = KeymasterPersistenceWorker(store: store)
        let first = worker.submitSave(persistenceGrant(access: "first", refresh: "first-refresh"))
        try await requireEventually { store.hasEnteredFirstSave }
        let clear = worker.submitClear()
        let replacement = persistenceGrant(access: "replacement", refresh: "replacement-refresh")
        let second = worker.submitSave(replacement)
        let read = worker.submitLoad()
        // All operations are submitted before the blocked first save can complete.
        store.releaseFirstSave()
        try await first.value().get()
        try await clear.value().get()
        try await second.value().get()
        #expect(await read.value() == .found(replacement))
        #expect(store.stored == replacement)
    }

    @Test @MainActor
    func testKeymasterPersistence() async {
        let sentinel = "SPOTTY_PRIVACY_SENTINEL_stored-grant_9b2e"
        let payload = Data("{\"access_token\":\"\(sentinel)\"}".utf8)
        #expect(KeymasterStoredGrantCodec.decode(payload) == nil, "corrupt secure blobs fail closed")
        #expect(KeymasterGrantPersistenceDiagnostics.unreadableGrant == "Stored grant is unreadable source=file")
        #expect(!KeymasterGrantPersistenceDiagnostics.unreadableGrant.contains(sentinel))

        let secure = GatewayGrantStore()
        let session = KeymasterSession(
            store: secure,
            refresher: { refreshToken in
                persistenceGrant(access: "rotated-at", refresh: "rotated-\(refreshToken)")
            },
            cookieCleanup: {}
        )
        do {
            try await session.adopt(
                persistenceGrant(
                    access: "adopted-at",
                    refresh: "adopted-rt",
                    expiresAt: Date(timeIntervalSince1970: 1)
                ))
        } catch {
            Issue.record("adopt saves securely: unexpected error \(error)")
        }
        #expect((try? await session.accessToken(now: Date(timeIntervalSince1970: 1_000))) == "rotated-at")
        #expect(secure.stored?.refreshToken == "rotated-adopted-rt")

        let restoredSession = KeymasterSession(
            store: secure,
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        #expect((try? await restoredSession.accessToken()) == "rotated-at")

        #expect(await session.clear())
        #expect(secure.stored == nil)
    }

    @Test(arguments: [KeymasterGrantLoadResult.denied, .failed, .absent])
    @MainActor func storedReadOutcomesStayDistinctWithoutClearingTheGrant(outcome: KeymasterGrantLoadResult) async {
        let existing = outcome == .absent ? nil : persistenceGrant(access: "existing-at", refresh: "existing-rt")
        let store = GatewayGrantStore(stored: existing, readOutcome: outcome, failSaves: true)
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let expected: KeymasterGrantState = outcome == .denied ? .denied : outcome == .failed ? .failed : .absent

        #expect(await session.grantState == expected)
        #expect(await session.hasGrant == false)
        #expect(store.stored == existing, "read failures preserve the durable grant")
        #expect(store.clearCount == 0, "reads never trigger credential deletion")
    }

    @Test @MainActor func failedFirstAdoptionPublishesNoGrant() async {
        let store = GatewayGrantStore(failSaves: true)
        let session = KeymasterSession(store: store, cookieCleanup: {})
        await #expect(throws: GatewayGrantStore.Failure.saveRejected) {
            try await session.adopt(persistenceGrant(access: "failed-at", refresh: "failed-rt"))
        }
        #expect(store.stored == nil)
        #expect(await session.grantState == .absent)
    }

    @Test @MainActor func replacementIsDurableAfterSaveClearSave() async throws {
        let store = GatedPersistenceStore()
        defer { store.releaseFirstSave(); store.releaseClear() }
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let firstGrant = persistenceGrant(access: "first-at", refresh: "first-rt")
        let replacement = persistenceGrant(access: "replacement-at", refresh: "replacement-rt")
        let first = Task { try await session.adopt(firstGrant) }
        defer { first.cancel() }
        try await requireEventually { store.hasEnteredFirstSave }
        #expect(store.stored == nil, "the pending save has not published a durable grant")
        store.releaseFirstSave()
        try await first.value
        #expect(store.stored == firstGrant)

        #expect(await session.clear())
        #expect(store.stored == nil)
        try await session.adopt(replacement)
        #expect(store.stored == replacement)
        #expect(try await session.accessToken() == replacement.accessToken)
    }

    @Test @MainActor func lateAdoptionCannotRestoreASignedOutGrant() async throws {
        let store = GatedPersistenceStore()
        defer { store.releaseFirstSave(); store.releaseClear() }
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let adoption = Task { try await session.adopt(persistenceGrant(access: "stale-at", refresh: "stale-rt")) }
        defer { adoption.cancel() }
        try await requireEventually { store.hasEnteredFirstSave }
        let adoptingGeneration = await session.credentialGeneration
        let clear = Task { await session.clear() }
        defer { clear.cancel() }
        // Prove sign-out owns the generation while the old save is still blocked on the worker.
        try await requireEventually { await session.credentialGeneration != adoptingGeneration }

        store.releaseFirstSave()
        try await adoption.value
        #expect(await clear.value)

        #expect(store.stored == nil)
        #expect(await session.grantState == .absent)
        #expect(await session.hasGrant == false)
        await #expect(throws: KeymasterSessionError.noGrant) { try await session.accessToken() }
    }

    @Test(arguments: [false, true]) @MainActor
    func supersededAdoptionCannotRetireItsReplacement(failFirstSave: Bool) async throws {
        let store = GatedPersistenceStore(failFirstSave: failFirstSave, parkReplacementSave: true)
        defer { store.releaseFirstSave(); store.releaseReplacementSave(); store.releaseClear() }
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let first = Task { try await session.adopt(persistenceGrant(access: "first", refresh: "first-refresh")) }
        defer { first.cancel() }
        try await requireEventually { store.hasEnteredFirstSave }
        let firstGeneration = await session.credentialGeneration
        let latest = persistenceGrant(access: "latest", refresh: "latest-refresh")
        let second = Task { try await session.adopt(latest) }
        defer { second.cancel() }
        try await requireEventually { await session.credentialGeneration != firstGeneration }

        store.releaseFirstSave()
        try await requireEventually { store.hasEnteredReplacementSave }
        // A superseded failure is also inert. Neither path may retire the second operation.
        try await first.value
        store.releaseReplacementSave()
        try await second.value

        #expect(store.stored == latest)
        #expect(try await session.accessToken() == latest.accessToken)
        #expect(await session.grantState == .available)
    }

    @Test @MainActor func clearingAdoptionReleasesTokenReadersBeforeItsSaveSettles() async throws {
        let store = GatedPersistenceStore()
        defer { store.releaseFirstSave(); store.releaseClear() }
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let adoption = Task { try await session.adopt(persistenceGrant(access: "old", refresh: "old-refresh")) }
        defer { adoption.cancel() }
        try await requireEventually { store.hasEnteredFirstSave }
        let generation = await session.credentialGeneration
        var readerIssued = false
        var readerFinished = false
        let reader = Task {
            readerIssued = true
            await #expect(throws: KeymasterSessionError.noGrant) { try await session.accessToken() }
            readerFinished = true
        }
        defer { reader.cancel() }
        try await requireEventually { readerIssued }
        let clearing = Task { await session.clear() }
        defer { clearing.cancel() }
        try await requireEventually { await session.credentialGeneration != generation }
        try await requireEventually(description: "sign-out releases token readers before disk work settles") {
            readerFinished
        }
        #expect(store.hasEnteredClear == false, "clear is still queued behind the parked save")
        await reader.value

        store.releaseFirstSave()
        try await adoption.value
        #expect(await clearing.value)
        #expect(store.stored == nil)
    }

}

private func persistenceGrant(access: String, refresh: String, expiresAt: Date = Date().addingTimeInterval(3_600))
    -> KeymasterTokens
{
    KeymasterTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, username: "listener")
}

// Storage is a synchronous blocking port; its worker must remain occupied until the test releases it.
// Async response gates would move that work off the lane whose ordering these checks exercise.
private final class GatedPersistenceStore: KeymasterTokenStoring, Sendable {
    private struct State {
        var value: KeymasterTokens?
        var saveEntered = false
        var clearEntered = false
        var replacementSaveEntered = false
    }
    private let state: Mutex<State>
    private let firstSaveGate = DispatchSemaphore(value: 0)
    private let clearGate = DispatchSemaphore(value: 0)
    private let replacementSaveGate = DispatchSemaphore(value: 0)
    private let failClear: Bool
    private let failFirstSave: Bool
    private let parkClear: Bool
    private let failReplacementSave: Bool
    private let parkReplacementSave: Bool

    init(
        stored: KeymasterTokens? = nil, failFirstSave: Bool = false, failClear: Bool = false,
        parkClear: Bool = false, failReplacementSave: Bool = false, parkReplacementSave: Bool = false
    ) {
        state = Mutex(State(value: stored))
        self.failFirstSave = failFirstSave
        self.failClear = failClear
        self.parkClear = parkClear || failClear
        self.failReplacementSave = failReplacementSave
        self.parkReplacementSave = parkReplacementSave
    }

    var stored: KeymasterTokens? { state.withLock { $0.value } }
    var hasEnteredFirstSave: Bool { state.withLock { $0.saveEntered } }
    var hasEnteredClear: Bool { state.withLock { $0.clearEntered } }
    var hasEnteredReplacementSave: Bool { state.withLock { $0.replacementSaveEntered } }

    func loadResult() -> KeymasterGrantLoadResult {
        state.withLock { $0.value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        let isFirstSave = state.withLock { state in
            defer { state.saveEntered = true }
            return !state.saveEntered
        }
        if isFirstSave {
            firstSaveGate.wait()
            if failFirstSave { throw GatewayGrantStore.Failure.saveRejected }
        } else {
            state.withLock { $0.replacementSaveEntered = true }
            if parkReplacementSave {
                replacementSaveGate.wait()
                replacementSaveGate.signal()
            }
            if failReplacementSave { throw GatewayGrantStore.Failure.saveRejected }
        }
        state.withLock { $0.value = tokens }
    }

    func clear() throws {
        state.withLock { $0.clearEntered = true }
        if parkClear {
            clearGate.wait()
            clearGate.signal()
        }
        if failClear { throw GatewayGrantStore.Failure.saveRejected }
        state.withLock { $0.value = nil }
    }

    func releaseClear() { clearGate.signal() }
    func releaseFirstSave() { firstSaveGate.signal() }
    func releaseReplacementSave() { replacementSaveGate.signal() }
}

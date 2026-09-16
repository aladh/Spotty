import Foundation
import Testing
import Synchronization
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Keymaster Persistence")
struct KeymasterPersistenceTests {
    @Test(arguments: [false, true]) @MainActor
    func completedRemovalSurvivesFailedAdoption(removed: Bool) async throws {
        let store = GatedPersistenceStore(
            failClear: !removed, parkClear: true, failReplacementSave: true)
        store.releaseFirstSave()
        let cookies = Mutex(0)
        let session = KeymasterSession(store: store, cookieCleanup: { cookies.withLock { $0 += 1 } })
        let old = persistenceGrant(access: "old", refresh: "old-refresh")
        try await session.adopt(old)
        let removal = Task { await session.clear() }
        await store.clearEntered.value()
        let clearingGeneration = await session.credentialGeneration
        let adoption = Task {
            try await session.adopt(persistenceGrant(access: "replacement", refresh: "replacement-refresh"))
        }
        #expect(await waitUntil { await session.credentialGeneration != clearingGeneration })

        store.releaseClear()
        #expect(await removal.value == removed)
        await #expect(throws: PersistenceSaveFailure.rejected) { try await adoption.value }

        #expect(await session.grantState == (removed ? .absent : .removalFailed))
        #expect(await session.hasGrant == false)
        #expect(store.stored == (removed ? nil : old))
        // A new authorization began; its cookies cannot be distinguished from the old jar.
        #expect(cookies.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedRotationSaveRetriesPersistenceWithoutSpendingTheOldTokenAgain(forced: Bool) async throws {
        let store = RecordingTokenStore()
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
            await #expect(throws: PersistenceSaveFailure.rejected) {
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
        let store = RecordingTokenStore()
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
        await #expect(throws: PersistenceSaveFailure.rejected) { try await session.accessToken() }

        if markReauthentication {
            await session.markReauthenticationRequired()
        } else {
            await #expect(throws: PersistenceSaveFailure.rejected) {
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
        let session = KeymasterSession(
            store: store,
            refresher: { _ in persistenceGrant(access: "stale-rotation", refresh: "stale-rotation-refresh") },
            cookieCleanup: {})
        let generation = await session.credentialGeneration
        let refresh = Task { try await session.accessToken(expectedGeneration: generation) }
        await store.waitUntilFirstSaveEntered()
        let replacement = persistenceGrant(access: "new-account", refresh: "new-account-refresh")
        let transition = Task {
            if adopt { try await session.adopt(replacement) } else { #expect(await session.clear()) }
        }
        #expect(await waitUntil { await session.credentialGeneration != generation })

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
        store.releaseFirstSave()
        let cookies = Mutex(0)
        let session = KeymasterSession(store: store, cookieCleanup: { cookies.withLock { $0 += 1 } })
        try await session.adopt(persistenceGrant(access: "old", refresh: "old-refresh"))
        let removal = Task { await session.clear() }
        await store.clearEntered.value()
        let clearingGeneration = await session.credentialGeneration
        let replacement = persistenceGrant(access: "replacement", refresh: "replacement-refresh")
        let adoption = Task { try await session.adopt(replacement) }
        #expect(await waitUntil { await session.credentialGeneration != clearingGeneration })

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
        let worker = KeymasterPersistenceWorker(store: store)
        let first = worker.submitSave(persistenceGrant(access: "first", refresh: "first-refresh"))
        await store.waitUntilFirstSaveEntered()
        let clear = worker.submitClear()
        let replacement = persistenceGrant(access: "replacement", refresh: "replacement-refresh")
        let second = worker.submitSave(replacement)
        // All three operations are submitted before the blocked first save can complete.
        store.releaseFirstSave()
        try await first.value().get()
        try await clear.value().get()
        try await second.value().get()
        #expect(store.stored == replacement)
    }

    @Test @MainActor
    func testKeymasterPersistence() async {
        let sentinel = "SPOTTY_PRIVACY_SENTINEL_stored-grant_9b2e"
        let payload = Data("{\"access_token\":\"\(sentinel)\"}".utf8)
        #expect(KeymasterStoredGrantCodec.decode(payload) == nil, "corrupt secure blobs fail closed")
        #expect(KeymasterGrantPersistenceDiagnostics.unreadableGrant == "Stored grant is unreadable source=file")
        #expect(!KeymasterGrantPersistenceDiagnostics.unreadableGrant.contains(sentinel))

        let secure = RecordingTokenStore()
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

    @Test @MainActor
    func testTypedReadFailuresAndDurableOrdering() async {
        let existing = persistenceGrant(access: "existing-at", refresh: "existing-rt")

        do {
            let store = OutcomeTokenStore(outcome: .denied, stored: existing)
            let session = KeymasterSession(store: store, cookieCleanup: {})
            #expect((await session.grantState) == (.denied), "denied reads stay distinct from absence")
            #expect((await session.hasGrant) == false, "a denied read is not reported as usable")
            #expect((store.stored) == (existing), "a denied read preserves the durable grant")
            #expect((store.clearCount) == (0), "a denied read does not trigger retired cleanup")
        }

        do {
            let store = OutcomeTokenStore(outcome: .failed, stored: existing)
            let session = KeymasterSession(store: store, cookieCleanup: {})
            #expect((await session.grantState) == (.failed), "failed reads stay distinct from absence")
            #expect((store.stored) == (existing), "a failed read preserves the durable grant")
            #expect((store.clearCount) == (0), "a failed read does not trigger retired cleanup")
        }

        do {
            let store = OutcomeTokenStore(outcome: .absent)
            let session = KeymasterSession(store: store, cookieCleanup: {})
            #expect((await session.grantState) == (.absent), "only a missing item is absent")
            #expect((store.clearCount) == (0), "the typed fake has no incidental cleanup")
        }

        do {
            let store = FailingSaveStore()
            let session = KeymasterSession(store: store, cookieCleanup: {})
            var failed = false
            do {
                try await session.adopt(persistenceGrant(access: "failed-at", refresh: "failed-rt"))
            } catch PersistenceSaveFailure.rejected {
                failed = true
            } catch {
                Issue.record("failed save has a typed test error: unexpected error \(error)")
            }
            #expect((failed) == true, "a failed save is surfaced to its caller")
            #expect((store.stored) == nil, "a failed save does not create durable credentials")
            #expect((await session.grantState) == (.absent), "a failed first save rolls back memory")
        }

        do {
            let store = GatedPersistenceStore()
            let session = KeymasterSession(store: store, cookieCleanup: {})
            let firstGrant = persistenceGrant(access: "first-at", refresh: "first-rt")
            let replacement = persistenceGrant(access: "replacement-at", refresh: "replacement-rt")
            let first = Task { try? await session.adopt(firstGrant) }
            await store.waitUntilFirstSaveEntered()
            #expect((store.stored) == nil, "an uncompleted save does not publish an in-memory grant")
            store.releaseFirstSave()
            _ = await first.value

            #expect(await session.clear())
            #expect((store.stored) == nil, "the clear removes the previous durable grant")
            try? await session.adopt(replacement)
            #expect((store.stored) == (replacement), "save, clear, save preserves the newest durable grant")
        }

        do {
            let store = GatedPersistenceStore()
            let session = KeymasterSession(store: store, cookieCleanup: {})
            let first = Task { try? await session.adopt(persistenceGrant(access: "stale-at", refresh: "stale-rt")) }
            await store.waitUntilFirstSaveEntered()
            let clear = Task { await session.clear() }
            store.releaseFirstSave()
            _ = await first.value
            #expect(await clear.value)
            #expect((store.stored) == nil, "a stale save cannot recreate a signed-out grant")
        }
    }
}

private func persistenceGrant(access: String, refresh: String, expiresAt: Date = Date().addingTimeInterval(3_600))
    -> KeymasterTokens
{
    KeymasterTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, username: "listener")
}

private final class RecordingTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var rejectSaves = false
    var failSaves: Bool {
        get { lock.withLock { rejectSaves } }
        set { lock.withLock { rejectSaves = newValue } }
    }
    var stored: KeymasterTokens? { lock.withLock { value } }
    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }
    func save(_ tokens: KeymasterTokens) throws {
        try lock.withLock {
            if rejectSaves { throw PersistenceSaveFailure.rejected }
            value = tokens
        }
    }
    func clear() { lock.withLock { value = nil } }
}

private enum PersistenceSaveFailure: Error, Equatable, Sendable {
    case rejected
}

private final class OutcomeTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: KeymasterGrantLoadResult
    private var value: KeymasterTokens?
    private var clears = 0

    init(outcome: KeymasterGrantLoadResult, stored: KeymasterTokens? = nil) {
        self.outcome = outcome
        value = stored
    }

    var stored: KeymasterTokens? { lock.withLock { value } }
    var clearCount: Int { lock.withLock { clears } }

    func loadResult() -> KeymasterGrantLoadResult { outcome }
    func save(_: KeymasterTokens) throws { throw PersistenceSaveFailure.rejected }
    func clear() {
        lock.withLock {
            clears += 1; value = nil
        }
    }
}

private final class FailingSaveStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?

    var stored: KeymasterTokens? { lock.withLock { value } }
    func loadResult() -> KeymasterGrantLoadResult { .absent }
    func save(_: KeymasterTokens) throws { throw PersistenceSaveFailure.rejected }
    func clear() { lock.withLock { value = nil } }
}

private final class GatedPersistenceStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var saveEntered = false
    private var saveWaiter: CheckedContinuation<Void, Never>?
    private let firstSaveGate = DispatchSemaphore(value: 0)
    private let clearGate = DispatchSemaphore(value: 0)
    private let failClear: Bool
    private let failFirstSave: Bool
    private let parkClear: Bool
    private let failReplacementSave: Bool
    let clearEntered = KeymasterPersistenceReceipt<Void>()

    init(
        stored: KeymasterTokens? = nil, failFirstSave: Bool = false, failClear: Bool = false,
        parkClear: Bool = false, failReplacementSave: Bool = false
    ) {
        value = stored
        self.failFirstSave = failFirstSave
        self.failClear = failClear
        self.parkClear = parkClear || failClear
        self.failReplacementSave = failReplacementSave
    }

    var stored: KeymasterTokens? { lock.withLock { value } }

    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        let waiter: CheckedContinuation<Void, Never>?
        let isFirstSave: Bool
        lock.lock()
        isFirstSave = !saveEntered
        if isFirstSave {
            saveEntered = true
            waiter = saveWaiter
            saveWaiter = nil
        } else {
            waiter = nil
        }
        lock.unlock()
        waiter?.resume()

        if isFirstSave {
            firstSaveGate.wait()
            if failFirstSave { throw PersistenceSaveFailure.rejected }
        } else if failReplacementSave {
            throw PersistenceSaveFailure.rejected
        }
        lock.withLock { value = tokens }
    }

    func clear() throws {
        if parkClear {
            clearEntered.resolve(())
            clearGate.wait()
            clearGate.signal()
        }
        if failClear { throw PersistenceSaveFailure.rejected }
        lock.withLock { value = nil }
    }

    func releaseClear() { clearGate.signal() }

    func waitUntilFirstSaveEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if saveEntered {
                lock.unlock()
                continuation.resume()
            } else {
                saveWaiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseFirstSave() { firstSaveGate.signal() }
}

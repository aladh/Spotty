import Foundation
import Testing
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Keymaster Persistence")
struct KeymasterPersistenceTests {
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
        await clear.value()
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

        await session.clear()
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

            await session.clear()
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
            await clear.value
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
    var stored: KeymasterTokens? { lock.withLock { value } }
    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }
    func save(_ tokens: KeymasterTokens) throws { lock.withLock { value = tokens } }
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
        }
        lock.withLock { value = tokens }
    }

    func clear() { lock.withLock { value = nil } }

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

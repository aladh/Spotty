import Foundation
import SpottyDomain
import SpottyTestSupport
import Synchronization
import Testing
@testable import SpottyGateway

@Suite("Keymaster reauthentication persistence")
struct KeymasterReauthenticationTests {
    @Test func markerRoundTripsAndFreshAdoptionClearsIt() async throws {
        let store = GatewayGrantStore()
        let initial = markerGrant(access: "access-a", refresh: "refresh-a")
        let session = KeymasterSession(store: store, cookieCleanup: {})
        try await session.adopt(initial)
        #expect(await session.reauthenticationRequired() == false)

        await session.markReauthenticationRequired()
        let persisted = try #require(store.stored)
        #expect(persisted.requiresReauthentication)
        #expect(await session.reauthenticationRequired())
        let decoded = try JSONDecoder().decode(KeymasterTokens.self, from: JSONEncoder().encode(persisted))
        #expect(decoded == persisted)

        let data = try JSONEncoder().encode(initial)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "requiresReauthentication")
        let legacyGrant = try JSONDecoder().decode(
            KeymasterTokens.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(legacyGrant == initial, "Older grants remain readable without the marker")

        let restored = KeymasterSession(store: store, cookieCleanup: {})
        #expect(await restored.reauthenticationRequired())
        try await restored.adopt(markerGrant(access: "access-b", refresh: "refresh-b"))
        #expect(store.stored?.requiresReauthentication == false)
        #expect(await restored.reauthenticationRequired() == false)
        await restored.markReauthenticationRequired()
        #expect(await restored.clear())
        #expect(store.stored == nil)
    }

    @Test func markerSurvivesRotatingRefresh() async throws {
        let store = GatewayGrantStore()
        let session = KeymasterSession(
            store: store,
            refresher: { refreshToken in
                markerGrant(access: "rotated-access", refresh: "rotated-\(refreshToken)")
            }, cookieCleanup: {})
        var initial = markerGrant(access: "access-a", refresh: "refresh-a")
        initial.expiresAt = .distantPast
        try await session.adopt(initial)
        await session.markReauthenticationRequired()

        #expect(try await session.accessToken(now: HarnessDates.fixed) == "rotated-access")
        #expect(store.stored?.refreshToken == "rotated-refresh-a")
        #expect(store.stored?.requiresReauthentication == true)
    }

    @Test func markerAbortsWhenFreshAdoptionStartsDuringInitialLoad() async throws {
        let replacement = markerGrant(access: "access-new", refresh: "refresh-new")
        let store = MarkerLoadStore(initial: markerGrant(access: "access-old", refresh: "refresh-old"))
        defer { store.releaseLoad() }
        let session = KeymasterSession(store: store, cookieCleanup: {})
        let finished = HarnessCounters()
        let marker = Task {
            defer { finished.record("marker") }
            await session.markReauthenticationRequired()
        }
        defer { marker.cancel() }
        try await requireEventually { store.hasEnteredLoad }
        let loadingGeneration = await session.credentialGeneration
        let adoption = Task {
            defer { finished.record("adoption") }
            try await session.adopt(replacement)
        }
        defer { adoption.cancel() }
        // Creation of a task is not admission. The new generation must own the grant before
        // the old load can return, while its durable save is still queued behind that load.
        try await requireEventually { await session.credentialGeneration != loadingGeneration }
        store.releaseLoad()
        try await requireEventually { finished.count("marker") == 1 && finished.count("adoption") == 1 }
        await marker.value
        try await adoption.value

        #expect(store.stored == replacement, "An old marker must not mark the newly adopted grant")
        #expect(await session.reauthenticationRequired() == false)
    }

    @Test func failedMarkerSaveRetriesAndFailedAdoptionRetainsMarker() async throws {
        let initial = markerGrant(access: "access-a", refresh: "refresh-a")
        let store = GatewayGrantStore(stored: initial, failSaves: true)
        let session = KeymasterSession(store: store, cookieCleanup: {})
        await session.markReauthenticationRequired()
        #expect(await session.reauthenticationRequired())
        #expect(store.stored == initial, "A failed save must not claim durability")

        store.failSaves = false
        await session.markReauthenticationRequired()
        #expect(store.stored?.requiresReauthentication == true)
        #expect(store.saveCount == 2)

        store.failSaves = true
        await #expect(throws: GatewayGrantStore.Failure.saveRejected) {
            try await session.adopt(markerGrant(access: "access-b", refresh: "refresh-b"))
        }
        var marked = initial
        marked.requiresReauthentication = true
        #expect(store.stored == marked)
        #expect(await session.reauthenticationRequired())
        #expect(store.saveCount == 3)
    }
}

private func markerGrant(access: String, refresh: String) -> KeymasterTokens {
    KeymasterTokens(accessToken: access, refreshToken: refresh, expiresAt: .distantFuture, username: "listener")
}

/// The storage protocol is synchronous: only this first disk read blocks the persistence worker.
/// Shared async response gates cannot express it. Closing also admits a read that has not entered.
private final class MarkerLoadStore: KeymasterTokenStoring, Sendable {
    private struct State {
        var entered = false
        var released = false
    }
    private let state = Mutex(State())
    private let loadGate = DispatchSemaphore(value: 0)
    private let storage: GatewayGrantStore

    init(initial: KeymasterTokens) { storage = GatewayGrantStore(stored: initial) }
    var stored: KeymasterTokens? { storage.stored }
    var hasEnteredLoad: Bool { state.withLock { $0.entered } }

    func loadResult() -> KeymasterGrantLoadResult {
        let snapshot = storage.loadResult()
        let shouldWait = state.withLock {
            guard !$0.entered else { return false }
            $0.entered = true
            return !$0.released
        }
        if shouldWait { loadGate.wait() }
        return snapshot
    }

    func releaseLoad() {
        let release = state.withLock {
            guard !$0.released else { return false }
            $0.released = true
            return true
        }
        if release { loadGate.signal() }
    }

    func save(_ tokens: KeymasterTokens) throws { try storage.save(tokens) }
    func clear() throws { storage.clear() }
}

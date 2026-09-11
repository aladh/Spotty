import Testing
import Foundation
@testable import SpottyCore

@Suite("Auth Credential Retry")
struct AuthCredentialRetryTests {
    @Test
    @MainActor
    func aClockValidRefusalSpendsTheRefreshTokenOnce() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        let current = grant(access: "access-a", refresh: "refresh-a")
        let renewed = grant(access: "access-b", refresh: "refresh-b")
        try? await session.adopt(current)

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        #expect((refresher.attemptCount) == (1), "clock-valid refusal spends the refresh token once")
        #expect((refresher.spent) == (["refresh-a"]), "the spent refresh token is the current grant's")
        refresher.complete(renewed)

        let token = try? await pending.value
        #expect((token) == ("access-b"), "forced refresh returns the replacement bearer")
        #expect((store.stored?.refreshToken) == ("refresh-b"), "the replacement grant is persisted")
        #expect((try? await session.accessToken()) == ("access-b"), "a later accessToken does not refresh again")
        #expect((refresher.attemptCount) == (1), "clock-valid access after refresh does not spend again")
    }

    @Test
    @MainActor
    func overlappingRefusalsJoinTheSingleInFlightRefresh() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let first = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        let started = StartedGate(count: 2)
        let second = Task {
            started.mark()
            return try await session.refreshIgnoringExpiry(rejected: "access-a")
        }
        let joinedAccess = Task {
            started.mark()
            return try await session.accessToken()
        }
        await started.wait()
        _ = await session.hasGrant
        #expect((refresher.attemptCount) == (1), "the second 401 joins rather than starting a second spend")
        #expect((refresher.overlappingSpends) == (0), "no overlapping refresh spend while the first is in flight")

        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        #expect((try? await first.value) == ("access-b"), "first waiter receives the replacement")
        #expect((try? await second.value) == ("access-b"), "second waiter receives the same replacement")
        #expect((try? await joinedAccess.value) == ("access-b"), "in-flight accessToken joins the same refresh")
        #expect((refresher.attemptCount) == (1), "rotating refresh token is spent once")
        #expect((refresher.spent) == (["refresh-a"]), "rotating refresh token is not double-spent")
    }

    @Test
    @MainActor
    func aRenewedRefreshTokenIsNotSpentAgain() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))
        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        _ = try? await pending.value

        let late = try? await session.refreshIgnoringExpiry(rejected: "access-a")
        #expect((late) == ("access-b"), "a late 401 for the old bearer returns the replacement")
        #expect((refresher.attemptCount) == (1), "the replacement refresh token is not spent")
        #expect((store.stored?.refreshToken) == ("refresh-b"), "the replacement grant remains stored")
    }

    @Test
    @MainActor
    func matchingInvalidGrantSurfacesGrantRevoked() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        refresher.fail(KeymasterAuthError.grantRevoked)

        var revoked = false
        do {
            _ = try await pending.value
        } catch KeymasterSessionError.grantRevoked {
            revoked = true
        } catch {
            #expect((false) == true, "matching invalid_grant surfaces grantRevoked, got \(error)")
        }
        #expect((revoked) == true, "matching invalid_grant surfaces the sign-in-again error")
        #expect((store.stored) == nil, "matching invalid_grant clears the stored grant")
        #expect((cookies.count) == (1), "matching invalid_grant runs the terminal cookie cleanup")
        await announcements.waitForAnnouncement()
        #expect((announcements.count) == (1), "matching invalid_grant announces revocation")
        announcements.cancel()
        var noGrantAfterClear = false
        do {
            _ = try await session.accessToken()
        } catch KeymasterSessionError.noGrant {
            noGrantAfterClear = true
        } catch {
            #expect((false) == true, "cleared grant is noGrant, got \(error)")
        }
        #expect((noGrantAfterClear) == true, "the session has no grant after matching revocation")
    }

    @Test
    @MainActor
    func aStaleInvalidGrantNeitherClearsCookiesNorAnnounces() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        try? await session.adopt(grant(access: "access-new", refresh: "refresh-new"))
        refresher.fail(KeymasterAuthError.grantRevoked)

        #expect((try? await pending.value) == ("access-new"), "stale invalid_grant returns the replacement bearer")
        #expect((store.stored?.refreshToken) == ("refresh-new"), "the adopted grant remains")
        #expect((cookies.count) == (0), "stale invalid_grant does not clear cookies")
        await session.drainActor()
        #expect((announcements.count) == (0), "stale invalid_grant does not announce")
        #expect((try? await session.accessToken()) == ("access-new"), "the replacement bearer is live")
        announcements.cancel()
    }

    @Test
    @MainActor
    func logoutDuringRefreshWinsOverTheStaleSuccess() async {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let superseded = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        let joinedAccess = Task { try await session.accessToken() }
        _ = await session.hasGrant
        try? await session.adopt(grant(access: "access-adopted", refresh: "refresh-adopted"))
        refresher.complete(grant(access: "access-stale", refresh: "refresh-stale"))

        #expect(
            (try? await superseded.value) == ("access-adopted"),
            "a refresh that loses to adopt returns the adopted bearer")
        #expect(
            (try? await joinedAccess.value) == ("access-adopted"),
            "a parallel accessToken during adopt returns the adopted bearer")
        #expect((store.stored?.accessToken) == ("access-adopted"), "adopted tokens survive the stale success")

        let loggedOut = Task { try await session.refreshIgnoringExpiry(rejected: "access-adopted") }
        await refresher.waitUntilParked()
        await session.clear()
        refresher.complete(grant(access: "access-zombie", refresh: "refresh-zombie"))

        var logoutStale = false
        do {
            _ = try await loggedOut.value
        } catch KeymasterSessionError.noGrant {
            logoutStale = true
        } catch {
            #expect((false) == true, "logout during refresh is noGrant, got \(error)")
        }
        #expect((logoutStale) == true, "a refresh that loses to logout does not persist")
        #expect((store.stored) == nil, "logout leaves no grant for the stale success to restore")
        #expect((cookies.count) == (1), "logout still runs cookie cleanup once")
    }

    @Test
    @MainActor
    func concurrentCallersShareOneStoreRead() async {
        let stored = grant(access: "stored-access", refresh: "stored-refresh")
        let store = GatedGrantStore(initial: stored)
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        await store.waitUntilLoadEntered()
        #expect((store.loadCount) == (1), "the first caller starts one store read")

        let second = Task { try await session.accessToken() }
        let third = Task { await session.hasGrant }
        store.releaseLoad()

        #expect((await first.value) == true, "first caller sees the stored grant")
        #expect((try? await second.value) == ("stored-access"), "second caller receives the stored bearer")
        #expect((await third.value) == true, "third caller sees the stored grant")
        #expect((store.loadCount) == (1), "concurrent callers share one store read")
    }

    @Test
    @MainActor
    func anOverlappingLoadAndAdoptionLeaveTheReplacementDurable() async {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { try await session.accessToken() }
        await store.waitUntilLoadEntered()
        let adoption = Task {
            try? await session.adopt(grant(access: "adopted-access", refresh: "adopted-refresh"))
        }
        store.releaseLoad()

        let observed = try? await first.value
        #expect(
            (observed == "disk-access" || observed == "adopted-access") == true,
            "a load that wins before adoption may return the committed disk bearer"
        )
        _ = await adoption.value
        #expect(
            (store.stored?.accessToken) == ("adopted-access"),
            "the replacement is the final durable bearer after overlapping load and adoption"
        )
    }

    @Test
    @MainActor
    func clearDuringAnOverlappingLoadLeavesNoDurableGrant() async {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        await store.waitUntilLoadEntered()
        let clear = Task { await session.clear() }
        store.releaseLoad()

        _ = await first.value
        await clear.value
        #expect((store.stored) == nil, "clear leaves no durable grant after an overlapping load")
    }

    @Test
    @MainActor
    func aPartnerBearerRejectionRetriesWithTheNextCredentialPair() async {
        let tokens = CredentialSequence(values: ["access-a", "access-b"])
        let clients = CredentialSequence(values: ["client-a", "client-b"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        )

        let profile = try? await api.profile()
        #expect((profile?.name) == ("Listener"), "retry succeeds after one 401")
        #expect((await invalidatedAccess.values) == (["access-a"]), "the sent bearer is invalidated")
        #expect((await invalidatedClient.values) == (["client-a"]), "the sent client token is invalidated")
        #expect((tokens.callCount) == (2), "access is fetched for the attempt and the retry")
        #expect((clients.callCount) == (2), "client token is fetched for the attempt and the retry")
        #expect((transport.callCount) == (2), "the transport is attempted twice")
        #expect(
            (transport.authorizationTokens) == (["access-a", "access-b"]), "retry carries the replacement pair")
        #expect(
            (transport.clientTokens) == (["client-a", "client-b"]), "retry carries the replacement client token")
    }

    @Test
    @MainActor
    func aRevokedPartnerBearerStaysGrantRevoked() async {
        let tokens = CredentialSequence(values: ["access-a"])
        let clients = CredentialSequence(values: ["client-a"])
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { _ in throw KeymasterSessionError.grantRevoked },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        )

        var revoked = false
        do {
            _ = try await api.profile()
        } catch KeymasterSessionError.grantRevoked {
            revoked = true
        } catch {
            #expect((false) == true, "bearer revoke stays grantRevoked, got \(error)")
        }
        #expect((revoked) == true, "a revoked bearer still surfaces grantRevoked")
        #expect(
            (await invalidatedClient.values) == (["client-a"]),
            "the named client token is dropped before the bearer throw")
        #expect((transport.callCount) == (1), "a terminal bearer throw does not retry the request")
        #expect((tokens.callCount) == (1), "access is fetched only for the first attempt")
    }

    @Test
    @MainActor
    func aSecondPartnerRejectionIsReturnedRatherThanRetried() async {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        )

        var status = 0
        do {
            _ = try await api.profile()
        } catch let error as PartnerAPIError {
            if case let .requestFailed(code) = error { status = code }
        } catch {
            #expect((false) == true, "second 401 stays PartnerAPIError, got \(error)")
        }
        #expect((status) == (401), "a second 401 is returned rather than retried again")
        #expect(
            (await invalidatedAccess.values) == (["access-a", "access-b"]), "both sent bearers are invalidated")
        #expect(
            (await invalidatedClient.values) == (["client-a", "client-b"]),
            "both sent client tokens are invalidated")
        #expect((transport.callCount) == (2), "the transport stops after the retry")
        #expect((tokens.callCount) == (2), "a third credential is never fetched")
    }

    @Test
    @MainActor
    func aQueueBearerRejectionInvalidatesTheSentBearer() async {
        let tokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c"])
        let invalidated = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, queueBody),
        ])
        let api = SpotifyWebPlayerAPI(
            accessToken: { tokens.next() },
            invalidateAccessToken: { await invalidated.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        )

        let tracks = try? await api.queue()
        #expect((tracks?.map(\.uri)) == (["spotify:track:track-id"]), "queue retry succeeds after one 401")
        #expect((await invalidated.values) == (["queue-a"]), "queue 401 invalidates the sent bearer")
        #expect(
            (transport.authorizationTokens) == (["queue-a", "queue-b"]), "queue retry uses the replacement bearer")
        #expect((transport.clientTokens) == ([]), "queue never sends a client token")
        #expect((transport.callCount) == (2), "queue transport is attempted twice")
    }

    @Test
    @MainActor
    func aSecondQueueRejectionIsReturnedRatherThanRetried() async {
        let tokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c"])
        let invalidated = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (401, Data()),
            (200, queueBody),
        ])
        let api = SpotifyWebPlayerAPI(
            accessToken: { tokens.next() },
            invalidateAccessToken: { await invalidated.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        )

        var status = 0
        do {
            _ = try await api.queue()
        } catch let error as SpotifyWebPlayerAPIError {
            if case let .requestFailed(code) = error { status = code }
        } catch {
            #expect((false) == true, "second queue 401 stays SpotifyWebPlayerAPIError, got \(error)")
        }
        #expect((status) == (401), "a second queue 401 is returned rather than retried again")
        #expect((await invalidated.values) == (["queue-a", "queue-b"]), "queue invalidates both sent bearers")
        #expect((transport.clientTokens) == ([]), "queue never sends a client token")
        #expect((transport.callCount) == (2), "queue stops after the retry")
        #expect((tokens.callCount) == (2), "queue never fetches a third bearer")
    }

    @Test
    @MainActor
    func onlyTheSequencedRejectedPairIsInvalidatedOnce() async {
        let currentAccess = SharedToken("access-b")
        let currentClient = SharedToken("client-b")
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let tokens = CredentialSequence(values: ["access-a"])
        let clients = CredentialSequence(values: ["client-a"])
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: {
                if tokens.callCount == 0 {
                    return tokens.next()
                }
                return await currentAccess.value()
            },
            clientToken: {
                if clients.callCount == 0 {
                    return clients.next()
                }
                return await currentClient.value()
            },
            invalidateAccessToken: { rejected in
                await invalidatedAccess.record(rejected)
                await currentAccess.replace(rejected, with: "erased-access")
            },
            invalidateClientToken: { rejected in
                await invalidatedClient.record(rejected)
                await currentClient.replace(rejected, with: "erased-client")
            },
            transport: transport.send,
            retryTiming: .immediate
        )

        let profile = try? await api.profile()
        #expect((profile?.name) == ("Listener"), "retry succeeds with the live replacement")
        #expect((await invalidatedAccess.values) == (["access-a"]), "the rejected bearer is still named")
        #expect((await invalidatedClient.values) == (["client-a"]), "the rejected client token is still named")
        #expect((await currentAccess.value()) == ("access-b"), "the newer bearer survives named invalidation")
        #expect((await currentClient.value()) == ("client-b"), "the newer client token survives named invalidation")
        #expect(
            (transport.authorizationTokens) == (["access-a", "access-b"]), "retry carries the live replacement pair"
        )
        #expect(
            (transport.clientTokens) == (["client-a", "client-b"]),
            "retry carries the live replacement client token")
        #expect((tokens.callCount) == (1), "the sequenced rejected pair is fetched once")
        #expect((transport.callCount) == (2), "the transport is attempted twice")
    }
}

private actor SharedToken {
    private var current: String

    init(_ value: String) {
        current = value
    }

    func value() -> String { current }

    func replace(_ rejected: String, with replacement: String) {
        if current == rejected {
            current = replacement
        }
    }
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

private func grant(
    access: String,
    refresh: String,
    expiresAt: Date = Date().addingTimeInterval(3_600)
) -> KeymasterTokens {
    KeymasterTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiresAt,
        username: "listener"
    )
}

private final class MemoryGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.withLock { value = tokens }
    }

    func clear() {
        lock.withLock { value = nil }
    }
}

/// `load()` snapshots on entry, then waits, so adopt/clear during the wait cannot change what
/// the stale read would have returned.
private final class GatedGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var loads = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private let gate = DispatchSemaphore(value: 0)

    init(initial: KeymasterTokens?) {
        value = initial
    }

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    var loadCount: Int {
        lock.withLock { loads }
    }

    func loadResult() -> KeymasterGrantLoadResult {
        lock.lock()
        loads += 1
        let snapshot = value
        let continuation = entered
        entered = nil
        hasEntered = true
        lock.unlock()
        continuation?.resume()
        gate.wait()
        return snapshot.map(KeymasterGrantLoadResult.found) ?? .absent
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.withLock { value = tokens }
    }

    func clear() {
        lock.withLock { value = nil }
    }

    func waitUntilLoadEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func releaseLoad() {
        gate.signal()
    }
}

private final class ParkingRefresher: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<KeymasterTokens, Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var attempts = 0
    private var spentTokens: [String] = []
    private var overlapping = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    var overlappingSpends: Int {
        lock.withLock { overlapping }
    }

    var spent: [String] {
        lock.withLock { spentTokens }
    }

    func refresh(_ refreshToken: String) async throws -> KeymasterTokens {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if parked != nil {
                overlapping += 1
            }
            attempts += 1
            spentTokens.append(refreshToken)
            parked = continuation
            let entered = entered
            self.entered = nil
            lock.unlock()
            entered?.resume()
        }
    }

    func waitUntilParked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if parked != nil {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func complete(_ tokens: KeymasterTokens) {
        lock.lock()
        let continuation = parked
        parked = nil
        lock.unlock()
        continuation?.resume(returning: tokens)
    }

    func fail(_ error: Error) {
        lock.lock()
        let continuation = parked
        parked = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String]
    private var index = 0

    init(values: [String]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = values[index]
        index += 1
        return value
    }
}

private actor RecordingInvalidator {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class ScriptedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(Int, Data)]
    private var index = 0
    private var authorizations: [String] = []
    private var clients: [String] = []

    init(responses: [(Int, Data)]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var authorizationTokens: [String] {
        lock.withLock { authorizations }
    }

    var clientTokens: [String] {
        lock.withLock { clients }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        if let access = SpotifyCredentials.accessTokenCarried(by: request) {
            authorizations.append(access)
        }
        if let client = request.value(forHTTPHeaderField: "Client-Token") {
            clients.append(client)
        }
        let response = responses[index]
        index += 1
        let url = request.url ?? URL(string: "https://example.invalid/")!
        return (
            response.1, HTTPURLResponse(url: url, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

private final class StartedGate: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var marked = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(count: Int) {
        target = count
    }

    func mark() {
        lock.lock()
        marked += 1
        let ready = marked >= target
        let waiter = waiter
        if ready { self.waiter = nil }
        lock.unlock()
        if ready { waiter?.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if marked >= target {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

private extension KeymasterSession {
    /// Completes a hop onto this actor so a just-created revocation stream can install.
    func drainActor() async {
        _ = await hasGrant
    }
}

private final class GrantCookieCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RevocationProbe: @unchecked Sendable {
    private let state: State
    private let listener: Task<Void, Never>

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var announcements = 0
        var waiter: CheckedContinuation<Void, Never>?

        func noteAnnouncement() {
            lock.lock()
            announcements += 1
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    init(_ stream: AsyncStream<Void>) {
        let state = State()
        self.state = state
        listener = Task {
            for await _ in stream {
                state.noteAnnouncement()
            }
        }
    }

    var count: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.announcements
    }

    func waitForAnnouncement() async {
        await withCheckedContinuation { continuation in
            state.lock.lock()
            if state.announcements > 0 {
                state.lock.unlock()
                continuation.resume()
            } else {
                state.waiter = continuation
                state.lock.unlock()
            }
        }
    }

    func cancel() {
        listener.cancel()
        state.lock.lock()
        let waiter = state.waiter
        state.waiter = nil
        state.lock.unlock()
        waiter?.resume()
    }
}

import SpottyTestSupport
import Testing
import Foundation
import Synchronization
import SpottyDomain
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Auth Credential Retry")
struct AuthCredentialRetryTests {
    @Test(arguments: [0, 1, 2])
    func exhaustedCredentialScriptsReportUnexpectedWorkWithoutCrashing(length: Int) async throws {
        let values = (0..<length).map { "credential-\($0)" }
        let credentials = CredentialSequence(values: values)
        let responses = (0..<length).map { (200 + $0, Data([UInt8($0)])) }
        let transport = ScriptedTransport(responses: responses)
        var request = URLRequest(url: URL(string: "https://example.invalid/fixture")!)
        request.setValue("Bearer recorded-access", forHTTPHeaderField: "Authorization")
        request.setValue("recorded-client", forHTTPHeaderField: "Client-Token")
        for index in 0..<length {
            #expect(try credentials.next() == values[index])
            let (body, response) = try await transport.send(request)
            #expect(body == responses[index].1)
            #expect((response as? HTTPURLResponse)?.statusCode == responses[index].0)
        }

        #expect(throws: CredentialScriptError.exhausted) { try credentials.next() }
        await #expect(throws: CredentialScriptError.exhausted) { try await transport.send(request) }

        #expect(credentials.callCount == length + 1)
        #expect(transport.callCount == length + 1)
        #expect(transport.authorizationTokens == Array(repeating: "recorded-access", count: length + 1))
        #expect(transport.clientTokens == Array(repeating: "recorded-client", count: length + 1))
    }

    @Test @MainActor func refreshFixtureCleanupSettlesUnexpectedOverlappingCalls() async throws {
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let first = Task { try await refresher.refresh("first") }
        let second = Task { try await refresher.refresh("second") }
        defer { first.cancel(); second.cancel() }
        try await requireEventually { refresher.waiterCount == 2 }
        #expect(refresher.attemptCount == 2 && refresher.overlappingSpends == 1)
        #expect(Set(refresher.spent) == ["first", "second"])
        first.cancel()
        #expect(refresher.waiterCount == 2, "late-reply mode deliberately ignores caller cancellation")

        refresher.close()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await refresher.refresh("after-close") }
        #expect(refresher.waiterCount == 0)
    }

    @Test(arguments: [false, true])
    @MainActor
    func cancelledCallerCannotStartRotationAtSessionOwner(afterRefusal: Bool) async throws {
        let gate = HarnessClock(sleep: .uncooperativelyParked)
        defer { gate.releaseAll() }
        let store = GatewayGrantStore()
        let spent = RecordingInvalidator()
        let renewed = grant(access: "access-b", refresh: "refresh-b")
        let session = KeymasterSession(
            store: store,
            refresher: {
                await spent.record($0)
                return renewed
            }, cookieCleanup: {})
        let current = grant(
            access: "access-a", refresh: "refresh-a",
            expiresAt: HarnessDates.fixed.addingTimeInterval(afterRefusal ? 3_600 : -3_600))
        try await session.adopt(current)
        let request = Task {
            try await gate.sleep(seconds: 1)
            if afterRefusal {
                return try await session.refreshIgnoringExpiry(rejected: current.accessToken)
            }
            return try await session.accessToken(now: HarnessDates.fixed)
        }
        defer { request.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        request.cancel()
        gate.releaseAll()
        do {
            _ = try await request.value
            Issue.record("The session owner must reject a cancelled rotation request")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await spent.values.isEmpty)
        #expect(store.stored == current)
    }

    @Test @MainActor
    func readRetryCannotMultiplyClientTokenAttempts() async {
        let calls = HarnessCounters()
        let transport = ScriptedTransport(responses: [(200, profileBody)])
        let api = PartnerAPI(
            accessToken: { "access-a" },
            clientToken: {
                try await ClientTokenRequest.send(
                    deviceId: "synthetic",
                    transport: { _ in
                        calls.record("client-token")
                        throw URLError(.timedOut)
                    }, retryTiming: .immediate
                ).token
            },
            invalidateAccessToken: { _ in }, invalidateClientToken: { _ in },
            transport: transport.send, retryTiming: .immediate)
        await #expect(throws: URLError.self) { _ = try await api.profile() }
        #expect(calls.count("client-token") == SpotifyTransientRetry.maximumAttempts)
        #expect(transport.callCount == 0)
    }

    @Test(
        arguments: [false, true],
        [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost])
    @MainActor
    func readRetryCannotRepeatRotatingRefreshFailures(afterRefusal: Bool, code: URLError.Code) async throws {
        let spent = RecordingInvalidator()
        let session = KeymasterSession(
            store: GatewayGrantStore(),
            refresher: { refreshToken in
                await spent.record(refreshToken)
                return try await KeymasterAuth.postToken(
                    body: Data(), fallbackRefreshToken: refreshToken,
                    transport: { _ in throw URLError(code) }, retryTiming: .immediate)
            },
            cookieCleanup: {})
        try await session.adopt(
            grant(
                access: "access-a", refresh: "refresh-a",
                expiresAt: HarnessDates.fixed.addingTimeInterval(afterRefusal ? 3_600 : -3_600)))
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(
            responses: Array(repeating: (401, Data()), count: SpotifyTransientRetry.maximumAttempts))
        let api = PartnerAPI(
            accessToken: { try await session.accessToken(now: HarnessDates.fixed) },
            clientToken: { "client-a" },
            invalidateAccessToken: { _ = try await session.refreshIgnoringExpiry(rejected: $0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send, retryTiming: .immediate)

        do {
            _ = try await api.profile()
            Issue.record("The uncertain refresh must reach the caller")
        } catch let error as URLError {
            #expect(error.code == code)
        }
        #expect(await spent.values == ["refresh-a"], "read replay must not spend a rotating token again")
        #expect(transport.callCount == (afterRefusal ? 1 : 0))
        #expect(await invalidatedClient.values == (afterRefusal ? ["client-a"] : []))
    }

    @Test(arguments: [false, true])
    @MainActor
    func aClockValidRefusalSpendsTheRefreshTokenOnce(cancelAfterDispatch: Bool) async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        let current = grant(access: "access-a", refresh: "refresh-a")
        let renewed = grant(access: "access-b", refresh: "refresh-b")
        try? await session.adopt(current)

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { pending.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        #expect((refresher.attemptCount) == (1), "clock-valid refusal spends the refresh token once")
        #expect((refresher.spent) == (["refresh-a"]), "the spent refresh token is the current grant's")
        if cancelAfterDispatch { pending.cancel() }
        refresher.complete(renewed)

        let token = try? await pending.value
        #expect((token) == ("access-b"), "forced refresh returns the replacement bearer")
        #expect((store.stored?.refreshToken) == ("refresh-b"), "the replacement grant is persisted")
        #expect((try? await session.accessToken()) == ("access-b"), "a later accessToken does not refresh again")
        #expect((refresher.attemptCount) == (1), "clock-valid access after refresh does not spend again")
    }

    @Test
    @MainActor
    func overlappingRefusalsJoinTheSingleInFlightRefresh() async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let first = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { first.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        let started = HarnessCounters()
        let second = Task {
            started.record("started")
            return try await session.refreshIgnoringExpiry(rejected: "access-a")
        }
        defer { second.cancel() }
        let joinedAccess = Task {
            started.record("started")
            return try await session.accessToken()
        }
        defer { joinedAccess.cancel() }
        try await requireEventually { started.count("started") == 2 }
        _ = await session.hasGrant
        // Failed admission must unwind the gate before any join can wait on extra responses.
        try #require((refresher.attemptCount) == (1), "the second 401 joins rather than starting a second spend")
        try #require((refresher.overlappingSpends) == (0), "no overlapping refresh spend while the first is in flight")

        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        #expect((try? await first.value) == ("access-b"), "first waiter receives the replacement")
        #expect((try? await second.value) == ("access-b"), "second waiter receives the same replacement")
        #expect((try? await joinedAccess.value) == ("access-b"), "in-flight accessToken joins the same refresh")
        #expect((refresher.attemptCount) == (1), "rotating refresh token is spent once")
        #expect((refresher.spent) == (["refresh-a"]), "rotating refresh token is not double-spent")
    }

    @Test
    @MainActor
    func aRenewedRefreshTokenIsNotSpentAgain() async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))
        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { pending.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        _ = try? await pending.value

        let late = try? await session.refreshIgnoringExpiry(rejected: "access-a")
        #expect((late) == ("access-b"), "a late 401 for the old bearer returns the replacement")
        #expect((refresher.attemptCount) == (1), "the replacement refresh token is not spent")
        #expect((store.stored?.refreshToken) == ("refresh-b"), "the replacement grant remains stored")
    }

    @Test
    @MainActor
    func matchingInvalidGrantSurfacesGrantRevoked() async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let cookies = HarnessCounters()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.record("cleanup") }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())
        defer { announcements.cancel() }

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { pending.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
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
        #expect((cookies.count("cleanup")) == (1), "matching invalid_grant runs the terminal cookie cleanup")
        try await requireEventually { announcements.count == 1 }
        #expect((announcements.count) == (1), "matching invalid_grant announces revocation")
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
    func aStaleInvalidGrantNeitherClearsCookiesNorAnnounces() async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let cookies = HarnessCounters()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.record("cleanup") }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())
        defer { announcements.cancel() }

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { pending.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        try? await session.adopt(grant(access: "access-new", refresh: "refresh-new"))
        refresher.fail(KeymasterAuthError.grantRevoked)

        #expect((try? await pending.value) == ("access-new"), "stale invalid_grant returns the replacement bearer")
        #expect((store.stored?.refreshToken) == ("refresh-new"), "the adopted grant remains")
        #expect((cookies.count("cleanup")) == (0), "stale invalid_grant does not clear cookies")
        await session.drainActor()
        #expect((announcements.count) == (0), "stale invalid_grant does not announce")
        #expect((try? await session.accessToken()) == ("access-new"), "the replacement bearer is live")
    }

    @Test
    @MainActor
    func logoutDuringRefreshWinsOverTheStaleSuccess() async throws {
        let store = GatewayGrantStore()
        let refresher = ParkingRefresher()
        defer { refresher.close() }
        let cookies = HarnessCounters()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.record("cleanup") }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let superseded = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        defer { superseded.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        let joinedAccess = Task { try await session.accessToken() }
        defer { joinedAccess.cancel() }
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
        defer { loggedOut.cancel() }
        try await requireEventually { refresher.waiterCount == 1 }
        #expect(await session.clear())
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
        #expect((cookies.count("cleanup")) == (1), "logout still runs cookie cleanup once")
    }

    @Test
    @MainActor
    func concurrentCallersShareOneStoreRead() async throws {
        let stored = grant(access: "stored-access", refresh: "stored-refresh")
        let store = GatedGrantStore(initial: stored)
        defer { store.releaseLoad() }
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        defer { first.cancel() }
        try await requireEventually { store.loadCount == 1 }
        #expect((store.loadCount) == (1), "the first caller starts one store read")

        let second = Task { try await session.accessToken() }
        defer { second.cancel() }
        let third = Task { await session.hasGrant }
        defer { third.cancel() }
        store.releaseLoad()

        #expect((await first.value) == true, "first caller sees the stored grant")
        #expect((try? await second.value) == ("stored-access"), "second caller receives the stored bearer")
        #expect((await third.value) == true, "third caller sees the stored grant")
        #expect((store.loadCount) == (1), "concurrent callers share one store read")
    }

    @Test
    @MainActor
    func anOverlappingLoadAndAdoptionLeaveTheReplacementDurable() async throws {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        defer { store.releaseLoad() }
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { try await session.accessToken() }
        defer { first.cancel() }
        try await requireEventually { store.loadCount == 1 }
        let loadingGeneration = await session.credentialGeneration
        let adoption = Task {
            try await session.adopt(grant(access: "adopted-access", refresh: "adopted-refresh"))
        }
        defer { adoption.cancel() }
        try await requireEventually { await session.credentialGeneration != loadingGeneration }
        store.releaseLoad()

        #expect(try await first.value == "adopted-access", "the reader follows the accepted replacement")
        try await adoption.value
        #expect(
            (store.stored?.accessToken) == ("adopted-access"),
            "the replacement is the final durable bearer after overlapping load and adoption"
        )
    }

    @Test
    @MainActor
    func clearDuringAnOverlappingLoadLeavesNoDurableGrant() async throws {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        defer { store.releaseLoad() }
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        defer { first.cancel() }
        try await requireEventually { store.loadCount == 1 }
        let clear = Task { await session.clear() }
        defer { clear.cancel() }
        store.releaseLoad()

        _ = await first.value
        #expect(await clear.value)
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
            accessToken: { try tokens.next() },
            clientToken: { try clients.next() },
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
            accessToken: { try tokens.next() },
            clientToken: { try clients.next() },
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
            accessToken: { try tokens.next() },
            clientToken: { try clients.next() },
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
            accessToken: { try tokens.next() },
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
            accessToken: { try tokens.next() },
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
                    return try tokens.next()
                }
                return await currentAccess.value()
            },
            clientToken: {
                if clients.callCount == 0 {
                    return try clients.next()
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

/// `load()` snapshots on entry, then waits, so adopt/clear during the wait cannot change what
/// the stale read would have returned.
// The persistence worker uses a synchronous port, so this gate parks its actual worker lane.
// Releasing it is permanent: unexpected extra reads can fail assertions without hanging cleanup.
private final class GatedGrantStore: KeymasterTokenStoring, Sendable {
    private struct State {
        var value: KeymasterTokens?
        var loads = 0
    }
    private let state: Mutex<State>
    private let gate = DispatchSemaphore(value: 0)

    init(initial: KeymasterTokens?) { state = Mutex(State(value: initial)) }

    var stored: KeymasterTokens? { state.withLock { $0.value } }
    var loadCount: Int { state.withLock { $0.loads } }

    func loadResult() -> KeymasterGrantLoadResult {
        let snapshot = state.withLock { state in
            state.loads += 1
            return state.value
        }
        gate.wait()
        gate.signal()
        return snapshot.map(KeymasterGrantLoadResult.found) ?? .absent
    }

    func save(_ tokens: KeymasterTokens) throws { state.withLock { $0.value = tokens } }
    func clear() { state.withLock { $0.value = nil } }
    func releaseLoad() { gate.signal() }
}

/// Records refresh spends; shared response ownership keeps every unexpected overlapping call
/// releasable. Ignored cancellation models late network replies, while close always settles them.
private final class ParkingRefresher: Sendable {
    private struct State {
        var spent: [String] = []
        var active = 0
        var overlapping = 0
    }
    private let state = Mutex(State())
    private let responses = HarnessResponseGate<KeymasterTokens>(cancellation: .ignored)

    var attemptCount: Int { state.withLock { $0.spent.count } }
    var overlappingSpends: Int { state.withLock { $0.overlapping } }
    var spent: [String] { state.withLock { $0.spent } }
    var waiterCount: Int { responses.waiterCount }

    func refresh(_ refreshToken: String) async throws -> KeymasterTokens {
        state.withLock {
            if $0.active > 0 { $0.overlapping += 1 }
            $0.active += 1
            $0.spent.append(refreshToken)
        }
        defer { state.withLock { $0.active -= 1 } }
        return try await responses.wait()
    }

    func complete(_ tokens: KeymasterTokens) { responses.finish(tokens) }
    func fail(_ error: Error) { responses.resolve(.failure(error)) }
    func close() { responses.close() }
}

private enum CredentialScriptError: Error, Equatable { case exhausted }

private final class CredentialSequence: Sendable {
    private let values: [String]
    private let calls = Mutex(0)

    init(values: [String]) { self.values = values }

    var callCount: Int { calls.withLock { $0 } }

    func next() throws -> String {
        try calls.withLock { calls in
            let index = calls
            calls += 1
            guard values.indices.contains(index) else { throw CredentialScriptError.exhausted }
            return values[index]
        }
    }
}

private actor RecordingInvalidator {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class ScriptedTransport: Sendable {
    private struct State {
        var calls = 0
        var authorizations: [String] = []
        var clients: [String] = []
    }
    private let state = Mutex(State())
    private let responses: [(Int, Data)]

    init(responses: [(Int, Data)]) { self.responses = responses }

    var callCount: Int { state.withLock { $0.calls } }
    var authorizationTokens: [String] { state.withLock { $0.authorizations } }
    var clientTokens: [String] { state.withLock { $0.clients } }

    var send: SpotifyCredentials.Transport { { [self] request in try step(request) } }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        let response = try state.withLock { state in
            let index = state.calls
            state.calls += 1
            if let access = SpotifyCredentials.accessTokenCarried(by: request) { state.authorizations.append(access) }
            if let client = request.value(forHTTPHeaderField: "Client-Token") { state.clients.append(client) }
            guard responses.indices.contains(index) else { throw CredentialScriptError.exhausted }
            return responses[index]
        }
        let url = request.url ?? URL(string: "https://example.invalid/")!
        return (
            response.1, HTTPURLResponse(url: url, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

private extension KeymasterSession {
    /// Completes a hop onto this actor so a just-created revocation stream can install.
    func drainActor() async {
        _ = await hasGrant
    }
}

private final class RevocationProbe: Sendable {
    private let counters: HarnessCounters
    private let listener: Task<Void, Never>

    init(_ stream: AsyncStream<AccountGrantRevocation>) {
        let counters = HarnessCounters()
        self.counters = counters
        listener = Task {
            for await _ in stream { counters.record("announcements") }
        }
    }

    var count: Int { counters.count("announcements") }
    func cancel() { listener.cancel() }
}

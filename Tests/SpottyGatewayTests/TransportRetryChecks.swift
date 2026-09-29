import SpottyTestSupport
import Testing
import SpottyDomain
import Foundation
@testable import SpottyGateway
import SpottyRuntimeContracts

@Test(
    arguments: [false, true],
    [
        ("0", 0.0), ("30", 30.0), ("31", nil), ("99999999999999999999", nil),
        ("  12 ", 12.0), ("  12\n", 0.5), ("", 0.5), ("  ", 0.5), ("+8", 0.5), ("-8", 0.5), ("tomorrow", 0.5),
        ("Mon, 12 Jan 1970 13:46:40 GMT", 0.0), ("Mon, 12 Jan 1970 13:46:10 GMT", 0.0),
        ("Mon, 12 Jan 1970 13:47:10 GMT", 30.0), ("Mon, 12 Jan 1970 14:46:40 GMT", nil),
        ("Monday, 12-Jan-70 13:46:47 GMT", 7.0), ("Mon Jan 12 13:46:47 1970", 7.0),
        ("Mon, 12 Jan 1970 08:46:47 -0500", 7.0),
    ] as [(String, TimeInterval?)])
@MainActor
func retryPolicyHeadersAreObservedThroughBothRequestOwners(
    tokenRequest: Bool, expectation: (header: String, delay: TimeInterval?)
) async throws {
    let sleeper = RecordingSleeper()
    let transport = ScriptedRetryTransport(steps: [
        .http(status: 503, headers: ["Retry-After": expectation.header]),
        .http(status: 200, body: profileBody),
    ])
    let retryTiming = timing(now: Date(timeIntervalSince1970: 1_000_000), sleeper: sleeper)
    if tokenRequest {
        let (_, response) = try await TokenRequestTransport.send(
            URLRequest(url: URL(string: "https://example.invalid/token")!), transport: transport.send,
            timing: retryTiming, retryNetworkErrors: true)
        #expect((response as? HTTPURLResponse)?.statusCode == (expectation.delay == nil ? 503 : 200))
    } else if expectation.delay != nil {
        #expect(try await partnerAPI(transport: transport.send, retryTiming: retryTiming).profile().name == "Listener")
    } else {
        await #expect(throws: PartnerAPIError.requestFailed(503)) {
            try await partnerAPI(transport: transport.send, retryTiming: retryTiming).profile()
        }
    }
    #expect(sleeper.delays == (expectation.delay.map { [$0] } ?? []))
    #expect(transport.callCount == (expectation.delay == nil ? 1 : 2))
}

@Test(arguments: [200, 400, 401, 403, 404, 429, 500, 501, 502, 503, 504])
@MainActor
func retryPolicyStatusClassification(status: Int) async throws {
    let sleeper = RecordingSleeper()
    let transport = ScriptedRetryTransport(steps: [
        .http(status: status), .http(status: 200),
    ])
    let (_, response) = try await TokenRequestTransport.send(
        URLRequest(url: URL(string: "https://example.invalid/token")!), transport: transport.send,
        timing: timing(sleeper: sleeper), retryNetworkErrors: true)
    let retryable = [429, 500, 502, 503, 504].contains(status)
    #expect((response as? HTTPURLResponse)?.statusCode == (retryable ? 200 : status))
    #expect(transport.callCount == (retryable ? 2 : 1))
    #expect(sleeper.delays == (retryable ? [0.5] : []))
}

@Test(
    arguments: [false, true],
    [
        (.timedOut, true), (.networkConnectionLost, true), (.cannotConnectToHost, true),
        (.cancelled, false), (.secureConnectionFailed, false), (.notConnectedToInternet, false),
        (.cannotFindHost, false), (.userCancelledAuthentication, false),
    ] as [(URLError.Code, Bool)])
@MainActor
func retryPolicyNetworkClassificationPreservesRotatingTokenSafety(
    allowNetworkRetry: Bool, expectation: (code: URLError.Code, retryable: Bool)
) async throws {
    let sleeper = RecordingSleeper()
    let transport = ScriptedRetryTransport(steps: [.urlError(expectation.code), .http(status: 200)])
    let canRetry = allowNetworkRetry && expectation.retryable
    let send = {
        try await TokenRequestTransport.send(
            URLRequest(url: URL(string: "https://example.invalid/token")!), transport: transport.send,
            timing: timing(sleeper: sleeper), retryNetworkErrors: allowNetworkRetry)
    }
    if canRetry {
        let (_, response) = try await send()
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    } else {
        await expectURLError("terminal network error retains its code", expectation.code) { _ = try await send() }
    }
    #expect(transport.callCount == (canRetry ? 2 : 1))
    #expect(sleeper.delays == (canRetry ? [0.5] : []))
}

@Test(
    arguments: [
        (-1.0, [0.25, 0.5]), (0, [0.25, 0.5]), (0.5, [0.375, 0.75]), (1, [0.5, 1]), (2, [0.5, 1]),
    ] as [(Double, [Double])])
@MainActor
func retryPolicyBackoffHasThreeAttemptsAndTwoBoundedWaits(expectation: (jitter: Double, delays: [Double])) async throws
{
    let sleeper = RecordingSleeper()
    let transport = ScriptedRetryTransport(steps: Array(repeating: .http(status: 503), count: 4))
    let (_, response) = try await TokenRequestTransport.send(
        URLRequest(url: URL(string: "https://example.invalid/token")!), transport: transport.send,
        timing: timing(sleeper: sleeper, jitter: expectation.jitter), retryNetworkErrors: true)
    #expect((response as? HTTPURLResponse)?.statusCode == 503)
    #expect(transport.callCount == 3)
    #expect(sleeper.delays == expectation.delays)
}

@Test(arguments: [false, true])
@MainActor
func cancelledRetryWaitCannotSendAgain(tokenRequest: Bool) async throws {
    let release = HarnessResponseGate<Void>(cancellation: .ignored)
    defer { release.close() }
    let transport = ScriptedRetryTransport(steps: [.http(status: 503), .http(status: 200, body: profileBody)])
    let retryTiming = SpotifyTransientRetry.Timing(
        now: { HarnessDates.fixed }, sleep: { _ in try await release.wait() }, unitJitter: { 1 })
    let request = Task {
        if tokenRequest {
            _ = try await TokenRequestTransport.send(
                URLRequest(url: URL(string: "https://example.invalid/token")!), transport: transport.send,
                timing: retryTiming, retryNetworkErrors: true)
        } else {
            _ = try await partnerAPI(transport: transport.send, retryTiming: retryTiming).profile()
        }
    }
    defer { request.cancel() }
    try await requireEventually { release.waiterCount == 1 }
    request.cancel()
    release.finish(())
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(transport.callCount == 1)
}

@Test("Cancelled refusals cannot start credential rotation", arguments: [false, true])
@MainActor
func cancelledRefusalDoesNotRefreshCredentials(cancelDuringClientInvalidation: Bool) async throws {
    let gate = HarnessClock(sleep: .uncooperativelyParked)
    defer { gate.releaseAll() }
    let invalidatedAccess = RecordingInvalidator()
    let invalidatedClient = RecordingInvalidator()
    let request = Task {
        try await SpotifyCredentials.retryingRefusedCredentials(
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: {
                await invalidatedClient.record($0)
                if cancelDuringClientInvalidation { try? await gate.sleep(seconds: 1) }
            },
            prepare: { @Sendable in URLRequest(url: URL(string: "https://example.invalid/")!) },
            send: { @Sendable _ in
                if !cancelDuringClientInvalidation { try await gate.sleep(seconds: 1) }
                return SpotifyCredentials.Attempt(
                    body: Data(), status: 401, accessToken: "fixture-access", clientToken: "fixture-client")
            })
    }
    defer { request.cancel() }
    try await requireEventually { gate.waiterCount == 1 }
    request.cancel()
    gate.releaseAll()
    do {
        _ = try await request.value
        Issue.record("The cancelled request must report cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await invalidatedAccess.values.isEmpty, "Cancellation must not spend a rotating refresh token")
    #expect(await invalidatedClient.values == (cancelDuringClientInvalidation ? ["fixture-client"] : []))
}

// Keep each independent transport contract in its own Swift Testing case. This reduces the amount
// of actor-isolated work one runner task owns and improves stall localization; it is a test-shape
// improvement, not evidence that a runner-level wedge has been cured.
@Test("Transport Retry-After parsing and waiting budget")
@MainActor
func transportRetryAfter() async {
    let deltaSleep = RecordingSleeper()
    let deltaTransport = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "7"]),
        .http(status: 200, body: profileBody),
    ])
    let deltaProfile = try? await partnerAPI(
        transport: deltaTransport.send,
        retryTiming: timing(sleeper: deltaSleep)
    ).profile()
    #expect((deltaProfile?.name) == ("Listener"), "Retry-After delta succeeds after one retry")
    #expect((deltaSleep.delays) == ([7]), "Retry-After delta is the recorded delay")
    #expect((deltaTransport.callCount) == (2), "Retry-After delta attempts twice")

    let dateSleep = RecordingSleeper()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let dateTransport = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "Mon, 12 Jan 1970 13:46:52 GMT"]),
        .http(status: 200, body: profileBody),
    ])
    let dateProfile = try? await partnerAPI(
        transport: dateTransport.send,
        retryTiming: timing(now: now, sleeper: dateSleep)
    ).profile()
    #expect((dateProfile?.name) == ("Listener"), "Retry-After HTTP-date succeeds after one retry")
    #expect((dateSleep.delays) == ([12]), "Retry-After HTTP-date delay is the delta until that instant")

    let malformedSleep = RecordingSleeper()
    let malformedTransport = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "not-a-delay"]),
        .http(status: 200, body: profileBody),
    ])
    let malformedProfile = try? await partnerAPI(
        transport: malformedTransport.send,
        retryTiming: timing(sleeper: malformedSleep, jitter: 1)
    ).profile()
    #expect((malformedProfile?.name) == ("Listener"), "malformed Retry-After still retries")
    #expect(
        (malformedSleep.delays) == ([0.5]),
        "malformed Retry-After uses the first backoff")

    let cappedSleep = RecordingSleeper()
    let cappedTransport = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "3600"]),
        .http(status: 200, body: profileBody),
    ])
    await expectThrown("long throttles are surfaced without replay", PartnerAPIError.requestFailed(429)) {
        _ = try await partnerAPI(
            transport: cappedTransport.send,
            retryTiming: timing(sleeper: cappedSleep)
        ).profile()
    }
    #expect(cappedSleep.delays.isEmpty)
    #expect(cappedTransport.callCount == 1)
}

@Test("Transport transient status and URL error classifications have a finite budget")
@MainActor
func transportTransientClassificationsAndBudget() async {
    let fiveSleep = RecordingSleeper()
    let fiveTransport = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 200, body: profileBody),
    ])
    let recovered = try? await partnerAPI(
        transport: fiveTransport.send,
        retryTiming: timing(sleeper: fiveSleep, jitter: 1)
    ).profile()
    #expect((recovered?.name) == ("Listener"), "transient 5xx succeeds after retry")
    #expect((fiveSleep.delays) == ([0.5]), "transient 5xx uses backoff")
    #expect((fiveTransport.callCount) == (2), "transient 5xx attempts twice")

    let budget = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 502),
        .http(status: 500),
        .http(status: 200, body: profileBody),
    ])
    await expectThrown("the attempt budget is finite", PartnerAPIError.requestFailed(500)) {
        _ = try await partnerAPI(transport: budget.send).profile()
    }
    #expect((budget.callCount) == (3), "budget stops after three attempts")

    let timeoutThenOk = ScriptedRetryTransport(steps: [
        .urlError(.timedOut),
        .http(status: 200, body: profileBody),
    ])
    let afterTimeout = try? await partnerAPI(transport: timeoutThenOk.send).profile()
    #expect((afterTimeout?.name) == ("Listener"), "timeout URLError retries and succeeds")
    #expect((timeoutThenOk.callCount) == (2), "timeout URLError attempts twice")

    let lostThenOk = ScriptedRetryTransport(steps: [
        .urlError(.networkConnectionLost),
        .http(status: 200, body: profileBody),
    ])
    #expect(
        ((try? await partnerAPI(transport: lostThenOk.send).profile())?.name) == ("Listener"),
        "networkConnectionLost retries")

    let hostThenOk = ScriptedRetryTransport(steps: [
        .urlError(.cannotConnectToHost),
        .http(status: 200, body: profileBody),
    ])
    #expect(
        ((try? await partnerAPI(transport: hostThenOk.send).profile())?.name) == ("Listener"),
        "cannotConnectToHost retries")

    let cancelled = ScriptedRetryTransport(steps: [.urlError(.cancelled)])
    await expectURLError("cancelled URLError is not retried", .cancelled) {
        _ = try await partnerAPI(transport: cancelled.send).profile()
    }
    #expect((cancelled.callCount) == (1), "cancelled URLError is one attempt")

    let tls = ScriptedRetryTransport(steps: [.urlError(.secureConnectionFailed)])
    await expectURLError("TLS URLError is not retried", .secureConnectionFailed) {
        _ = try await partnerAPI(transport: tls.send).profile()
    }
    #expect((tls.callCount) == (1), "disallowed URLError is one attempt")

    let offline = ScriptedRetryTransport(steps: [.urlError(.notConnectedToInternet)])
    await expectURLError("offline URLError is not retried", .notConnectedToInternet) {
        _ = try await partnerAPI(transport: offline.send).profile()
    }
    #expect((offline.callCount) == (1), "offline URLError is one attempt")

}

@Test("Web queue reads do not use generic transport replay")
@MainActor
func webQueueDoesNotReplay() async {
    let queueSleep = RecordingSleeper()
    let queueTransport = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "1"]),
        .http(status: 200, body: queueBody),
    ])
    await expectThrown(
        "Web queue 429 is not generic-replayed",
        SpotifyWebPlayerAPIError.requestFailed(429)
    ) {
        _ = try await SpotifyWebPlayerAPI(
            accessToken: { "queue-a" },
            invalidateAccessToken: { _ in },
            transport: queueTransport.send,
            retryTiming: timing(sleeper: queueSleep)
        ).queue()
    }
    #expect((queueTransport.callCount) == (1), "Web queue 429 is one GET")
    #expect((queueSleep.delays) == ([]), "Web queue 429 does not sleep in the generic retry layer")
    #expect((queueTransport.methods) == (["GET"]), "Web queue 429 is GET")
    #expect(
        (queueTransport.urls) == ([SpotifyWebPlayerAPI.queueURL.absoluteString]),
        "Web queue 429 hits the documented endpoint")
}

@Test("Transport credential refusal and transient failure share one attempt budget")
@MainActor
func transportCredentialRefusalAndMixedBudget() async {
    let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
    let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
    let invalidatedAccess = RecordingInvalidator()
    let invalidatedClient = RecordingInvalidator()
    let mixed = ScriptedRetryTransport(steps: [
        .http(status: 401),
        .http(status: 503),
        .http(status: 200, body: profileBody),
    ])
    let recovered = try? await PartnerAPI(
        accessToken: { tokens.next() },
        clientToken: { clients.next() },
        invalidateAccessToken: { await invalidatedAccess.record($0) },
        invalidateClientToken: { await invalidatedClient.record($0) },
        transport: mixed.send,
        retryTiming: .immediate
    ).profile()
    #expect((recovered?.name) == ("Listener"), "401 then 5xx still succeeds within the budget")
    #expect((await invalidatedAccess.values) == (["access-a"]), "credentials invalidate once")
    #expect((await invalidatedClient.values) == (["client-a"]), "client token invalidates once")
    #expect((mixed.callCount) == (3), "401 plus transient retry is three attempts")
    #expect((tokens.callCount) == (3), "each attempt signs again")

    let second401 = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 401),
        .http(status: 401),
        .http(status: 200, body: profileBody),
    ])
    let tokensB = CredentialSequence(values: ["a", "b", "c"])
    let clientsB = CredentialSequence(values: ["ca", "cb", "cc"])
    let accessB = RecordingInvalidator()
    var status = 0
    do {
        _ = try await PartnerAPI(
            accessToken: { tokensB.next() },
            clientToken: { clientsB.next() },
            invalidateAccessToken: { await accessB.record($0) },
            invalidateClientToken: { _ in },
            transport: second401.send,
            retryTiming: .immediate
        ).profile()
    } catch let error as PartnerAPIError {
        if case let .requestFailed(code) = error { status = code }
    } catch {
        #expect((false) == true, "second 401 stays PartnerAPIError, got \(error)")
    }
    #expect((status) == (401), "a second 401 stops even when budget remains")
    #expect((second401.callCount) == (3), "a second 401 does not consume a fourth attempt")
    #expect((await accessB.values) == (["b", "c"]), "each 401 names its sent bearer")

}

@Test("Task cancellation while retry backoff is parked stops replay")
@MainActor
func transportTaskCancellationDuringParkedBackoff() async throws {
    let clock = HarnessClock.parked()
    defer { clock.releaseAll() }
    let parked = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "5"]),
        .http(status: 200, body: profileBody),
    ])
    let task = Task {
        try await partnerAPI(
            transport: parked.send,
            retryTiming: SpotifyTransientRetry.Timing(
                now: { clock.now() },
                sleep: { try await clock.sleep(seconds: $0) },
                unitJitter: { 1 }
            )
        ).profile()
    }
    defer { task.cancel() }
    try await requireEventually { clock.waiterCount == 1 }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(parked.callCount == 1, "Cancellation during backoff does not send the retry")
    #expect(clock.requestedSleeps == [5], "Cancellation still records the Retry-After delay")
}

@Test("Concurrent rejected bearer reads adopt the replacement independently")
@MainActor
func concurrentRejectedBearerReplacement() async throws {
    let started = HarnessResponseGate<Void>()
    defer { started.close() }
    let current = SharedToken("access-a")
    let invalidatedAccess = RecordingInvalidator()
    let concurrent = BearerResponseTransport { token in
        token == "access-a" ? .http(status: 401) : .http(status: 200, body: profileBody)
    }
    let api = PartnerAPI(
        accessToken: {
            let token = await current.value()
            if token == "access-a" {
                try await started.wait()
            }
            return token
        },
        clientToken: { "client-a" },
        invalidateAccessToken: { rejected in
            await invalidatedAccess.record(rejected)
            await current.replace(rejected, with: "access-b")
        },
        invalidateClientToken: { _ in },
        transport: concurrent.send,
        retryTiming: .immediate
    )
    let first = Task { try await api.profile() }
    let second = Task { try await api.profile() }
    defer { first.cancel(); second.cancel() }
    try await requireEventually { started.waiterCount == 2 }
    started.finish(())
    started.finish(())
    let names = [(try? await first.value)?.name, (try? await second.value)?.name]
    #expect((names.allSatisfy { $0 == "Listener" }) == true, "both concurrent reads succeed")
    #expect(
        (await invalidatedAccess.values) == (["access-a", "access-a"]),
        "each concurrent 401 names the rejected bearer")
    #expect((concurrent.callCount) == (4), "concurrent reads retry independently")

}

@Test("Mutations and Connect commands do not replay")
@MainActor
func mutationAndConnectCommandsDoNotReplay() async {
    let mutation = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 200, body: Data()),
    ])
    await expectThrown(
        "PartnerAPI mutations do not replay a lost 5xx",
        PartnerAPIError.requestFailed(503)
    ) {
        try await partnerAPI(transport: mutation.send).addToPlaylist(
            playlistId: "pl",
            trackUris: ["spotify:track:t"]
        )
    }
    #expect((mutation.callCount) == (1), "a playlist mutation is one attempt")

    let connect = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 200, body: Data()),
    ])
    await expectThrown(
        "Connect commands do not replay a lost 5xx",
        SpotifyConnectAPIError.requestFailed(503)
    ) {
        try await SpotifyConnectAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateAccessToken: { _ in },
            invalidateClientToken: { _ in },
            transport: connect.send,
            retryTiming: .immediate
        ).send(.pause, from: "source", to: "target")
    }
    #expect((connect.callCount) == (1), "a Connect command is one attempt")
}

@Test("Budget-final credential refusal still invalidates the rejected credentials")
@MainActor
func budgetFinalCredentialInvalidation() async {
    let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c", "access-d"])
    let clients = CredentialSequence(values: ["client-a", "client-b", "client-c", "client-d"])
    let invalidatedAccess = RecordingInvalidator()
    let invalidatedClient = RecordingInvalidator()
    let fiveThen401 = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 503),
        .http(status: 401),
        .http(status: 200, body: profileBody),
    ])
    var fiveStatus = 0
    do {
        _ = try await PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: fiveThen401.send,
            retryTiming: .immediate
        ).profile()
    } catch let error as PartnerAPIError {
        if case let .requestFailed(code) = error { fiveStatus = code }
    } catch {
        #expect((false) == true, "budget-final 401 stays PartnerAPIError, got \(error)")
    }
    #expect((fiveStatus) == (401), "5xx then 401 returns the terminal 401")
    #expect((fiveThen401.callCount) == (3), "5xx then 401 is three attempts")
    #expect((await invalidatedAccess.values) == (["access-c"]), "the final 401 bearer is invalidated")
    #expect((await invalidatedClient.values) == (["client-c"]), "the final 401 client token is invalidated")
    #expect((tokens.callCount) == (3), "no fourth credential fetch after the budget-final 401")

    let timeoutTokens = CredentialSequence(values: ["timeout-a", "timeout-b", "timeout-c", "timeout-d"])
    let timeoutClients = CredentialSequence(values: [
        "client-timeout-a", "client-timeout-b", "client-timeout-c",
    ])
    let timeoutAccess = RecordingInvalidator()
    let timeoutClient = RecordingInvalidator()
    let timeoutThen401 = ScriptedRetryTransport(steps: [
        .urlError(.timedOut),
        .urlError(.timedOut),
        .http(status: 401),
        .http(status: 200, body: profileBody),
    ])
    var timeoutStatus = 0
    do {
        _ = try await PartnerAPI(
            accessToken: { timeoutTokens.next() },
            clientToken: { timeoutClients.next() },
            invalidateAccessToken: { await timeoutAccess.record($0) },
            invalidateClientToken: { await timeoutClient.record($0) },
            transport: timeoutThen401.send,
            retryTiming: .immediate
        ).profile()
    } catch let error as PartnerAPIError {
        if case let .requestFailed(code) = error { timeoutStatus = code }
    } catch {
        #expect((false) == true, "timeout then 401 stays PartnerAPIError, got \(error)")
    }
    #expect((timeoutStatus) == (401), "timeout then 401 returns the terminal 401")
    #expect((timeoutThen401.callCount) == (3), "timeout then 401 is three attempts")
    #expect((await timeoutAccess.values) == (["timeout-c"]), "the timeout-final 401 bearer is invalidated")
    #expect(
        (await timeoutClient.values) == (["client-timeout-c"]),
        "the timeout-final 401 client token is invalidated")
    #expect((timeoutTokens.callCount) == (3), "no fourth credential fetch after the timeout-final 401")

}

@Test("Web queue transient failure remains a single fallback attempt")
@MainActor
func webQueueTransientFailureDoesNotReplay() async {
    let queueTokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c", "queue-d"])
    let queueAccess = RecordingInvalidator()
    let queueTransient = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 401),
        .http(status: 200, body: queueBody),
    ])
    await expectThrown(
        "Web queue 503 is not generic-replayed",
        SpotifyWebPlayerAPIError.requestFailed(503)
    ) {
        _ = try await SpotifyWebPlayerAPI(
            accessToken: { queueTokens.next() },
            invalidateAccessToken: { await queueAccess.record($0) },
            transport: queueTransient.send,
            retryTiming: .immediate
        ).queue()
    }
    #expect((queueTransient.callCount) == (1), "Web queue 503 is one GET")
    #expect((await queueAccess.values) == ([]), "Web queue 503 does not invalidate a bearer")
    #expect((queueTokens.callCount) == (1), "Web queue 503 does not fetch a replacement bearer")
}

@Test("Throwing terminal credential invalidation propagates")
@MainActor
func throwingTerminalCredentialInvalidation() async {
    let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c", "access-d"])
    let clients = CredentialSequence(values: ["client-a", "client-b", "client-c", "client-d"])
    let invalidatedClient = RecordingInvalidator()
    let thrown = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 503),
        .http(status: 401),
        .http(status: 200, body: profileBody),
    ])
    var revoked = false
    do {
        _ = try await PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { _ in throw KeymasterSessionError.grantRevoked },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: thrown.send,
            retryTiming: .immediate
        ).profile()
    } catch KeymasterSessionError.grantRevoked {
        revoked = true
    } catch {
        #expect((false) == true, "budget-final bearer throw stays grantRevoked, got \(error)")
    }
    #expect((revoked) == true, "a budget-final bearer throw still surfaces grantRevoked")
    #expect(
        (await invalidatedClient.values) == (["client-c"]),
        "client token drops before the terminal bearer throw")
    #expect((thrown.callCount) == (3), "a terminal bearer throw does not add a request")
    #expect((tokens.callCount) == (3), "a terminal bearer throw does not fetch another credential")
}

@Test("Terminal invalidation cancellation propagates")
@MainActor
func terminalInvalidationCancellationPropagates() async {
    let tokens = CredentialSequence(values: ["cancel-a", "cancel-b", "cancel-c", "cancel-d"])
    let clients = CredentialSequence(values: [
        "cancel-client-a", "cancel-client-b", "cancel-client-c",
    ])
    let invalidator = CancellationThrowingInvalidator()
    let transport = ScriptedRetryTransport(steps: [
        .http(status: 503),
        .http(status: 503),
        .http(status: 401),
        .http(status: 200, body: profileBody),
    ])
    // Keep the cancellation probe in its own test task. Xcode 26.6 can strand this retry hop
    // when it follows the large retry matrix, before the terminal invalidator is reached.
    var propagatedCancellation = false
    do {
        _ = try await PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { try await invalidator.invalidate($0) },
            invalidateClientToken: { _ in },
            transport: transport.send,
            retryTiming: .immediate
        ).profile()
    } catch is CancellationError {
        propagatedCancellation = true
    } catch {
        #expect((false) == true, "terminal invalidation preserves CancellationError, got \(error)")
    }
    #expect(
        (propagatedCancellation) == true,
        "CancellationError from terminal invalidation propagates")
    #expect((transport.callCount) == (3), "terminal invalidation cancellation does not add a request")
    #expect((invalidator.values) == (["cancel-c"]), "cancellation still names the final bearer")
    #expect((tokens.callCount) == (3), "cancellation does not fetch another credential")
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

private func partnerAPI(
    transport: @escaping SpotifyCredentials.Transport,
    retryTiming: SpotifyTransientRetry.Timing = .immediate
) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: retryTiming
    )
}

private func timing(
    now: Date = Date(timeIntervalSince1970: 0),
    sleeper: RecordingSleeper,
    jitter: Double = 1
) -> SpotifyTransientRetry.Timing {
    SpotifyTransientRetry.Timing(
        now: { now },
        sleep: { try await sleeper.sleep($0) },
        unitJitter: { jitter }
    )
}

@MainActor
private func expectThrown<Failure: Error & Equatable>(
    _ label: String,
    _ expected: Failure,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as Failure {
        #expect((error) == (expected), "\(label)")
    } catch {
        #expect((false) == true, "\(label) throws \(Failure.self), got \(error)")
    }
}

@MainActor
private func expectURLError(
    _ label: String,
    _ code: URLError.Code,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as URLError {
        #expect((error.code) == (code), "\(label) keeps URLError.code")
    } catch {
        #expect((false) == true, "\(label) throws URLError, got \(error)")
    }
}

private enum RetryStep {
    case http(status: Int, body: Data = Data(), headers: [String: String] = [:])
    case urlError(URLError.Code)
}

private enum RetryScriptFailure: Error { case exhausted }

private final class ScriptedRetryTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [RetryStep]
    private var index = 0
    private var recordedMethods: [String] = []
    private var recordedURLs: [String] = []
    private var recordedClientTokens: [String] = []

    init(steps: [RetryStep]) {
        self.steps = steps
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var methods: [String] {
        lock.withLock { recordedMethods }
    }

    var urls: [String] {
        lock.withLock { recordedURLs }
    }

    var clientTokens: [String] {
        lock.withLock { recordedClientTokens }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let stepIndex = index
        index += 1
        recordedMethods.append(request.httpMethod ?? "GET")
        recordedURLs.append(request.url?.absoluteString ?? "")
        if let client = request.value(forHTTPHeaderField: "Client-Token"), !client.isEmpty {
            recordedClientTokens.append(client)
        }
        guard steps.indices.contains(stepIndex) else {
            Issue.record("Unexpected transport attempt \(stepIndex + 1); the retry script is exhausted")
            throw RetryScriptFailure.exhausted
        }
        let step = steps[stepIndex]
        let url = request.url ?? URL(string: "https://example.invalid/")!
        switch step {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        case let .urlError(code):
            throw URLError(code)
        }
    }
}

private final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.withLock { recorded }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
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
        let valueIndex = index
        index += 1
        guard values.indices.contains(valueIndex) else {
            Issue.record("Unexpected credential read \(valueIndex + 1); the credential script is exhausted")
            return "unexpected-fixture-token"
        }
        return values[valueIndex]
    }
}

private actor RecordingInvalidator {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class CancellationThrowingInvalidator: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.withLock { recorded }
    }

    func invalidate(_ value: String) async throws {
        lock.withLock { recorded.append(value) }
        throw CancellationError()
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

private final class BearerResponseTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let response: @Sendable (String?) -> RetryStep

    init(response: @escaping @Sendable (String?) -> RetryStep) {
        self.response = response
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        index += 1
        lock.unlock()
        let url = request.url ?? URL(string: "https://example.invalid/")!
        switch response(SpotifyCredentials.accessTokenCarried(by: request)) {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        case let .urlError(code):
            throw URLError(code)
        }
    }
}

@Test("Token endpoint transient retry and rotating-grant safety")
@MainActor
func tokenEndpointRetries() async throws {
    let tokens = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
    let retry = ScriptedRetryTransport(steps: [.http(status: 503), .http(status: 200, body: tokens)])
    let result = try await KeymasterAuth.postToken(
        body: Data(), fallbackRefreshToken: "old-refresh",
        transport: retry.send, retryTiming: .immediate)
    #expect(result.refreshToken == "new-refresh")
    #expect(retry.callCount == 2)

    let sleeper = RecordingSleeper()
    let rateLimited = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "7"]), .http(status: 200, body: tokens),
    ])
    _ = try await KeymasterAuth.postToken(
        body: Data(), fallbackRefreshToken: "old-refresh",
        transport: rateLimited.send, retryTiming: timing(sleeper: sleeper))
    #expect(sleeper.delays == [7])

    let longThrottle = ScriptedRetryTransport(steps: [
        .http(status: 429, headers: ["Retry-After": "3600"]), .http(status: 200, body: tokens),
    ])
    await #expect(throws: KeymasterAuthError.tokenExchangeFailed(429)) {
        try await KeymasterAuth.postToken(
            body: Data(), fallbackRefreshToken: "old-refresh",
            transport: longThrottle.send, retryTiming: timing(sleeper: sleeper))
    }
    #expect(longThrottle.callCount == 1)
    #expect(sleeper.delays == [7], "the token endpoint must not sleep and retry ahead of a long throttle")

    let revoked = ScriptedRetryTransport(steps: [
        .http(status: 503, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    ])
    await #expect(throws: KeymasterAuthError.grantRevoked) {
        try await KeymasterAuth.postToken(
            body: Data(), fallbackRefreshToken: "old-refresh",
            transport: revoked.send, retryTiming: .immediate)
    }
    #expect(revoked.callCount == 1)

    let lost = ScriptedRetryTransport(steps: [.urlError(.networkConnectionLost)])
    await #expect(throws: URLError.self) {
        try await KeymasterAuth.postToken(
            body: Data(), fallbackRefreshToken: "old-refresh",
            transport: lost.send, retryTiming: .immediate)
    }
    #expect(lost.callCount == 1, "A lost rotating-refresh response cannot safely be replayed")

    let exhausted = ScriptedRetryTransport(steps: [.http(status: 503), .http(status: 503), .http(status: 503)])
    await #expect(throws: KeymasterAuthError.tokenExchangeFailed(503)) {
        try await KeymasterAuth.postToken(
            body: Data(), fallbackRefreshToken: "old-refresh",
            transport: exhausted.send, retryTiming: .immediate)
    }
    #expect(exhausted.callCount == SpotifyTransientRetry.maximumAttempts)

    // Independent response fixture: granted token "synthetic-client", lifetime 100 seconds.
    let grant =
        Data([0x08, 0x01, 0x12, 0x14, 0x0A, 0x10])
        + Data("synthetic-client".utf8) + Data([0x10, 0x64])
    let client = ScriptedRetryTransport(steps: [
        .http(status: 503), .urlError(.timedOut), .http(status: 200, body: grant),
    ])
    #expect(
        try await ClientTokenRequest.send(
            deviceId: "synthetic", transport: client.send,
            retryTiming: .immediate
        ).token == "synthetic-client")
    #expect(client.callCount == 3)

    let challenge = Data([0x08, 0x02])
    let challenged = ScriptedRetryTransport(steps: [.http(status: 200, body: challenge)])
    await #expect(throws: ClientTokenError.challenged) {
        try await ClientTokenRequest.send(deviceId: "synthetic", transport: challenged.send, retryTiming: .immediate)
    }
    #expect(challenged.callCount == 1)
}

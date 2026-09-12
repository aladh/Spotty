import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime
@testable import SpottyGateway
import SpottyRuntimeContracts

@Test("Transport Retry")
@MainActor
func testTransportRetry() async {
    do {
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
            (malformedSleep.delays) == ([SpotifyTransientRetry.backoffDelay(completedAttempts: 1, unitJitter: 1)]),
            "malformed Retry-After uses the first backoff")

        let cappedSleep = RecordingSleeper()
        let cappedTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "3600"]),
            .http(status: 200, body: profileBody),
        ])
        _ = try? await partnerAPI(
            transport: cappedTransport.send,
            retryTiming: timing(sleeper: cappedSleep)
        ).profile()
        #expect((cappedSleep.delays) == ([SpotifyTransientRetry.maximumDelaySeconds]), "huge Retry-After is capped")
    }

    do {
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

    do {
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

        let sleeper = ParkUntilCancelledSleeper()
        let parked = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "5"]),
            .http(status: 200, body: profileBody),
        ])
        // The cancellation probe must not inherit this test's MainActor isolation. A parked
        // unstructured MainActor child can otherwise outlive a failed synchronization and block
        // unrelated MainActor suites from starting.
        let task = Task.detached {
            try await partnerAPI(
                transport: parked.send,
                retryTiming: SpotifyTransientRetry.Timing(
                    now: { Date(timeIntervalSince1970: 0) },
                    sleep: { try await sleeper.sleep($0) },
                    unitJitter: { 1 }
                )
            ).profile()
        }
        await expectEventually { sleeper.hasStarted }
        task.cancel()
        var cancelledDuringBackoff = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelledDuringBackoff = true
        } catch {
            #expect((false) == true, "backoff cancellation stays CancellationError, got \(error)")
        }
        #expect((cancelledDuringBackoff) == true, "cancellation during backoff surfaces CancellationError")
        #expect((parked.callCount) == (1), "cancellation during backoff does not send the retry")
        #expect((sleeper.delays) == ([5]), "cancellation still recorded the Retry-After delay")
    }

    do {
        let started = StartedGate(count: 2)
        let current = SharedToken("access-a")
        let invalidatedAccess = RecordingInvalidator()
        let concurrent = BearerResponseTransport { token in
            token == "access-a" ? .http(status: 401) : .http(status: 200, body: profileBody)
        }
        let api = PartnerAPI(
            accessToken: {
                let token = await current.value()
                if token == "access-a" {
                    started.mark()
                    await started.wait()
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
        async let first = api.profile()
        async let second = api.profile()
        let names = [(try? await first)?.name, (try? await second)?.name]
        #expect((names.allSatisfy { $0 == "Listener" }) == true, "both concurrent reads succeed")
        #expect(
            (await invalidatedAccess.values) == (["access-a", "access-a"]),
            "each concurrent 401 names the rejected bearer")
        #expect((concurrent.callCount) == (4), "concurrent reads retry independently")

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

    do {
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

    do {
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

        let parkedTokens = CredentialSequence(values: ["park-a", "park-b", "park-c", "park-d"])
        let parkedClients = CredentialSequence(values: ["park-client-a", "park-client-b", "park-client-c"])
        let parkedAccess = ParkUntilCancelledInvalidator()
        let parked = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 503),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        // Keep this parked cancellation probe off MainActor for the same reason as the retry
        // backoff probe above. The bounded start check also guarantees cleanup on a regression.
        let task = Task.detached {
            try await PartnerAPI(
                accessToken: { parkedTokens.next() },
                clientToken: { parkedClients.next() },
                invalidateAccessToken: { try await parkedAccess.park($0) },
                invalidateClientToken: { _ in },
                transport: parked.send,
                retryTiming: .immediate
            ).profile()
        }
        await expectEventually { await parkedAccess.hasStarted }
        task.cancel()
        var cancelledDuringInvalidation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelledDuringInvalidation = true
        } catch {
            #expect((false) == true, "terminal invalidation cancellation stays CancellationError, got \(error)")
        }
        #expect(
            (cancelledDuringInvalidation) == true,
            "cancellation during terminal invalidation surfaces CancellationError")
        #expect((parked.callCount) == (3), "cancellation during terminal invalidation does not add a request")
        #expect((await parkedAccess.values) == (["park-c"]), "cancellation still named the final bearer")
        #expect((parkedTokens.callCount) == (3), "cancellation does not fetch another credential")
    }

    do {
        let clock = ControllablePlaybackClock(Date(timeIntervalSince1970: 1_700_000_000))
        let fallback = [
            QueueEntry(uri: "spotify:track:alpha", provider: "connect", occurrence: 0, uid: "uid-alpha"),
            QueueEntry(uri: "spotify:track:beta", provider: "connect", occurrence: 1, uid: "uid-beta"),
        ]
        let cached = [
            queueCheckTrack("spotify:track:alpha"),
            queueCheckTrack("spotify:track:beta"),
        ]
        let webQueue = RateLimitedThenAvailableWebQueue(tracks: [queueCheckTrack("spotify:track:web")])
        let limitedService = QueueService(
            webQueue: webQueue,
            metadata: TrackMetadataService(remote: UnusedQueueRemote()),
            clock: clock
        )
        await limitedService.reset(accountEpoch: 11)

        let first = await limitedService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 11
        )
        #expect((await webQueue.callCount) == (1), "first 429 performs one Web queue call")
        #expect((first?.source) == (.connect), "first 429 falls back to Connect")
        #expect((first?.completeness) == (.complete), "first 429 Connect fallback is complete")
        #expect(
            (first?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
            "first 429 preserves Connect order")
        #expect(
            (first?.entries.map(\.uid)) == (["uid-alpha", "uid-beta"]),
            "first 429 preserves Connect occurrence uids")

        let second = await limitedService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 11
        )
        #expect((await webQueue.callCount) == (1), "cooldown refresh makes no second Web request")
        #expect((second?.source) == (.connect), "cooldown refresh still uses Connect")
        #expect((second?.completeness) == (.complete), "cooldown refresh stays complete")
        #expect(
            (second?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
            "cooldown refresh keeps Connect order")
        clock.advance(seconds: 5 * 60 + 1)
        let recovered = await limitedService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 11
        )
        #expect((await webQueue.callCount) == (2), "expired cooldown retries the Web queue once")
        #expect((recovered?.source) == (.connect), "expired cooldown keeps authoritative Connect order")
        #expect(
            (recovered?.entries.map(\.uri)) == (["spotify:track:alpha", "spotify:track:beta"]),
            "expired cooldown does not let Web reorder Connect entries")
        #expect(
            (recovered?.entries.map(\.uid)) == (["uid-alpha", "uid-beta"]),
            "expired cooldown preserves Connect occurrence uids")
    }
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

private func queueCheckTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private struct UnusedQueueRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri, title: "Unused", artist: "Unused", artworkURL: nil, duration: 1
        )
    }
}

private actor RateLimitedThenAvailableWebQueue: WebQueueClient {
    private let tracks: [CatalogTrack]
    private(set) var callCount = 0

    init(tracks: [CatalogTrack]) {
        self.tracks = tracks
    }

    func queue() async throws -> [CatalogTrack] {
        callCount += 1
        if callCount == 1 {
            throw SpotifyWebPlayerAPIError.requestFailed(429)
        }
        return tracks
    }
}

private final class ControllablePlaybackClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(seconds _: TimeInterval) async throws {}
}

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
        let step = steps[index]
        index += 1
        recordedMethods.append(request.httpMethod ?? "GET")
        recordedURLs.append(request.url?.absoluteString ?? "")
        if let client = request.value(forHTTPHeaderField: "Client-Token"), !client.isEmpty {
            recordedClientTokens.append(client)
        }
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

private final class ParkUntilCancelledSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var didStart = false

    var delays: [TimeInterval] {
        lock.withLock { recorded }
    }

    var hasStarted: Bool {
        lock.withLock { didStart }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock {
            recorded.append(seconds)
            didStart = true
        }
        try await HarnessClock.parked().sleep(seconds: 60)
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

private actor ParkUntilCancelledInvalidator {
    private(set) var values: [String] = []
    private(set) var hasStarted = false

    func park(_ value: String) async throws {
        values.append(value)
        hasStarted = true
        try await HarnessClock.parked().sleep(seconds: 60)
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

private final class StartedGate: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var marked = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        target = count
    }

    func mark() {
        lock.lock()
        marked += 1
        let ready = marked >= target
        let toResume: [CheckedContinuation<Void, Never>]
        if ready {
            toResume = waiters
            waiters = []
        } else {
            toResume = []
        }
        lock.unlock()
        for waiter in toResume {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if marked >= target {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
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

    var grant = ProtobufWriter()
    grant.varint(field: 1, 1)
    grant.message(field: 2) { token in
        token.string(field: 1, "synthetic-client")
        token.varint(field: 2, 100)
    }
    let client = ScriptedRetryTransport(steps: [
        .http(status: 503), .urlError(.timedOut), .http(status: 200, body: grant.data),
    ])
    #expect(
        try await ClientTokenRequest.send(
            deviceId: "synthetic", transport: client.send,
            retryTiming: .immediate
        ).token == "synthetic-client")
    #expect(client.callCount == 3)

    var challenge = ProtobufWriter()
    challenge.varint(field: 1, 2)
    let challenged = ScriptedRetryTransport(steps: [.http(status: 200, body: challenge.data)])
    await #expect(throws: ClientTokenError.challenged) {
        try await ClientTokenRequest.send(deviceId: "synthetic", transport: challenged.send, retryTiming: .immediate)
    }
    #expect(challenged.callCount == 1)
}

import Foundation
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyGateway

@MainActor
struct ClientTokenLifetimeChecks {
    @Test func cancelledConsumerSettlesBeforeAnUncooperativeFetch() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>(cancellation: .ignored)
        defer { responses.close() }
        let completed = HarnessCounters()
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
        let consumer = await startToken(provider, completed: completed)
        defer { consumer.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        consumer.cancel()
        try await requireEventually(description: "cancelled client-token caller settles before its dependency") {
            completed.count("consumer") == 1
        }
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(responses.waiterCount == 1)
    }

    @Test(arguments: [false, true])
    func preCancelledCallerNeitherFetchesNorReceivesACachedToken(primeCache: Bool) async throws {
        let device = TokenDeviceID()
        let calls = HarnessCounters()
        let provider = ClientTokenProvider(deviceIdStore: device) { _ in
            calls.record("fetch")
            return tokenValue()
        }
        if primeCache { _ = try await provider.token(now: HarnessDates.fixed) }
        let cancelled = Task { try await provider.token(now: HarnessDates.fixed) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(calls.count("fetch") == (primeCache ? 1 : 0))
        #expect(device.calls.count("deviceID") == (primeCache ? 1 : 0))
    }

    @Test func cancellingOneCallerPreservesItsPeerAndTheSharedCache() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>()
        defer { responses.close() }
        let completed = HarnessCounters()
        let device = TokenDeviceID()
        let provider = ClientTokenProvider(deviceIdStore: device) { _ in try await responses.wait() }
        let first = await startToken(provider, completed: completed, name: "first")
        let peer = await startToken(provider, completed: completed, name: "peer")
        defer { first.cancel(); peer.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        first.cancel()
        try await requireEventually { completed.count("first") == 1 }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(completed.count("peer") == 0)
        #expect(responses.waiterCount == 1, "the remaining caller still owns the cooperative fetch")
        responses.finish(tokenValue())
        #expect(try await peer.value == "current")
        #expect(try await provider.token(now: HarnessDates.fixed) == "current")
        #expect(responses.requestCount == 1)
        #expect(device.calls.count("deviceID") == 1)
    }

    @Test func cancellingTheLastCallerCancelsCooperativeWorkAndAllowsRetry() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>()
        defer { responses.close() }
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
        let cancelled = await startToken(provider)
        defer { cancelled.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        cancelled.cancel()
        try await requireEventually { responses.waiterCount == 0 }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let replacement = await startToken(provider)
        defer { replacement.cancel() }
        try await requireEventually { responses.waiterCount == 1 && responses.requestCount == 2 }
        responses.finish(tokenValue())
        #expect(try await replacement.value == "current")
    }

    @Test func sharedFailurePreservesItsTypeAndAllowsRetry() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>()
        defer { responses.close() }
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
        let first = await startToken(provider)
        let second = await startToken(provider)
        defer { first.cancel(); second.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        responses.resolve(.failure(ClientTokenError.challenged))
        await #expect(throws: ClientTokenError.challenged) { try await first.value }
        await #expect(throws: ClientTokenError.challenged) { try await second.value }
        #expect(responses.requestCount == 1)
        responses.finish(tokenValue())
        #expect(try await provider.token(now: HarnessDates.fixed) == "current")
        #expect(responses.requestCount == 2)
    }

    @Test func expiryEqualityRenewsAndARefusalCannotDiscardANewerGrant() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>()
        defer { responses.close() }
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
        responses.finish(tokenValue("original", expiresAfter: 10))
        #expect(try await provider.token(now: HarnessDates.fixed) == "original")
        #expect(try await provider.token(now: HarnessDates.fixed.addingTimeInterval(9)) == "original")
        #expect(responses.requestCount == 1)
        responses.finish(tokenValue())
        #expect(try await provider.token(now: HarnessDates.fixed.addingTimeInterval(10)) == "current")
        await provider.invalidate(rejected: "original")
        #expect(try await provider.token(now: HarnessDates.fixed) == "current")
        #expect(responses.requestCount == 2)
        await provider.invalidate(rejected: "current")
        responses.finish(tokenValue("renewed"))
        #expect(try await provider.token(now: HarnessDates.fixed) == "renewed")
        #expect(responses.requestCount == 3)
    }

    @Test(arguments: [false, true], [false, true])
    func retiredResponsesCannotSettleOrClearReplacementCallers(invalidate: Bool, failOld: Bool) async throws {
        let oldResponses = HarnessResponseGate<GrantedClientToken>(cancellation: .ignored)
        let newResponses = HarnessResponseGate<GrantedClientToken>()
        defer { oldResponses.close(); newResponses.close() }
        let calls = HarnessCounters()
        let completed = HarnessCounters()
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in
            calls.record("fetch")
            switch calls.count("fetch") {
            case 1: return tokenValue("original", expiresAfter: 10)
            case 2:
                defer { completed.record("oldDependency") }
                return try await oldResponses.wait()
            default: return try await newResponses.wait()
            }
        }
        #expect(try await provider.token(now: HarnessDates.fixed) == "original")
        let expired = HarnessDates.fixed.addingTimeInterval(20)
        let old = await startToken(provider, now: expired, completed: completed, name: "old")
        let oldPeer = await startToken(provider, now: expired, completed: completed, name: "oldPeer")
        defer { old.cancel(); oldPeer.cancel() }
        try await requireEventually { oldResponses.waiterCount == 1 }
        if invalidate {
            // Keep the expired token as refusal evidence while its renewal is running.
            await provider.invalidate(rejected: "original")
        } else {
            old.cancel()
            oldPeer.cancel()
        }
        try await requireEventually { completed.count("old") == 1 && completed.count("oldPeer") == 1 }
        await #expect(throws: CancellationError.self) { try await old.value }
        await #expect(throws: CancellationError.self) { try await oldPeer.value }
        #expect(oldResponses.waiterCount == 1, "retirement must settle callers before a dependency responds")

        let replacement = await startToken(provider, now: expired, completed: completed, name: "replacement")
        defer { replacement.cancel() }
        try await requireEventually { newResponses.waiterCount == 1 }
        if failOld {
            oldResponses.resolve(.failure(RetiredTokenFailure(released: completed)))
            // Unlike a counter inside the fetcher, releasing its error proves the worker has
            // discarded the result. No retired caller can retain this error in its task result.
            try await requireEventually { completed.count("oldFailureReleased") == 1 }
        } else {
            oldResponses.finish(tokenValue("retired"))
            try await requireEventually { completed.count("oldDependency") == 1 }
        }
        let peer = await startToken(provider, now: expired, completed: completed, name: "peer")
        defer { peer.cancel() }
        #expect(completed.count("replacement") == 0)
        newResponses.finish(tokenValue())
        try await requireEventually { completed.count("replacement") == 1 && completed.count("peer") == 1 }
        #expect(try await replacement.value == "current")
        #expect(try await peer.value == "current")
        await provider.invalidate(rejected: "original")
        newResponses.finish(tokenValue("unexpected-cache-miss"))
        #expect(try await provider.token(now: expired) == "current")
        #expect(calls.count("fetch") == 3)
    }

    @Test func cancelledCallsReleaseTheirOwnerWhileTheDependencyRemainsParked() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>(cancellation: .ignored)
        defer { responses.close() }
        let completed = HarnessCounters()
        weak var released: ClientTokenProvider?
        do {
            let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
            released = provider
            let caller = await startToken(provider, completed: completed)
            defer { caller.cancel() }
            try await requireEventually { responses.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("consumer") == 1 }
            await #expect(throws: CancellationError.self) { try await caller.value }
        }
        try await requireEventually { released == nil }
        #expect(responses.waiterCount == 1)
    }

    @Test func cancellationSettlesStructuredChildrenBeforeTheDependencyResponds() async throws {
        let responses = HarnessResponseGate<GrantedClientToken>(cancellation: .ignored)
        defer { responses.close() }
        let completed = HarnessCounters()
        let provider = ClientTokenProvider(deviceIdStore: TokenDeviceID()) { _ in try await responses.wait() }
        let parent = Task {
            defer { completed.record("parent") }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try? await provider.token(now: HarnessDates.fixed) }
                }
            }
        }
        defer { parent.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        parent.cancel()
        try await requireEventually { completed.count("parent") == 1 }
        #expect(responses.waiterCount == 1)
        await parent.value
    }
}

private func tokenValue(_ token: String = "current", expiresAfter: TimeInterval = 100) -> GrantedClientToken {
    GrantedClientToken(token: token, expiresAt: HarnessDates.fixed.addingTimeInterval(expiresAfter))
}

// An installation identity is outside the account/playback harness; count its reads without defaults.
private struct TokenDeviceID: DeviceIdStoring {
    let calls = HarnessCounters()
    func deviceId() -> String {
        calls.record("deviceID")
        return "synthetic-device"
    }
}

// A response-lifetime witness: the shared gate can deliver an error but cannot observe its disposal.
private final class RetiredTokenFailure: Error {
    let released: HarnessCounters
    init(released: HarnessCounters) { self.released = released }
    deinit { released.record("oldFailureReleased") }
}

// Inherit the provider actor and register through the first suspension before admitting a peer.
private func startToken(
    _ provider: isolated ClientTokenProvider, now: Date = HarnessDates.fixed,
    completed: HarnessCounters = HarnessCounters(), name: String = "consumer"
) -> Task<String, any Error> {
    Task.immediate {
        defer { completed.record(name) }
        return try await provider.token(now: now)
    }
}

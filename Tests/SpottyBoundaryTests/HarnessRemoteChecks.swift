import Testing
import SpottyDomain
@testable import SpottySessionRuntime

@Suite("Harness remote synchronization")
struct HarnessRemoteTests {
    @Test
    @MainActor
    func cancellationAndCompletionOwnExactlyOnePark() async throws {
        let sendRemote = HarnessRemote(send: .park)
        let cancelledBeforeSend = Task {
            try await sendRemote.send(.pause, from: "source", to: "target")
        }
        cancelledBeforeSend.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledBeforeSend.value }
        #expect(sendRemote.parkedSendCount == 0)
        #expect(sendRemote.sendCount == 1, "attempt counters remain historical")

        let parkedSend = Task {
            try await sendRemote.send(.pause, from: "source", to: "target")
        }
        try await requireEventually { sendRemote.parkedSendCount == 1 }
        #expect(sendRemote.completePark(success: true))
        try await parkedSend.value
        #expect(sendRemote.parkedSendCount == 0)
        #expect(!sendRemote.completePark(success: true), "a completion cannot consume a settled park")

        let failedSend = Task {
            try await sendRemote.send(.pause, from: "source", to: "target")
        }
        try await requireEventually { sendRemote.parkedSendCount == 1 }
        #expect(sendRemote.completePark(success: false))
        await #expect(throws: HarnessFailure.unavailable) { try await failedSend.value }
        #expect(sendRemote.parkedSendCount == 0)
    }

    @Test
    @MainActor
    func metadataCancellationCompletionAndReuseKeepAccountingExact() async throws {
        let remote = HarnessRemote(metadata: .park)
        let uri = "spotify:track:harness-reuse"

        let cancelledBeforeMetadata = Task { try await remote.trackMetadata(for: uri) }
        cancelledBeforeMetadata.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledBeforeMetadata.value }
        #expect(remote.parkedMetadataRequestCount == 0)
        #expect(remote.activeMetadataRequests == 0)

        let cancelledAfterParking = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs == [uri] }
        cancelledAfterParking.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledAfterParking.value }
        #expect(remote.parkedMetadataRequestCount == 0)
        #expect(remote.activeMetadataRequests == 0)

        let success = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        #expect(remote.completeMetadata(for: uri, title: "Success"))

        let replacement = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        let duplicate = Task { try await remote.trackMetadata(for: uri) }
        await #expect(throws: HarnessFailure.unavailable) { try await duplicate.value }
        #expect(remote.activeMetadataRequests == 1, "the built-in gate owns one same-URI park")
        #expect(remote.parkedMetadataURIs == [uri])

        // Cancelling an earlier same-URI registration after reuse must not consume the replacement.
        success.cancel()
        #expect(remote.parkedMetadataURIs == [uri])
        #expect(remote.completeMetadata(for: uri, title: "Replacement"))
        #expect(try await success.value.title == "Success")
        #expect(try await replacement.value.title == "Replacement")
        #expect(remote.activeMetadataRequests == 0)

        let failure = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        #expect(remote.failMetadata(for: uri))
        await #expect(throws: HarnessFailure.unavailable) { try await failure.value }

        let reused = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        #expect(remote.completeMetadata(for: uri, title: "Reused"))
        #expect(try await reused.value.title == "Reused")
        #expect(remote.requestedURIs == [uri, uri, uri, uri, uri, uri, uri])
        #expect(remote.maximumActiveMetadataRequests == 1)
        #expect(remote.activeMetadataRequests == 0)
        #expect(remote.parkedMetadataRequestCount == 0)
    }

    @Test(arguments: Array(0..<32))
    @MainActor
    func completionRacingCancellationNeverLeaks(_ iteration: Int) async throws {
        let remote = HarnessRemote(metadata: .park)
        let uri = "spotify:track:race-\(iteration)"
        let request = Task { try await remote.trackMetadata(for: uri) }
        try await requireEventually { remote.parkedMetadataURIs.contains(uri) }
        if iteration.isMultiple(of: 2) {
            request.cancel()
            _ = remote.completeMetadata(for: uri)
        } else {
            _ = remote.completeMetadata(for: uri)
            request.cancel()
        }
        _ = try? await request.value
        #expect(remote.activeMetadataRequests == 0)
        #expect(remote.parkedMetadataRequestCount == 0)
    }

    @Test(arguments: Array(0..<32))
    @MainActor
    func sendCompletionRacingCancellationNeverLeaks(_ iteration: Int) async throws {
        let remote = HarnessRemote(send: .park)
        let request = Task {
            try await remote.send(.pause, from: "source", to: "target")
        }
        try await requireEventually { remote.parkedSendCount == 1 }
        if iteration.isMultiple(of: 2) {
            request.cancel()
            _ = remote.completePark(success: true)
        } else {
            _ = remote.completePark(success: true)
            request.cancel()
        }
        _ = try? await request.value
        #expect(remote.parkedSendCount == 0)
    }
}

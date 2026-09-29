import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

// Runtime-only queue fixtures avoid importing the desktop harness for service admission checks.
struct GatedQueue: WebQueueClient {
    let responses: HarnessResponseGate<[CatalogTrack]>
    func queue() async throws -> [CatalogTrack] { try await responses.wait() }
}

struct UnexpectedQueueRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        Issue.record("Queue service checks must not send playback commands")
    }

    func trackMetadata(for _: String) async throws -> SpotifyConnectTrackMetadata {
        Issue.record("Queue service fixtures already provide the required labels")
        throw CancellationError()
    }
}

private struct UnexpectedWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        Issue.record("Connect mutation checks must not fetch the Web queue")
        throw CancellationError()
    }
}

func isolatedQueueService(hook: (any QueueServiceHook)? = nil) -> QueueService {
    QueueService(
        webQueue: UnexpectedWebQueue(), metadata: TrackMetadataService(remote: UnexpectedQueueRemote()),
        clock: HarnessClock.sticky(), hook: hook)
}

#if DEBUG
    struct QueueServiceSuspensionHook: QueueServiceHook {
        var reset: HarnessSuspension?
        var accept: HarnessSuspension?
        var replacement: HarnessSuspension?

        func beforeReset() async { await reset?.waitIfArmed() }
        func beforeAcceptConnect() async { await accept?.waitIfArmed() }
        func beforeRecordCommittedReplacement() async { await replacement?.waitIfArmed() }
    }
#endif

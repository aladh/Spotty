@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime

@MainActor
@Suite("Playback store subscriptions")
struct PlaybackStoreSubscriptionTests {
    @Test
    func releasingRuntimeStopsItsProcessSubscriptions() async throws {
        let engine = HarnessEngine(events: .live)
        defer { engine.finishEvents() }
        var player: PlaybackStore? = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
        await player?.restore()
        #expect(engine.activeEventSubscriptionCount == 1)
        let publications = player!.withRuntime { $0.presentations() }
        let progress = HarnessCounters()
        let reader = Task {
            for await _ in publications { progress.record("publication") }
            progress.record("finished")
        }
        defer { reader.cancel() }
        try await requireEventually { progress.count("publication") > 0 }
        weak let runtime = player?.runtime
        player = nil
        try await requireEventually { runtime == nil }
        await expectEventually { engine.activeEventSubscriptionCount == 0 }
        try await requireEventually(description: "disposed runtime finishes retained presentation readers") {
            progress.count("finished") == 1
        }
        await reader.value
    }

}

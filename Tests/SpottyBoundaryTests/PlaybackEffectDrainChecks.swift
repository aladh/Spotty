import Foundation
import Testing
@testable import SpottyCore

@MainActor
private final class DrainPark {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false
    private(set) var didFinish = false

    func park() async {
        isParked = true
        await withCheckedContinuation { continuation = $0 }
        didFinish = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Playback Effect Drain")
struct PlaybackEffectDrainTests {
    @Test
    @MainActor
    func testCooperativeAccountEffectsSettleWithinTheGracePeriod() async {
        let effects = PlaybackEffectRegistry()
        effects.replace(
            .trackMetadata,
            with: Task {
                try? await Task.sleep(for: .seconds(10))
            }
        )

        let report = await effects.cancelAccountScopedAndDrain(timeoutNanoseconds: 20_000_000)

        #expect((report.requested) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.settled) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.timedOut.isEmpty) == true)
        #expect((report.didSettleAll) == true)
    }

    @Test
    @MainActor
    func testNonCancelableAccountEffectIsReportedWithoutHangingTeardown() async {
        let effects = PlaybackEffectRegistry()
        let park = DrainPark()
        let parked = Task { await park.park() }
        effects.replace(.trackMetadata, with: parked)
        #expect((await waitUntil { park.isParked }) == true, "the operation parks before cancellation")

        let report = await effects.cancelAccountScopedAndDrain(timeoutNanoseconds: 20_000_000)

        #expect((report.requested) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.settled.isEmpty) == true)
        #expect((report.timedOut) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.didSettleAll) == false)
        #expect(
            (effects.settlement(of: .trackMetadata) == nil) == true,
            "a timed-out operation no longer has admission in the registry"
        )

        park.release()
        await parked.value
        #expect((park.didFinish) == true, "the fenced operation may finish after the bounded report")
    }

    @Test
    @MainActor
    func testCapturedSettlementDoesNotJoinReplacementLifetime() async {
        let effects = PlaybackEffectRegistry()
        let originalPark = DrainPark()
        let replacementPark = DrainPark()
        effects.replace(.queueSnapshot, with: Task { await originalPark.park() })
        #expect((await waitUntil { originalPark.isParked }) == true)

        let captured = effects.cancelAccountScoped()
        effects.replace(.queueSnapshot, with: Task { await replacementPark.park() })
        #expect((await waitUntil { replacementPark.isParked }) == true)

        let report = await effects.drain(captured, timeoutNanoseconds: 20_000_000)

        #expect((report.requested) == (Set([PlaybackEffectID.queueSnapshot])))
        #expect((report.timedOut) == (Set([PlaybackEffectID.queueSnapshot])))
        #expect((effects.settlement(of: .queueSnapshot) != nil) == true)

        originalPark.release()
        replacementPark.release()
        await effects.settlement(of: .queueSnapshot)?.wait()
        #expect((originalPark.didFinish) == true)
        #expect((replacementPark.didFinish) == true)
    }
}

import Foundation
import Testing
@testable import SpottyCore

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

        let report = await effects.cancelAccountScopedAndDrain(
            timeoutNanoseconds: PlaybackEffectRegistry.accountDrainTimeoutNanoseconds
        )

        #expect((report.requested) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.settled) == (Set([PlaybackEffectID.trackMetadata])))
        #expect((report.timedOut.isEmpty) == true)
        #expect((report.didSettleAll) == true)
    }

    @Test
    @MainActor
    func testNonCancelableAccountEffectIsReportedWithoutHangingTeardown() async {
        let effects = PlaybackEffectRegistry()
        let park = SettlementPark()
        let parked = Task { await park.park() }
        effects.replace(.trackMetadata, with: parked)
        #expect((await waitUntil { park.isParked }) == true, "the operation parks before cancellation")

        let report = await effects.cancelAccountScopedAndDrain(timeoutNanoseconds: 50_000_000)

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
        let originalPark = SettlementPark()
        let replacementPark = SettlementPark()
        effects.replace(.queueSnapshot, with: Task { await originalPark.park() })
        #expect((await waitUntil { originalPark.isParked }) == true)

        let captured = effects.cancelAccountScoped()
        effects.replace(.queueSnapshot, with: Task { await replacementPark.park() })
        #expect((await waitUntil { replacementPark.isParked }) == true)

        // Release the captured task before draining. This proves drain waits for the exact
        // cancelled settlement while the replacement remains registered and parked.
        originalPark.release()
        let report = await effects.drain(
            captured,
            timeoutNanoseconds: PlaybackEffectRegistry.accountDrainTimeoutNanoseconds
        )

        #expect((report.requested) == (Set([PlaybackEffectID.queueSnapshot])))
        #expect((report.settled) == (Set([PlaybackEffectID.queueSnapshot])))
        #expect((report.timedOut.isEmpty) == true)
        #expect((effects.settlement(of: .queueSnapshot) != nil) == true)

        #expect((originalPark.didFinish) == true)
        #expect((replacementPark.didFinish) == false)
        replacementPark.release()
        await effects.settlement(of: .queueSnapshot)?.wait()
        #expect((originalPark.didFinish) == true)
        #expect((replacementPark.didFinish) == true)
    }
}

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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_SWIFT_LIFECYCLE_REPORT"] != nil))
    @MainActor
    func measureNamedDrainFaults() async throws {
        var rows: [[String: Double]] = []
        for _ in 0..<12 {
            let effects = PlaybackEffectRegistry()
            effects.replace(.trackMetadata, with: Task { try? await Task.sleep(for: .seconds(10)) })
            var started = ContinuousClock.now
            let cooperative = await effects.cancelAccountScopedAndDrain()
            #expect(cooperative.didSettleAll)
            let cooperativeElapsed = started.duration(to: .now)
            let park = SettlementPark()
            let parked = Task { await park.park() }
            effects.replace(.trackMetadata, with: parked)
            #expect(await waitUntil { park.isParked })
            started = .now
            let fenced = await effects.cancelAccountScopedAndDrain()
            let fencedElapsed = started.duration(to: .now)
            #expect(fenced.timedOut == Set([PlaybackEffectID.trackMetadata]))
            #expect(effects.settlement(of: .trackMetadata) == nil)
            park.release()
            await parked.value
            #expect(park.didFinish)
            func milliseconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            }
            rows.append([
                "cooperativeMilliseconds": milliseconds(cooperativeElapsed),
                "fencedNoncancelableMilliseconds": milliseconds(fencedElapsed),
            ])
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "deadlineMilliseconds": Double(PlaybackEffectRegistry.accountDrainTimeoutNanoseconds) / 1e6,
                "samples": rows,
            ], options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["SPOTTY_SWIFT_LIFECYCLE_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

}

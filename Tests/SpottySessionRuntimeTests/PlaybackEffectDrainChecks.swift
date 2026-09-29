import Foundation
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@Suite("Playback Effect Drain")
@SessionRuntimeActor
struct PlaybackEffectDrainTests {
    @Test
    func testCooperativeAccountEffectsSettleWithinTheGracePeriod() async throws {
        let effects = PlaybackEffectRegistry()
        let clock = HarnessClock.parked()
        defer { clock.releaseAll(); effects.cancelAccountScoped() }
        effects.run(.trackMetadata) { try? await clock.sleep(seconds: 10) }
        try await requireEventually { clock.waiterCount == 1 }

        let captured = effects.cancelAccountScoped()
        let report = await effects.drain(captured)

        #expect(report.requested == Set([PlaybackEffectID.trackMetadata]))
        #expect(report.settled == Set([PlaybackEffectID.trackMetadata]))
        #expect(report.timedOut.isEmpty)
        #expect(report.didSettleAll)
    }

    @Test
    func testNonCancelableAccountEffectIsReportedWithoutHangingTeardown() async throws {
        let effects = PlaybackEffectRegistry()
        let response = HarnessResponseGate<Void>(cancellation: .ignored)
        let progress = HarnessCounters()
        defer { response.close(); effects.cancelAccountScoped() }
        effects.run(.trackMetadata) {
            try? await response.wait()
            progress.record("finished")
        }
        try await requireEventually { response.waiterCount == 1 }

        let captured = effects.cancelAccountScoped()
        let parked = try #require(captured[.trackMetadata])
        let report = await effects.drain(captured, timeoutNanoseconds: 50_000_000)

        #expect(report.requested == Set([PlaybackEffectID.trackMetadata]))
        #expect(report.settled.isEmpty)
        #expect(report.timedOut == Set([PlaybackEffectID.trackMetadata]))
        #expect(report.didSettleAll == false)
        #expect(effects.settlement(of: .trackMetadata) == nil)
        #expect(response.waiterCount == 1)
        #expect(progress.count("finished") == 0)

        response.finish(())
        await parked.wait()
        #expect(progress.count("finished") == 1)
    }

    @Test
    func testCapturedSettlementDoesNotJoinReplacementLifetime() async throws {
        let effects = PlaybackEffectRegistry()
        let original = HarnessResponseGate<Void>(cancellation: .ignored)
        let replacement = HarnessResponseGate<Void>(cancellation: .ignored)
        let progress = HarnessCounters()
        defer { original.close(); replacement.close(); effects.cancelAccountScoped() }
        effects.run(.queueSnapshot) {
            try? await original.wait()
            progress.record("original")
        }
        try await requireEventually { original.waiterCount == 1 }

        let captured = effects.cancelAccountScoped()
        effects.run(.queueSnapshot) {
            try? await replacement.wait()
            progress.record("replacement")
        }
        try await requireEventually { replacement.waiterCount == 1 }
        let current = try #require(effects.settlement(of: .queueSnapshot))
        original.finish(())
        let report = await effects.drain(captured)

        #expect(report.requested == Set([PlaybackEffectID.queueSnapshot]))
        #expect(report.settled == Set([PlaybackEffectID.queueSnapshot]))
        #expect(report.timedOut.isEmpty)
        #expect(effects.settlement(of: .queueSnapshot) != nil)
        #expect(progress.count("original") == 1)
        #expect(progress.count("replacement") == 0)
        #expect(replacement.waiterCount == 1)

        replacement.finish(())
        await current.wait()
        #expect(progress.count("replacement") == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_SWIFT_LIFECYCLE_REPORT"] != nil))
    func measureNamedDrainFaults() async throws {
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        var rows: [[String: Double]] = []
        for _ in 0..<12 {
            let effects = PlaybackEffectRegistry()
            let clock = HarnessClock.parked()
            let response = HarnessResponseGate<Void>(cancellation: .ignored)
            let progress = HarnessCounters()
            defer { clock.releaseAll(); response.close(); effects.cancelAccountScoped() }
            effects.run(.trackMetadata) { try? await clock.sleep(seconds: 10) }
            try await requireEventually { clock.waiterCount == 1 }
            var started = ContinuousClock.now
            let cooperative = await effects.drain(effects.cancelAccountScoped())
            let cooperativeElapsed = started.duration(to: .now)
            #expect(cooperative.didSettleAll)

            effects.run(.trackMetadata) {
                try? await response.wait()
                progress.record("finished")
            }
            try await requireEventually { response.waiterCount == 1 }
            started = .now
            let captured = effects.cancelAccountScoped()
            let fenced = await effects.drain(captured)
            let fencedElapsed = started.duration(to: .now)
            #expect(fenced.timedOut == Set([PlaybackEffectID.trackMetadata]))
            #expect(effects.settlement(of: .trackMetadata) == nil)
            #expect(response.waiterCount == 1)
            response.finish(())
            await captured[.trackMetadata]?.wait()
            #expect(progress.count("finished") == 1)
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

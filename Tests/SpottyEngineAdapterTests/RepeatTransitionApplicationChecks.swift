import SpottyDomain
import SpottyEngineAdapter
import Testing

@Suite("Repeat transition application")
struct RepeatTransitionApplicationTests {
    @Test(arguments: [RepeatMode.off, .context, .track])
    func successfulCycleAppliesOnlyChangedFlagsInOrder(from: RepeatMode) {
        let plan = RepeatTransitionPlan.planning(from: from.flags, to: from.next.flags)
        var calls: [RepeatFlagMutation] = []
        let result = RepeatTransitionApplication.apply(plan) { mutation in
            calls.append(mutation)
            return .ok
        }
        let expected: [RepeatFlagMutation]
        switch from {
        case .off: expected = [.init(flag: .context, enabled: true)]
        case .context:
            expected = [.init(flag: .context, enabled: false), .init(flag: .track, enabled: true)]
        case .track: expected = [.init(flag: .track, enabled: false)]
        }
        #expect(calls == expected)
        #expect(result == .ok)
    }

    @Test func unchangedFlagsDoNotCallTheEngine() {
        let plan = RepeatTransitionPlan.planning(from: RepeatMode.context.flags, to: RepeatMode.context.flags)
        var calls = 0
        let result = RepeatTransitionApplication.apply(plan) { _ in
            calls += 1
            return .error
        }
        #expect(calls == 0)
        #expect(result == .ok)
    }

    @Test(arguments: [Int32(-1), -2, -3])
    func firstFailureReturnsItsCodeWithoutCompensation(code: Int32) {
        let failure = PlaybackEngineResult(rawValue: code)
        let plan = RepeatTransitionPlan.planning(from: RepeatMode.off.flags, to: RepeatMode.context.flags)
        var calls: [RepeatFlagMutation] = []
        let result = RepeatTransitionApplication.apply(plan) { mutation in
            calls.append(mutation)
            return failure
        }
        #expect(calls == [.init(flag: .context, enabled: true)])
        #expect(result == failure)
    }

    @Test(arguments: [Int32(-1), -2, -3], [false, true])
    func laterFailureAttemptsCompensationAndPreservesItsOriginalCode(code: Int32, compensationFails: Bool) {
        let failure = PlaybackEngineResult(rawValue: code)
        let plan = RepeatTransitionPlan.planning(from: RepeatMode.context.flags, to: RepeatMode.track.flags)
        var calls: [RepeatFlagMutation] = []
        let result = RepeatTransitionApplication.apply(plan) { mutation in
            calls.append(mutation)
            if calls.count == 2 { return failure }
            if calls.count == 3 && compensationFails { return PlaybackEngineResult(rawValue: -99) }
            return .ok
        }
        #expect(
            calls == [
                .init(flag: .context, enabled: false), .init(flag: .track, enabled: true),
                .init(flag: .context, enabled: true),
            ])
        #expect(result == failure, "Compensation cannot replace the original outcome")
    }

    @Test func remoteCompensationCannotReplaceTheOriginalError() async {
        enum Failure: Error { case forward, compensation }
        let plan = RepeatTransitionPlan.planning(from: RepeatMode.context.flags, to: RepeatMode.track.flags)
        var calls: [RepeatFlagMutation] = []
        do {
            try await RepeatTransitionApplication.applyRemote(plan) { mutation in
                calls.append(mutation)
                if calls.count == 2 { throw Failure.forward }
                if calls.count == 3 { throw Failure.compensation }
            }
            Issue.record("The failed forward mutation must throw")
        } catch {
            #expect(error as? Failure == .forward)
        }
        #expect(
            calls == [
                .init(flag: .context, enabled: false), .init(flag: .track, enabled: true),
                .init(flag: .context, enabled: true),
            ])
    }

}

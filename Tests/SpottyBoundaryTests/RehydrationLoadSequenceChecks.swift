import Testing
import SpottyDomain
@testable import SpottyEngineAdapter

@Suite("Rehydration load sequence")
@MainActor
struct RehydrationLoadSequenceTests {
    private let context = ResumeLoadPlan.Target.context(
        uri: "spotify:playlist:ctx",
        trackHint: "spotify:track:one",
        positionMS: 10
    )
    private let track = ResumeLoadPlan.Target.track(uri: "spotify:track:one", positionMS: 10)

    @Test
    func firstQueuedTargetStopsTheSequence() {
        var loaded: [ResumeLoadPlan.Target] = []
        let result = RehydrationLoadSequence.run(targets: [context, track]) {
            loaded.append($0)
            return .ok
        }
        #expect(result == .ok)
        #expect(loaded == [context])
    }

    @Test
    func refusedContextFallsThroughToTheTrack() {
        var loaded: [ResumeLoadPlan.Target] = []
        let result = RehydrationLoadSequence.run(targets: [context, track]) {
            loaded.append($0)
            return $0 == track ? .ok : .error
        }
        #expect(result == .ok)
        #expect(loaded == [context, track])
    }

    @Test(arguments: [Int32(-2), -3])
    func reconnectRequiredStopsBeforeTheNextTarget(code: Int32) {
        let failure = PlaybackEngineResult(rawValue: code)
        var loaded: [ResumeLoadPlan.Target] = []
        let result = RehydrationLoadSequence.run(targets: [context, track]) {
            loaded.append($0)
            return failure
        }
        #expect(result == failure)
        #expect(loaded == [context])
    }

    @Test
    func exhaustedTargetsReportFailure() {
        var loaded: [ResumeLoadPlan.Target] = []
        let result = RehydrationLoadSequence.run(targets: [context, track]) {
            loaded.append($0)
            return .error
        }
        #expect(result == .error)
        #expect(loaded == [context, track])
    }

    @Test
    func missingTargetsDoNotLoad() {
        let result = RehydrationLoadSequence.run(targets: []) { _ in
            Issue.record("A missing rehydration target must not issue a load")
            return .ok
        }
        #expect(result == .error)
    }
}

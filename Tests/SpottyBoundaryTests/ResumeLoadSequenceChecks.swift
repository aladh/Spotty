import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyEngineAdapter

/// `ResumeLoadSequence` policy for both callers. Store-level capture and the reconnect
/// trigger live in the command-failure and workflow suites.
@Suite("Resume Load Sequence")
struct ResumeLoadSequenceTests {
    @Test
    @MainActor
    func testResumeLoadSequence() {
        let context = ResumeLoadPlan.Target.context(
            uri: "spotify:playlist:ctx",
            trackHint: "spotify:track:one",
            positionMS: 10
        )
        let track = ResumeLoadPlan.Target.track(uri: "spotify:track:one", positionMS: 10)
        let reconnect = PlaybackEngineResult(rawValue: -2)

        do {
            var successfulPlayLoaded = false
            #expect(
                (ResumeLoadSequence.completing(play: .ok, targets: [context, track]) { _ in
                    successfulPlayLoaded = true
                    return .error
                }) == (.ok), "successful play does not load")
            #expect(!successfulPlayLoaded, "successful play must not load")

            var reconnectPlayLoaded = false
            #expect(
                (ResumeLoadSequence.completing(play: reconnect, targets: [context, track]) { _ in
                    reconnectPlayLoaded = true
                    return .ok
                }) == (reconnect), "reconnect-required play does not load")
            #expect(!reconnectPlayLoaded, "reconnect-required play must not load")

            var loaded: [ResumeLoadPlan.Target] = []
            let recovered = ResumeLoadSequence.completing(play: .error, targets: [context, track]) {
                loaded.append($0)
                if case .track = $0 { return .ok }
                return .error
            }
            #expect((loaded) == ([context, track]), "timeout tries context then track")
            #expect((recovered) == (.ok), "a later target can recover the timeout")

            var failedLoads = 0
            let exhausted = ResumeLoadSequence.completing(play: .error, targets: [context, track]) { _ in
                failedLoads += 1
                return .error
            }
            #expect((exhausted) == (.error), "exhausted loads keep the play timeout")
            #expect((failedLoads) == (2), "exhausted loads try every target")
        }

        do {
            var loaded: [ResumeLoadPlan.Target] = []
            let queued = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
                loaded.append($0)
                return .ok
            }
            #expect((loaded) == ([context]), "rehydration issues no play and stops at the first queued load")
            #expect((queued) == (.ok), "a queued load is the sequence result")

            loaded = []
            let unqueued = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
                loaded.append($0)
                if case .track = $0 { return .ok }
                return .error
            }
            #expect(
                (loaded) == ([context, track]), "a context load the engine refused to queue falls through to the track")
            #expect((unqueued) == (.ok), "the fallback result is reported")

            loaded = []
            let dead = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
                loaded.append($0)
                return reconnect
            }
            #expect((loaded) == ([context]), "a dead Spirc stops the sequence")
            #expect((dead) == (reconnect), "a dead Spirc is reported as reconnect-required")

            #expect(
                (ResumeLoadSequence.completing(play: nil, targets: []) { _ in .ok }) == (.error),
                "no targets is an ordinary failure")
        }
    }
}

import AVFoundation
import CoreMedia
import Testing
@testable import SpottyEngineAdapter

@Suite("Audio receiver pump")
struct AudioRendererPumpChecks {
    @Test
    func aFrozenPlayheadCannotAccumulateUnboundedAudio() {
        var pump = AudioRendererPump()
        let duration = 1024.0 / 44_100
        var admittedFrames = 0
        for _ in 0..<256 {
            guard pump.canEnqueue(duration: duration, playhead: .zero, maximumAhead: 2) else { break }
            pump.didEnqueue(frames: 1024, sampleRate: 44_100)
            admittedFrames += 1024
        }
        #expect(admittedFrames > 0)
        #expect(admittedFrames <= 88_200)
        #expect(!pump.canEnqueue(duration: duration, playhead: .zero, maximumAhead: 2))
        // Rendering one chunk creates room for exactly one further complete chunk.
        let moved = CMTime(value: 1024, timescale: 44_100)
        #expect(pump.canEnqueue(duration: duration, playhead: moved, maximumAhead: 2))
        pump.didEnqueue(frames: 1024, sampleRate: 44_100)
        #expect(!pump.canEnqueue(duration: duration, playhead: moved, maximumAhead: 2))
    }

    @Test
    func invalidPlayheadsDoNotAdmitUnboundedAudio() {
        let pump = AudioRendererPump()
        #expect(!pump.canEnqueue(duration: 1, playhead: .invalid, maximumAhead: 2))
        #expect(!pump.canEnqueue(duration: 1, playhead: .indefinite, maximumAhead: 2))
    }

    @Test
    func stopCancelsQueuedFeedAndEventsWithoutAdvancingOrFlushingTheTimeline() {
        var pump = AudioRendererPump()
        pump.didEnqueue(frames: 1024, sampleRate: 44_100)
        let queuedFeed = pump.generation
        let queuedEvent = pump.generation
        let acceptedTime = pump.presentationTime
        pump.invalidate()
        #expect(!pump.accepts(queuedFeed))
        #expect(!pump.accepts(queuedEvent))
        #expect(pump.presentationTime == acceptedTime)
    }

    @Test
    func flushAndRecreationFenceOldWorkAndRestartAtZero() {
        var pump = AudioRendererPump()
        pump.didEnqueue(frames: 44_100, sampleRate: 44_100)
        let beforeFlush = pump.generation
        pump.invalidate(resetPresentationTime: true)
        let resumed = pump.generation
        #expect(!pump.accepts(beforeFlush))
        #expect(pump.accepts(resumed))
        #expect(pump.presentationTime == .zero)
        pump.didEnqueue(frames: 1024, sampleRate: 44_100)
        pump.invalidate(resetPresentationTime: true)
        #expect(!pump.accepts(resumed))
        #expect(pump.presentationTime == .zero)
    }

    @Test
    func resumingEnqueueRejectsAnEventAlreadyDeliveredByACancelledObserver() {
        var pump = AudioRendererPump()
        let waitingObserver = pump.generation
        pump.invalidate()  // The next feed cancels the event task and invalidates its delivery.
        #expect(!pump.accepts(waitingObserver))
        let rearmedObserver = pump.generation
        #expect(pump.accepts(rearmedObserver))
        pump.invalidate(resetPresentationTime: true)  // Retirement supersedes the replacement too.
        #expect(!pump.accepts(waitingObserver))
        #expect(!pump.accepts(rearmedObserver))
    }

    @Test
    func onlyAcceptedSamplesWithoutRecoveryAdvancePresentationTime() {
        #expect(AudioRendererPump.action(for: .enqueued) == .advance)
        #expect(AudioRendererPump.action(for: .enqueuedWithSuggestedFlush([])) == .advance)
        #expect(AudioRendererPump.action(for: .enqueuedWithSuggestedFlush([.outputConfigurationChanged])) == .recreate)
        #expect(
            AudioRendererPump.action(for: .enqueuedWithSuggestedFlush([.wasFlushedAutomatically(at: .zero)]))
                == .recreate)
        #expect(AudioRendererPump.action(for: .cancelledDueToFlush) == .recreate)
        #expect(AudioRendererPump.action(for: .cancelledDueToError(SyntheticRendererError())) == .recreate)
    }
}

private struct SyntheticRendererError: Error {}

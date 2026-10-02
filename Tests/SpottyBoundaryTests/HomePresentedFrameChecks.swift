import Testing

struct HomePresentedFrameChecks {
    @Test func usableFrameUsesDisplayTimeAndFinalRasterAfterNativeReadiness() {
        let frames = [
            frame(displayed: 90, received: 300, digest: "ready"),
            frame(displayed: 110, received: 320, digest: "intermediate"),
            frame(displayed: 130, received: 340, digest: "ready"),
            frame(displayed: 140, received: 350, digest: "ready"),
            frame(displayed: 140, received: 360, digest: "ready"),
        ]
        let selected = HomePresentedFrameCollector.firstSteadyFrame(in: frames, started: 100, ready: 120)
        #expect(selected?.displayedMachTime == 130)
        #expect(selected?.receivedMachTime == 340)
    }

    @Test func incompletePresentationCannotEstablishAUsableFrame() {
        #expect(HomePresentedFrameCollector.firstSteadyFrame(in: [], started: 100, ready: 120) == nil)
        let old = [frame(displayed: 90, received: 300, digest: "ready")]
        #expect(HomePresentedFrameCollector.firstSteadyFrame(in: old, started: 100, ready: 120) == nil)
        #expect(HomePresentedFrameCollector.seconds(from: 120, to: 100) == nil)
    }

    private func frame(displayed: UInt64, received: UInt64, digest: String) -> HomePresentedFrameCollector.Frame {
        HomePresentedFrameCollector.Frame(displayedMachTime: displayed, receivedMachTime: received, digest: digest)
    }

    @Test func transientTerminalRasterCannotEstablishSteadiness() {
        let frames = [
            frame(displayed: 130, received: 140, digest: "old"),
            frame(displayed: 150, received: 160, digest: "old"),
            frame(displayed: 170, received: 180, digest: "new"),
        ]
        #expect(HomePresentedFrameCollector.firstSteadyFrame(in: frames, started: 100, ready: 120) == nil)
    }

    @Test func idleEventsCannotInventADisplayedFrameAfterObservedReadiness() {
        let early = HomePresentedFrameCollector.Frame(displayedMachTime: 110, receivedMachTime: 140, digest: "ready")
        let idle = HomePresentedFrameCollector.Frame(
            displayedMachTime: 110, receivedMachTime: 160, digest: "ready", isNewFrame: false)
        #expect(HomePresentedFrameCollector.firstSteadyFrame(in: [early, idle, idle], started: 100, ready: 120) == nil)
        let new = HomePresentedFrameCollector.Frame(displayedMachTime: 130, receivedMachTime: 170, digest: "ready")
        let confirmed = HomePresentedFrameCollector.Frame(
            displayedMachTime: 130, receivedMachTime: 180, digest: "ready", isNewFrame: false)
        #expect(
            HomePresentedFrameCollector.firstSteadyFrame(in: [new, confirmed, confirmed], started: 100, ready: 120)?
                .displayedMachTime == 130)
    }
}

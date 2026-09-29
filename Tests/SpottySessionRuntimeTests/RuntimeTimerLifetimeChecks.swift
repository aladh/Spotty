import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@Suite("Runtime timer lifetimes")
@SessionRuntimeActor
struct RuntimeTimerLifetimeTests {
    enum Timer: CaseIterable { case commandDeadline, queueDeadline, commandError }

    @Test(arguments: Timer.allCases, [false, true])
    func aSuspendedTimerCannotRetainItsRuntime(_ timer: Timer, cooperative: Bool) async throws {
        let clock = HarnessClock(sleep: cooperative ? .parked : .uncooperativelyParked)
        defer { clock.releaseAll() }
        var runtime: PlaybackSessionRuntime? = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(clock: clock))
        weak let owner = runtime
        let timerSettlement: PlaybackEffectSettlement
        do {
            timerSettlement = try await prepareTimer(try #require(runtime), timer: timer)
            try await requireEventually(description: "The runtime timer is suspended") { clock.waiterCount == 1 }
        } catch {
            await runtime?.shutdownForTermination()
            throw error
        }

        runtime = nil
        // Isolated deinitializers can enqueue their cleanup after the last reference disappears.
        await Task { @SessionRuntimeActor in }.value
        let wasReleased = owner == nil
        #expect(wasReleased, "A timer waiting for its deadline must not own the session runtime")

        // Clean up even the broken ownership under test, without waiting for real time.
        if let retained = owner { await retained.shutdownForTermination() }
        if cooperative {
            #expect(await waitUntil { clock.waiterCount == 0 }, "Disposal cancels a cooperative timer")
        } else {
            #expect(clock.waiterCount == 1, "An uncooperative dependency can outlive the released runtime")
        }
        clock.releaseAll()
        await timerSettlement.wait()
        #expect(clock.waiterCount == 0)
    }

    private func prepareTimer(_ runtime: PlaybackSessionRuntime, timer: Timer) async throws -> PlaybackEffectSettlement
    {
        switch timer {
        case .commandError:
            runtime.showTransientCommandError("Synthetic command rejection")
            return try #require(runtime.effects.settlement(of: .commandError))
        case .commandDeadline, .queueDeadline:
            try #require(runtime.send(.session(.ready), source: .account))
            try #require(
                runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                            localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
            if timer == .queueDeadline {
                runtime.addToQueue(uris: ["spotify:track:timer"])
                let execution = try #require(
                    runtime.effects.settlements().first { effect, _ in
                        if case .queueCommand = effect { return true }
                        return false
                    }?.value)
                await execution.wait()
                let intent = try #require(runtime.state.intents.last)
                return try #require(runtime.effects.settlement(of: .commandDeadline(intent.command.id)))
            }
            runtime.submitCommand(.shuffle(true), failureMessage: "Synthetic shuffle rejection")
            let command = try #require(runtime.state.pendingCommands[.options])
            let execution = try #require(runtime.effects.settlement(of: .command(command.id)))
            let deadline = try #require(runtime.effects.settlement(of: .commandDeadline(command.id)))
            await execution.wait()
            return deadline
        }
    }
}

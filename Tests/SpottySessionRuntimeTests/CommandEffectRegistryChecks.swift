import Foundation
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

private final class EffectEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) { lock.withLock { values.append(value) } }
    var recorded: [String] { lock.withLock { values } }
}

@Suite("Command Effect Registry")
@SessionRuntimeActor
struct CommandEffectRegistryTests {
    @Test
    func replacingEffectCancelsOldTaskWithoutLosingReplacement() async throws {
        let effects = PlaybackEffectRegistry()
        let clock = HarnessClock.parked()
        let replacement = HarnessResponseGate<Void>(cancellation: .ignored)
        let events = EffectEvents()
        defer { clock.releaseAll(); replacement.close(); effects.cancel(.trackMetadata) }

        effects.run(.trackMetadata) {
            try? await clock.sleep(seconds: 10)
            events.record(Task.isCancelled ? "cancelled" : "returned")
        }
        try await requireEventually { clock.waiterCount == 1 }
        let original = try #require(effects.settlement(of: .trackMetadata))
        effects.run(.trackMetadata) { try? await replacement.wait() }
        try await requireEventually { events.recorded == ["cancelled"] }
        await original.wait()

        try await requireEventually { replacement.waiterCount == 1 }
        let current = try #require(effects.settlement(of: .trackMetadata))
        replacement.finish(())
        await current.wait()
        #expect(effects.settlement(of: .trackMetadata) == nil)
    }

    @Test
    func accountCancellationPreservesProcessLifetimeEffects() async throws {
        let effects = PlaybackEffectRegistry()
        let commandID = PlaybackEffectID.command(UUID())
        let commandClock = HarnessClock.parked()
        let listenerClock = HarnessClock.parked()
        let events = EffectEvents()
        defer { commandClock.releaseAll(); listenerClock.releaseAll(); effects.cancel(.lifecycle) }

        effects.run(commandID) {
            try? await commandClock.sleep(seconds: 10)
            events.record(Task.isCancelled ? "command-cancelled" : "command-returned")
        }
        effects.run(.lifecycle) {
            try? await listenerClock.sleep(seconds: 10)
            events.record(Task.isCancelled ? "listener-cancelled" : "listener-returned")
        }
        try await requireEventually { commandClock.waiterCount == 1 && listenerClock.waiterCount == 1 }
        let cancelled = effects.cancelAccountScoped()
        #expect(Set(cancelled.keys) == [commandID])
        await cancelled[commandID]?.wait()
        #expect(events.recorded == ["command-cancelled"])
        #expect(listenerClock.waiterCount == 1)
        #expect(effects.settlement(of: .lifecycle) != nil)

        let listener = try #require(effects.cancel(.lifecycle))
        await listener.wait()
        #expect(events.recorded == ["command-cancelled", "listener-cancelled"])
        #expect(effects.settlements().isEmpty)
    }

    @Test
    func normalCompletionRemovesOwnershipWithoutCallingCancellation() async throws {
        let effects = PlaybackEffectRegistry()
        let response = HarnessResponseGate<Void>(cancellation: .ignored)
        let events = EffectEvents()
        defer { response.close(); effects.cancel(.positionRefresh) }
        #expect(effects.settlement(of: .positionRefresh) == nil)
        effects.run(.positionRefresh, onCancel: { events.record("cancelled") }) {
            try? await response.wait()
            events.record("finished")
        }
        try await requireEventually { response.waiterCount == 1 }
        let handle = try #require(effects.settlement(of: .positionRefresh))
        response.finish(())
        await handle.wait()

        #expect(effects.settlement(of: .positionRefresh) == nil)
        #expect(effects.cancel(.positionRefresh) == nil)
        #expect(events.recorded == ["finished"])
    }

    @Test
    func cancelledSettlementKeepsItsTaskAfterANewLifetimeStarts() async throws {
        let effects = PlaybackEffectRegistry()
        let original = HarnessResponseGate<Void>(cancellation: .ignored)
        let replacement = HarnessResponseGate<Void>(cancellation: .ignored)
        let events = EffectEvents()
        defer { original.close(); replacement.close(); effects.cancel(.queueSnapshot) }
        effects.run(.queueSnapshot) {
            try? await original.wait()
            events.record("original")
        }
        try await requireEventually { original.waiterCount == 1 }
        let handle = try #require(effects.cancel(.queueSnapshot))
        #expect(effects.settlement(of: .queueSnapshot) == nil)
        #expect(events.recorded.isEmpty)

        effects.run(.queueSnapshot) {
            try? await replacement.wait()
            events.record("replacement")
        }
        try await requireEventually { replacement.waiterCount == 1 }
        original.finish(())
        await handle.wait()

        #expect(events.recorded == ["original"])
        #expect(replacement.waiterCount == 1)
        let current = try #require(effects.settlement(of: .queueSnapshot))
        replacement.finish(())
        await current.wait()
        #expect(events.recorded == ["original", "replacement"])
        #expect(effects.settlement(of: .queueSnapshot) == nil)
    }

    @Test
    func cancellationHandlerCanRegisterAReplacement() async throws {
        let effects = PlaybackEffectRegistry()
        let original = HarnessResponseGate<Void>(cancellation: .ignored)
        let replacement = HarnessResponseGate<Void>(cancellation: .ignored)
        let events = EffectEvents()
        defer { original.close(); replacement.close(); effects.cancel(.queueSnapshot) }
        effects.run(
            .queueSnapshot,
            onCancel: {
                events.record("original")
                effects.run(.queueSnapshot, onCancel: { events.record("replacement") }) {
                    try? await replacement.wait()
                }
            }
        ) { try? await original.wait() }
        try await requireEventually { original.waiterCount == 1 }
        let handle = try #require(effects.cancel(.queueSnapshot))
        #expect(events.recorded == ["original"])
        try await requireEventually { replacement.waiterCount == 1 }
        original.finish(())
        await handle.wait()
        #expect(effects.settlement(of: .queueSnapshot) != nil)

        let replacementHandle = try #require(effects.cancel(.queueSnapshot))
        replacement.finish(())
        await replacementHandle.wait()
        #expect(events.recorded == ["original", "replacement"])
        #expect(effects.settlements().isEmpty)
    }

    @Test
    func replacementIsInstalledBeforeThePreviousCancellationHandlerRuns() async throws {
        let effects = PlaybackEffectRegistry()
        let original = HarnessResponseGate<Void>(cancellation: .ignored)
        let events = EffectEvents()
        defer { original.close(); effects.cancel(.queueSnapshot) }
        effects.run(
            .queueSnapshot,
            onCancel: {
                events.record("original")
                _ = effects.cancel(.queueSnapshot)
            }
        ) { try? await original.wait() }
        try await requireEventually { original.waiterCount == 1 }
        let handle = try #require(effects.settlement(of: .queueSnapshot))
        effects.run(.queueSnapshot, onCancel: { events.record("replacement") }) {
            events.record(Task.isCancelled ? "replacement-task-cancelled" : "replacement-task-returned")
        }
        try await requireEventually { events.recorded.count == 3 }
        original.finish(())
        await handle.wait()

        #expect(events.recorded == ["original", "replacement", "replacement-task-cancelled"])
        #expect(effects.settlements().isEmpty)
    }
}

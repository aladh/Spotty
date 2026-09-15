import Testing
import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime

private final class EffectEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) { lock.withLock { values.append(value) } }
    var recorded: [String] { lock.withLock { values } }
}

@MainActor
@Suite("Command Effect Registry")
struct CommandEffectRegistryTests {
    @Test
    func replacingEffectCancelsOldTaskWithoutLosingReplacement() async throws {
        let effects = PlaybackEffectRegistry()
        let clock = HarnessClock.parked()
        let replacement = SettlementPark()
        let events = EffectEvents()
        defer { clock.releaseAll(); replacement.release(); effects.cancel(.trackMetadata) }

        effects.run(.trackMetadata) {
            try? await clock.sleep(seconds: 10)
            events.record(Task.isCancelled ? "cancelled" : "returned")
        }
        #expect(await waitUntil { clock.waiterCount == 1 })
        let original = try #require(effects.settlement(of: .trackMetadata))
        effects.run(.trackMetadata) { await replacement.park() }
        let cancelled = await waitUntil { events.recorded == ["cancelled"] }
        clock.releaseAll()
        await original.wait()

        #expect(cancelled)
        #expect(await waitUntil { replacement.isParked })
        #expect(effects.settlement(of: .trackMetadata) != nil)
        replacement.release()
        await effects.settlement(of: .trackMetadata)?.wait()
        #expect(effects.settlement(of: .trackMetadata) == nil)
    }

    @Test
    func accountCancellationPreservesProcessLifetimeEffects() async {
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
        #expect(await waitUntil { commandClock.waiterCount == 1 && listenerClock.waiterCount == 1 })
        let cancelled = effects.cancelAccountScoped()
        #expect(Set(cancelled.keys) == [commandID])
        let commandCancelled = await waitUntil { events.recorded == ["command-cancelled"] }
        commandClock.releaseAll()
        await cancelled[commandID]?.wait()
        #expect(commandCancelled)
        #expect(listenerClock.waiterCount == 1)
        #expect(effects.settlement(of: .lifecycle) != nil)

        let listener = effects.cancel(.lifecycle)
        let listenerCancelled = await waitUntil { events.recorded.last == "listener-cancelled" }
        listenerClock.releaseAll()
        await listener?.wait()
        #expect(listenerCancelled)
        #expect(effects.settlements().isEmpty)
    }

    @Test
    func normalCompletionRemovesOwnershipWithoutCallingCancellation() async throws {
        let effects = PlaybackEffectRegistry()
        let park = SettlementPark()
        let events = EffectEvents()
        defer { park.release(); effects.cancel(.positionRefresh) }
        #expect(effects.settlement(of: .positionRefresh) == nil)
        effects.run(.positionRefresh, onCancel: { events.record("cancelled") }) { await park.park() }
        #expect(await waitUntil { park.isParked })
        let handle = try #require(effects.settlement(of: .positionRefresh))
        park.release()
        await handle.wait()

        #expect(park.didFinish)
        #expect(effects.settlement(of: .positionRefresh) == nil)
        #expect(effects.cancel(.positionRefresh) == nil)
        #expect(events.recorded.isEmpty)
    }

    @Test
    func cancelledSettlementKeepsItsTaskAfterANewLifetimeStarts() async throws {
        let effects = PlaybackEffectRegistry()
        let original = SettlementPark()
        let replacement = SettlementPark()
        defer { original.release(); replacement.release(); effects.cancel(.queueSnapshot) }
        effects.run(.queueSnapshot) { await original.park() }
        #expect(await waitUntil { original.isParked })
        let handle = try #require(effects.cancel(.queueSnapshot))
        #expect(effects.settlement(of: .queueSnapshot) == nil)
        #expect(!original.didFinish)

        effects.run(.queueSnapshot) { await replacement.park() }
        #expect(await waitUntil { replacement.isParked })
        original.release()
        await handle.wait()

        #expect(original.didFinish)
        #expect(!replacement.didFinish)
        #expect(effects.settlement(of: .queueSnapshot) != nil)
        replacement.release()
        await effects.settlement(of: .queueSnapshot)?.wait()
    }

    @Test
    func cancellationHandlerCanRegisterAReplacement() async throws {
        let effects = SessionRuntimeActor.sync { SpottySessionRuntime.PlaybackEffectRegistry() }
        let original = SettlementPark()
        let replacement = SettlementPark()
        let events = EffectEvents()
        defer {
            original.release(); replacement.release()
            SessionRuntimeActor.sync { _ = effects.cancel(.queueSnapshot) }
        }
        SessionRuntimeActor.sync {
            effects.run(
                .queueSnapshot,
                onCancel: {
                    events.record("original")
                    effects.run(.queueSnapshot, onCancel: { events.record("replacement") }) {
                        await replacement.park()
                    }
                }
            ) { await original.park() }
        }
        #expect(await waitUntil { original.isParked })
        let handle = try #require(SessionRuntimeActor.sync { effects.cancel(.queueSnapshot) })
        #expect(events.recorded == ["original"])
        #expect(await waitUntil { replacement.isParked })
        original.release()
        await handle.wait()
        #expect(SessionRuntimeActor.sync { effects.settlement(of: .queueSnapshot) != nil })

        let replacementHandle = SessionRuntimeActor.sync { effects.cancel(.queueSnapshot) }
        replacement.release()
        await replacementHandle?.wait()
        #expect(events.recorded == ["original", "replacement"])
        #expect(SessionRuntimeActor.sync { effects.settlements().isEmpty })
    }

    @Test
    func replacementIsInstalledBeforeThePreviousCancellationHandlerRuns() async throws {
        let effects = SessionRuntimeActor.sync { SpottySessionRuntime.PlaybackEffectRegistry() }
        let original = SettlementPark()
        let events = EffectEvents()
        defer {
            original.release()
            SessionRuntimeActor.sync { _ = effects.cancel(.queueSnapshot) }
        }
        SessionRuntimeActor.sync {
            effects.run(
                .queueSnapshot,
                onCancel: {
                    events.record("original")
                    _ = effects.cancel(.queueSnapshot)
                }
            ) { await original.park() }
        }
        #expect(await waitUntil { original.isParked })
        let handle = try #require(SessionRuntimeActor.sync { effects.settlement(of: .queueSnapshot) })
        SessionRuntimeActor.sync {
            effects.run(.queueSnapshot, onCancel: { events.record("replacement") }) {
                events.record(Task.isCancelled ? "replacement-task-cancelled" : "replacement-task-returned")
            }
        }
        #expect(await waitUntil { events.recorded.count == 3 })
        original.release()
        await handle.wait()

        #expect(events.recorded == ["original", "replacement", "replacement-task-cancelled"])
        #expect(SessionRuntimeActor.sync { effects.settlements().isEmpty })
    }
}

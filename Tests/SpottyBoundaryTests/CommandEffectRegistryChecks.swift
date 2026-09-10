import Testing
import Foundation
@testable import SpottyCore

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Work duration if cancellation fails. `awaitBounded` still fails the check well before 60s.
private let cancellationWorkNanoseconds: UInt64 = 50_000_000
private let cancellationWaitNanoseconds: UInt64 = 200_000_000

private func awaitBounded(_ task: Task<Void, Never>) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: cancellationWaitNanoseconds)
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}

@Suite("Command Effect Registry")
struct CommandEffectRegistryTests {
    @Test
    @MainActor
    func testCommandEffectRegistry() async {
        do {
            let effects = PlaybackEffectRegistry()
            let commandID = UUID()
            let finishedWithoutCancel = CancellationFlag()

            let superseded: Task<Void, Never> = Task {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
                if !Task.isCancelled {
                    finishedWithoutCancel.mark()
                }
            }
            effects.replace(.command(commandID), with: superseded)
            effects.replace(.command(commandID), with: Task<Void, Never> {})
            #expect(
                (await awaitBounded(superseded)) == true, "the superseded task ends without waiting out a long sleep")
            #expect((!finishedWithoutCancel.isSet) == true, "replacing a command token cancels the superseded task")
        }

        do {
            let effects = PlaybackEffectRegistry()
            let commandSurvived = CancellationFlag()
            let lifecycleCancelled = CancellationFlag()

            let command: Task<Void, Never> = Task {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
                if !Task.isCancelled {
                    commandSurvived.mark()
                }
            }
            let lifecycle: Task<Void, Never> = Task {
                await withTaskCancellationHandler {
                    do {
                        try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                    } catch {}
                } onCancel: {
                    lifecycleCancelled.mark()
                }
            }
            effects.replace(.command(UUID()), with: command)
            effects.replace(.lifecycle, with: lifecycle)

            effects.cancelAccountScoped()
            #expect((await awaitBounded(command)) == true, "account-scoped command cancellation is bounded")
            #expect((!commandSurvived.isSet) == true, "account teardown cancels in-flight commands")
            #expect(
                (!lifecycleCancelled.isSet) == true,
                "process-lifetime listeners are not cancelled with account-scoped work"
            )

            effects.cancel(.lifecycle)
            #expect((await awaitBounded(lifecycle)) == true, "explicit lifecycle cancellation is bounded")
            #expect((lifecycleCancelled.isSet) == true, "an explicit lifecycle cancel still stops the listener")
        }

        do {
            let effects = PlaybackEffectRegistry()
            let commandID = UUID()
            let replacementCancelled = CancellationFlag()

            let supersededRegistration = PlaybackEffectRegistration()
            let superseded: Task<Void, Never> = Task {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
                effects.complete(.command(commandID), registration: supersededRegistration)
            }
            effects.replace(.command(commandID), with: superseded, registration: supersededRegistration)

            let replacementRegistration = PlaybackEffectRegistration()
            let replacement: Task<Void, Never> = Task {
                await withTaskCancellationHandler {
                    do {
                        try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                    } catch {}
                } onCancel: {
                    replacementCancelled.mark()
                }
            }
            effects.replace(.command(commandID), with: replacement, registration: replacementRegistration)
            #expect(
                (await awaitBounded(superseded)) == true, "the superseded task ends without waiting out a long sleep")
            effects.cancel(.command(commandID))
            #expect((await awaitBounded(replacement)) == true, "the replacement token is still cancellable")
            #expect((replacementCancelled.isSet) == true, "completing the superseded task did not drop the replacement")
        }

        do {
            let effects = PlaybackEffectRegistry()
            let commandID = UUID()
            let previousCancelled = CancellationFlag()
            effects.replace(
                .command(commandID), with: Task<Void, Never> {},
                onCancel: {
                    previousCancelled.mark()
                })
            effects.replace(.command(commandID), with: Task<Void, Never> {})
            #expect((previousCancelled.isSet) == true, "replacing a token runs the previous onCancel")
        }

        do {
            #expect(
                (PlaybackEffectRegistry().settlement(of: .trackMetadata) == nil) == true,
                "a missing in-flight effect has no settlement handle")

            let cancelled = PlaybackEffectRegistry()
            let cancelGate = SettlementPark()
            cancelled.replace(.trackMetadata, with: Task { await cancelGate.park() })
            #expect((await waitUntil { cancelGate.isParked }) == true, "cancelled work parks before capture")
            let cancelledHandle = cancelled.settlement(of: .trackMetadata)
            #expect((cancelledHandle) != nil, "cancelled work is registered before cancel")
            cancelled.cancel(.trackMetadata)
            #expect((cancelled.settlement(of: .trackMetadata) == nil) == true, "cancel drops the live settlement")
            cancelGate.release()
            await cancelledHandle?.wait()
            #expect(
                (cancelGate.didFinish) == true, "waiting on a captured cancelled task observes unwind after release")

            let completed = PlaybackEffectRegistry()
            let completeGate = SettlementPark()
            let completeRegistration = PlaybackEffectRegistration()
            completed.replace(
                .positionRefresh,
                with: Task {
                    await completeGate.park()
                    completed.complete(.positionRefresh, registration: completeRegistration)
                },
                registration: completeRegistration
            )
            #expect((await waitUntil { completeGate.isParked }) == true, "completed work parks before capture")
            let completedHandle = completed.settlement(of: .positionRefresh)
            #expect((completedHandle) != nil, "completed work is registered before complete")
            completeGate.release()
            await completedHandle?.wait()
            #expect((completed.settlement(of: .positionRefresh) == nil) == true, "complete drops the live settlement")
            #expect(
                (completeGate.didFinish) == true, "waiting on a captured completed task observes unwind after complete")

            let replaced = PlaybackEffectRegistry()
            let originalGate = SettlementPark()
            let replacementGate = SettlementPark()
            replaced.replace(.queueSnapshot, with: Task { await originalGate.park() })
            #expect((await waitUntil { originalGate.isParked }) == true, "original work parks before capture")
            let originalHandle = replaced.settlement(of: .queueSnapshot)
            #expect((originalHandle) != nil, "original work is registered before replace")
            replaced.replace(.queueSnapshot, with: Task { await replacementGate.park() })
            #expect((await waitUntil { replacementGate.isParked }) == true, "replacement work parks after replace")
            #expect((replaced.settlement(of: .queueSnapshot)) != nil, "replacement keeps a live settlement")
            originalGate.release()
            await originalHandle?.wait()
            #expect((originalGate.didFinish) == true, "the captured handle followed the original task")
            #expect((!replacementGate.didFinish) == true, "the captured handle did not wait for the replacement")
            replacementGate.release()
            await replaced.settlement(of: .queueSnapshot)?.wait()
        }
    }
}

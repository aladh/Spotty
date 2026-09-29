import Dispatch
import SpottyEngineAdapter
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport

/// Blocking engine calls run on dispatch workers, never the cooperative Swift executor.
private func enterGate(_ gate: HarnessEngineGate) async -> PlaybackEngineResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: gate.enter()) }
    }
}

@Suite("Harness engine gate", .serialized)
@MainActor
struct HarnessEngineGateTests {
    @Test
    func terminalCloseReleasesAllCurrentAndFutureCallers() async throws {
        let gate = HarnessEngineGate(result: .ok)
        let workers = (0..<3).map { _ in Task { await enterGate(gate) } }
        do {
            try await requireEventually { gate.enteredCount == workers.count }
        } catch {
            gate.close()
            for worker in workers { _ = await worker.value }
            throw error
        }
        gate.close()
        for worker in workers { #expect(await worker.value == .error) }
        gate.close()
        gate.finish(with: .ok)
        gate.release()
        #expect(await enterGate(gate) == .error, "Neither repeated cleanup nor a late reply reopens admission")
        #expect(gate.enteredCount == 4)
    }

    @Test
    func ordinaryRepliesRemainOneShotAndMayArriveEarly() async throws {
        let gate = HarnessEngineGate()
        let completions = RuntimeCallbackRecorder<PlaybackEngineResult>()
        gate.finish(with: .ok)
        #expect(await enterGate(gate) == .ok)
        let second = Task {
            let result = await enterGate(gate)
            completions.append(result)
            return result
        }
        do {
            try await requireEventually { gate.enteredCount == 2 }
            #expect(completions.snapshot.isEmpty, "The early reply was consumed by the first caller")
            gate.finish(with: .error)
            #expect(await second.value == .error)
        } catch {
            gate.close()
            _ = await second.value
            throw error
        }
        gate.close()
    }
}

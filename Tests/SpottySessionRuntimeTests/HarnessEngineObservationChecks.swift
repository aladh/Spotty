import Dispatch
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport

@Suite("Harness engine observation")
struct HarnessEngineObservationChecks {
    @Test
    func executionCountCannotPrecedeRecordedOperations() async {
        let engine = HarnessEngine()
        let incompleteObservations = HarnessCounters()
        let calls = 1_000
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: calls) { _ in
                    _ = engine.execute(.pause)
                    let count = engine.count(.execute)
                    let recorded = engine.operations.count
                    if count > recorded { incompleteObservations.record("incomplete") }
                }
                continuation.resume()
            }
        }
        #expect(incompleteObservations.count("incomplete") == 0)
        #expect(engine.executeCount == calls)
        #expect(engine.operations.count == calls)
    }
}

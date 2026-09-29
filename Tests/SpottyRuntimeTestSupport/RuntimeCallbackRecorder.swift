import Foundation

/// Cross-executor observations are recorded at the callback itself, preserving cancellation and
/// ordering assertions without adding a MainActor hop before the test sees the event.
final class RuntimeCallbackRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) { lock.withLock { values.append(value) } }
    var snapshot: [Value] { lock.withLock { values } }
}

import Dispatch
import Foundation

/// The session's transition executor. Network, database and blocking engine workers must use
/// their own execution resources; this queue only commits bounded in-memory transitions.
private final class SessionTransitionExecutor: SerialExecutor, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.spotty.session-transitions", qos: .userInitiated)
    private let key = DispatchSpecificKey<Bool>()

    init() { queue.setSpecific(key: key, value: true) }

    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func checkIsolated() { dispatchPrecondition(condition: .onQueue(queue)) }
}

/// Shared isolation for the one runtime and its synchronous lifetime owners. Suspended work still
/// validates its account/engine stamp; actor isolation is not a substitute for those checks.
@globalActor
package actor SessionRuntimeActor {
    package static let shared = SessionRuntimeActor()
    private nonisolated let executor = SessionTransitionExecutor()

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Local clients use this entrance for bounded admission and deterministic scenario setup.
    /// A transition may never wait for MainActor, storage, network or a blocking engine call.
    /// Other in-process clients use SessionRuntimeServing's asynchronous command contract instead.
    package nonisolated static func sync<Value: Sendable>(
        _ operation: @SessionRuntimeActor () -> Value
    ) -> Value {
        withoutActuallyEscaping(operation) { isolatedOperation in
            let execute = {
                shared.executor.checkIsolated()
                // Swift has no custom-global-actor equivalent of MainActor.assumeIsolated. The
                // checked executor is the same runtime guarantee. Remove isolation only here,
                // never on a worker or UI executor.
                let checkedOperation = unsafeBitCast(isolatedOperation, to: (() -> Value).self)
                return checkedOperation()
            }
            if shared.executor.isCurrent { return execute() }
            return shared.executor.queue.sync(execute: execute)
        }
    }
}

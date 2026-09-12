//
//  SessionTeardownController.swift
//  Spotty
//
//  The single owner of session-teardown coalescing and its active task.
//

import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation

/// One owner for the teardown state machine: the coalescer, the task running it, and whether a
/// teardown is active at all.
///
/// `PlaybackSessionRuntime` holds the only instance and drives the account-side primitives in order.
/// `AccountStore` deliberately does not own a second copy: two coalescers meant two places could
/// disagree about whether a teardown was in flight and which intent had won.
@SessionRuntimeActor
final class SessionTeardownController {
    private var coalescer = SessionTeardownCoalescer()
    private var activeTask: Task<Void, Never>?

    var isActive: Bool { coalescer.isActive }

    /// The strongest intent requested so far, while a teardown is in flight.
    var intent: SessionTeardownIntent? { coalescer.intent }

    /// Records a requested teardown. `shouldStart` is true only for the caller that must run it;
    /// `cumulative` is the merged result every caller publishes.
    func request(_ requested: SessionTeardownIntent) -> (shouldStart: Bool, cumulative: SessionTeardownIntent) {
        let shouldStart = coalescer.request(requested)
        return (shouldStart, coalescer.intent ?? requested)
    }

    func setActiveTask(_ task: Task<Void, Never>?) {
        activeTask = task
    }

    /// Awaits the teardown already in flight, if there is one.
    func awaitActive() async {
        guard let activeTask else { return }
        await activeTask.value
    }

    /// Releases the gate and reports the intent that was in force. Callers must not suspend
    /// between their final comparison and this call.
    @discardableResult
    func complete() -> SessionTeardownIntent? {
        activeTask = nil
        return coalescer.complete()
    }
}

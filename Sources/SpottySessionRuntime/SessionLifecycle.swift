import SpottyDomain

/// One authority for admission, account retirement, and process termination. AccountStore and
/// PlaybackSessionRuntime read this owner; neither maintains its own shutdown flag. Preparation
/// is synchronous so closing admission, advancing identity, and installing the task cannot race.
@SessionRuntimeActor
final class SessionLifecycle {
    private enum State {
        case accepting
        case endingAccount(SessionTeardownIntent)
        case terminating(SessionTeardownIntent?)
    }

    private var state = State.accepting
    private var accountTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    var acceptsWork: Bool {
        if case .accepting = state { return true }
        return false
    }

    var isTerminating: Bool {
        if case .terminating = state { return true }
        return false
    }

    var intent: SessionTeardownIntent? {
        switch state {
        case .accepting: nil
        case let .endingAccount(intent): intent
        case let .terminating(intent): intent
        }
    }

    /// The first caller prepares the account boundary; overlapping callers strengthen its
    /// intent and receive the same completion. Termination permanently closes this entrance.
    func endAccount(
        _ requested: SessionTeardownIntent,
        prepare: (SessionTeardownIntent) -> Task<Void, Never>
    ) -> (started: Bool, intent: SessionTeardownIntent, task: Task<Void, Never>)? {
        switch state {
        case .accepting:
            state = .endingAccount(requested)
            let task = prepare(requested)
            accountTask = task
            return (true, requested, task)
        case let .endingAccount(current):
            let merged = current.merging(requested)
            state = .endingAccount(merged)
            guard let accountTask else { preconditionFailure("Account retirement preparation must be synchronous") }
            return (false, merged, accountTask)
        case .terminating:
            return nil
        }
    }

    /// Called in the same transition as the final intent comparison. Completing an account
    /// boundary during quit cannot reopen admission.
    @discardableResult
    func completeAccount() -> SessionTeardownIntent? {
        let completed = intent
        switch state {
        case .accepting: break
        case .endingAccount: state = .accepting
        case .terminating: state = .terminating(nil)
        }
        accountTask = nil
        return completed
    }

    /// Every quit caller joins the same task. An account retirement already in progress is
    /// handed to the termination operation, which must await it rather than duplicate cleanup.
    func terminate(prepare: (Task<Void, Never>?) -> Task<Void, Never>) -> Task<Void, Never> {
        if let terminationTask { return terminationTask }
        state = .terminating(intent)
        let task = prepare(accountTask)
        terminationTask = task
        return task
    }
}

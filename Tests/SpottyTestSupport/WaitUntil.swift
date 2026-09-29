import Testing

public enum SynchronizationPrerequisiteError: Error {
    case timedOut
}

/// Test-only cooperative wait for concrete boundary checks.
/// Inherits the calling actor and polls until `condition` is true, cancellation, or the deadline.
/// Initial yields admit already-scheduled work without timer latency. Continued polling uses a
/// one-millisecond backoff instead of consuming a core during slow prerequisites.
/// The deadline is a liveness watchdog, never simulated time or a delay before an assertion.
/// A true predicate is accepted only while cancellation and the deadline remain valid.
public func waitUntil(
    timeout: Duration = .seconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    if Task.isCancelled { return false }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var immediateYields = 16
    while clock.now < deadline {
        if Task.isCancelled { return false }
        let matched = await condition()
        if Task.isCancelled { return false }
        if clock.now >= deadline { return false }
        if matched { return true }
        if immediateYields > 0 {
            immediateYields -= 1
            await Task.yield()
        } else {
            do {
                try await Task.sleep(until: min(deadline, clock.now + .milliseconds(1)), clock: clock)
            } catch {
                return false
            }
        }
    }
    return false
}

/// A synchronization prerequisite must fail at its call site instead of silently timing out.
public func expectEventually(
    timeout: Duration = .seconds(10),
    description: String = "Synchronization prerequisite",
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async {
    if !(await waitUntil(timeout: timeout, condition)) {
        Issue.record("\(description) did not settle before the watchdog (\(timeout))", sourceLocation: sourceLocation)
    }
}

/// A synchronization prerequisite that callers must establish before releasing a gate or joining
/// dependent work. Unlike `expectEventually`, failure stops the current test path so cleanup can
/// cancel owned tasks and close its gates instead of awaiting work that was never admitted.
public func requireEventually(
    timeout: Duration = .seconds(10),
    description: String = "Synchronization prerequisite",
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async throws {
    guard await waitUntil(timeout: timeout, condition) else {
        Issue.record("\(description) did not settle before the watchdog (\(timeout))", sourceLocation: sourceLocation)
        throw SynchronizationPrerequisiteError.timedOut
    }
}

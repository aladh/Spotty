import SpottyDomain

/// Repeat-specific application of `RepeatTransitionPlan` for the local FFI and
/// remote Connect paths. Not a generic transaction or two-phase command type.
///
/// Local FFI is a synchronous `PlaybackEngineResult` (including reconnect
/// codes). Remote Connect is `async throws` mapped later to
/// `PlaybackCommandFailure.remoteRejected`. Those vocabularies and runtimes
/// stay distinct; sharing only the tiny `index > 0` loop would be a generic
/// two-phase runner this type exists to avoid.
public enum RepeatTransitionApplication {
    /// Applies forward mutations in plan order. A first-step failure returns that
    /// result with no compensation. After a later step fails, compensation runs
    /// best-effort (its results are ignored) and the failed step's result is returned.
    public static func apply(
        _ plan: RepeatTransitionPlan,
        send: (RepeatFlagMutation) -> PlaybackEngineResult
    ) -> PlaybackEngineResult {
        for (index, mutation) in plan.mutations.enumerated() {
            let result = send(mutation)
            guard result.isOK else {
                if index > 0 {
                    for item in plan.compensation {
                        _ = send(item)
                    }
                }
                return result
            }
        }
        return .ok
    }

    /// Same skip/order/compensation rules for the throwing Connect client.
    /// Compensation uses `try?` so a compensation failure cannot be reported as success.
    public static func applyRemote(
        _ plan: RepeatTransitionPlan,
        send: (RepeatFlagMutation) async throws -> Void
    ) async throws {
        for (index, mutation) in plan.mutations.enumerated() {
            do {
                try await send(mutation)
            } catch {
                if index > 0 {
                    for item in plan.compensation {
                        try? await send(item)
                    }
                }
                throw error
            }
        }
    }
}

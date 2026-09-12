import SpottyDomain
import SpottyEngineAdapter
@testable import SpottySessionRuntime
@testable import SpottyCore

/// Synthetic measurements inspect runtime settlement directly without adding test controls to
/// the shipping presentation facade. Commands still enter through the ordinary UI actions.
@MainActor
extension PlaybackStore {
    var state: PlaybackState {
        let runtime = runtime
        return SessionRuntimeActor.sync { runtime.state }
    }

    var queueService: QueueService { withRuntime { $0.queueService } }
    var coordinator: PlaybackCoordinator { withRuntime { $0.coordinator } }
    var accountStore: RuntimeBrowsingAccount { RuntimeBrowsingAccount(raw: withRuntime { $0.accountStore }) }
    var effects: RuntimeBrowsingEffects {
        RuntimeBrowsingEffects(
            raw: withRuntime { $0.effects }, didSettle: { [weak self] in self?.withRuntime { _ in } })
    }
}

@MainActor
struct RuntimeBrowsingAccount {
    let raw: AccountStore
    var phase: PlaybackSessionPhase { SessionRuntimeActor.sync { raw.phase } }
}

@MainActor
struct RuntimeBrowsingEffects {
    let raw: PlaybackEffectRegistry
    let didSettle: @MainActor @Sendable () -> Void
    func settlement(of id: PlaybackEffectID) -> RuntimeBrowsingSettlement? {
        SessionRuntimeActor.sync { raw.settlement(of: id) }.map {
            RuntimeBrowsingSettlement(raw: $0, didSettle: didSettle)
        }
    }
}

struct RuntimeBrowsingSettlement: Sendable {
    let raw: PlaybackEffectSettlement
    let didSettle: @MainActor @Sendable () -> Void
    func wait() async {
        await raw.wait()
        await didSettle()
    }
}

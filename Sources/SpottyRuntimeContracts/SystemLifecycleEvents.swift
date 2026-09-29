package nonisolated enum SystemLifecycleEvent: Sendable {
    case willSleep
    case didWake
}

package nonisolated protocol SystemLifecycleEvents: Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent>
}

@preconcurrency import AppKit
import Foundation
import SpottySessionRuntime

/// Adapts AppKit notifications once at the infrastructure edge. Product stores consume a typed
/// AsyncSequence and do not own NotificationCenter tokens.
nonisolated final class MacSystemLifecycleEvents: SystemLifecycleEvents, @unchecked Sendable {
    static let shared = MacSystemLifecycleEvents()

    private init() {}

    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let sleep = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { _ in continuation.yield(.willSleep) }
            let wake = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in continuation.yield(.didWake) }
            let tokens = LifecycleObserverTokens(center: center, tokens: [sleep, wake])
            continuation.onTermination = { _ in tokens.cancel() }
        }
    }
}

nonisolated private final class LifecycleObserverTokens: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]
    private let lock = NSLock()
    private var cancelled = false

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            for token in tokens { center.removeObserver(token) }
        }
    }
}

/// Production dependencies are visible in one composition value rather than constructed inside
/// feature methods. Tests can substitute a complete coherent environment.

import SpottyDiagnostics
import SpottyDomain
//
//  KeymasterTokenStore.swift
//  Spotty
//
//  Where the keymaster grant's tokens live between launches.
//

import Foundation
import SpottyRuntimeContracts
import Dispatch

/// The four outcomes that matter to account restoration. A filesystem denial or service failure is
/// deliberately distinct from a genuine missing item so restore cannot silently replace a stored
/// grant after an access problem.
nonisolated enum KeymasterGrantLoadResult: Equatable, Sendable {
    case found(KeymasterTokens)
    case absent
    case denied
    case failed

    var tokens: KeymasterTokens? {
        guard case let .found(tokens) = self else { return nil }
        return tokens
    }
}

/// Short account-facing state used by the connection workflow. It has no credential payload or
/// storage status text, which keeps the UI and logs independent of storage implementation details.
package nonisolated enum KeymasterGrantState: Equatable, Sendable {
    case available
    case absent
    case denied
    case failed
}

/// Storage for the keymaster tokens.
///
/// A protocol rather than a direct filesystem call so the rotation policy can be
/// tested without real session storage — the rule that matters (the response's refresh token replaces
/// the stored one) is a property of the *sequence* of refreshes, and a test that cannot
/// observe what was written cannot check it.
nonisolated protocol KeymasterTokenStoring: Sendable {
    func loadResult() -> KeymasterGrantLoadResult
    func save(_ tokens: KeymasterTokens) throws
    func clear()
}

/// Privacy-safe persistence diagnostics. Messages name a storage category and a reason;
/// they must never include a token, username, payload, account id, or request data.
enum KeymasterGrantPersistenceDiagnostics {
    static let unreadableGrant = "Stored grant is unreadable source=file"
    static let deniedGrant = "Stored grant access denied source=file"
    static let failedGrant = "Stored grant read failed source=file"
    static let saveFailed = "Stored grant save failed source=file"
}

enum KeymasterStoredGrantCodec {
    static func decode(_ data: Data) -> KeymasterTokens? {
        do {
            return try JSONDecoder().decode(KeymasterTokens.self, from: data)
        } catch {
            SpottyLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.unreadableGrant, privacy: .public)"
            )
            return nil
        }
    }
}

/// A completion receipt is created before the operation is submitted. This lets the session
/// submit work synchronously on its actor, preserving save/clear order even when the actor later
/// suspends while awaiting the result.
final class KeymasterPersistenceReceipt<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedValue: Value?
    private var isResolved = false
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func resolve(_ value: Value) {
        let continuations: [CheckedContinuation<Value, Never>]
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        resolvedValue = value
        continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: value)
        }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved, let resolvedValue {
                lock.unlock()
                continuation.resume(returning: resolvedValue)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Owns the blocking persistence calls away from `KeymasterSession`'s token actor. The serial
/// queue is an explicitly owned bounded lane; synchronous submit methods establish operation
/// order before the token actor suspends waiting for each receipt.
final class KeymasterPersistenceWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let store: any KeymasterTokenStoring

    init(store: any KeymasterTokenStoring) {
        queue = DispatchQueue(
            label: "dev.spotty.keymaster.persistence",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        self.store = store
    }

    /// Submission is synchronous so the caller's actor establishes the queue order before its
    /// next suspension. Waiting is separate and happens through the returned receipt.
    func submitLoad() -> KeymasterPersistenceReceipt<KeymasterGrantLoadResult> {
        let receipt = KeymasterPersistenceReceipt<KeymasterGrantLoadResult>()
        queue.async { [store] in
            receipt.resolve(store.loadResult())
        }
        return receipt
    }

    func submitSave(_ tokens: KeymasterTokens) -> KeymasterPersistenceReceipt<Result<Void, any Error>> {
        let receipt = KeymasterPersistenceReceipt<Result<Void, any Error>>()
        queue.async { [store] in
            do {
                try store.save(tokens)
                receipt.resolve(.success(()))
            } catch {
                receipt.resolve(.failure(error))
            }
        }
        return receipt
    }

    func submitClear() -> KeymasterPersistenceReceipt<Void> {
        let receipt = KeymasterPersistenceReceipt<Void>()
        queue.async { [store] in
            store.clear()
            receipt.resolve(())
        }
        return receipt
    }
}

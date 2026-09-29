import Foundation
@testable import SpottyGateway

/// In-memory persistence for boundary checks that use the real credential owner.
final class HarnessGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    enum Failure: Error, Equatable { case saveRejected }

    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var saveFailuresRemaining: Int
    private var saveStorage = 0

    init(initial: KeymasterTokens? = nil, saveFailures: Int = 0) {
        value = initial
        saveFailuresRemaining = saveFailures
    }

    var stored: KeymasterTokens? { lock.withLock { value } }
    var saveCount: Int { lock.withLock { saveStorage } }

    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { value.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        try lock.withLock {
            saveStorage += 1
            if saveFailuresRemaining > 0 {
                saveFailuresRemaining -= 1
                throw Failure.saveRejected
            }
            value = tokens
        }
    }

    func failNextSave() {
        lock.withLock { saveFailuresRemaining += 1 }
    }

    func clear() { lock.withLock { value = nil } }
}

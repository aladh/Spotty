import Foundation
import Security
import SpottyRuntimeContracts

/// Not a keychain item: it is an identifier, not a secret, and losing it costs nothing beyond
/// looking like a fresh install. A process-wide lock makes creation atomic across store instances;
/// the unchecked conformance is limited to Foundation's thread-safe UserDefaults boundary.
nonisolated struct UserDefaultsDeviceIdStore: DeviceIdStoring, @unchecked Sendable {
    static let storageKey = "keymasterDeviceId"
    private static let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func deviceId() -> String {
        Self.lock.withLock {
            if let existing = defaults.string(forKey: Self.storageKey), Self.isValid(existing) {
                return existing
            }

            let generated = Self.generate()
            defaults.set(generated, forKey: Self.storageKey)
            return generated
        }
    }

    private static func isValid(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    /// 40 hex characters, matching what the desktop client sends.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(40))
                .lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import Security
import SpottyRuntimeContracts

/// Not a keychain item: it is an identifier, not a secret, and losing it costs nothing beyond
/// looking like a fresh install.
nonisolated struct UserDefaultsDeviceIdStore: DeviceIdStoring {
    static let storageKey = "keymasterDeviceId"

    init() {}

    func deviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.storageKey),
            existing.count == 40,
            existing.allSatisfy(\.isHexDigit)
        {
            return existing
        }

        let generated = Self.generate()
        UserDefaults.standard.set(generated, forKey: Self.storageKey)
        return generated
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

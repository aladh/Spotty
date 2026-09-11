import Foundation
import Security

/// Where the device id lives. Stable across launches on purpose: it identifies this
/// installation to Spotify, and a new one on every launch looks like a new device each time.
public nonisolated protocol DeviceIdStoring: Sendable {
    func deviceId() -> String
}

/// Not a keychain item: it is an identifier, not a secret, and losing it costs nothing beyond
/// looking like a fresh install.
public nonisolated struct UserDefaultsDeviceIdStore: DeviceIdStoring {
    public static let storageKey = "keymasterDeviceId"

    public init() {}

    public func deviceId() -> String {
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
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(40))
                .lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Non-secret Connect identity, independent of account credentials, computer name, and client tokens.
/// Inject a defaults suite in tests. The process-wide lock also serializes fresh-store creation.
public nonisolated struct ConnectInstallationIDStore: DeviceIdStoring, @unchecked Sendable {
    public static let storageKey = "connectInstallationID"
    private static let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func deviceId() -> String {
        Self.lock.withLock {
            if let existing = defaults.string(forKey: Self.storageKey), Self.isValid(existing) {
                return existing.lowercased()
            }
            let generated = UserDefaultsDeviceIdStore.generate()
            defaults.set(generated, forKey: Self.storageKey)
            return generated
        }
    }

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    public static let liveDeviceID: String = {
        #if DEBUG
            // Packaged development builds carry a per-checkout ID. Unbundled tests/tools get
            // an ephemeral ID and never read or mutate the installed app's defaults.
            if let injected = Bundle.main.object(forInfoDictionaryKey: "SpottyConnectDeviceID") as? String,
                isValid(injected)
            {
                return injected.lowercased()
            }
            return UserDefaultsDeviceIdStore.generate()
        #else
            return ConnectInstallationIDStore(defaults: .standard).deviceId()
        #endif
    }()
}

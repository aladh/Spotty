import Foundation
import SpottyRuntimeContracts
import Security

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
            let generated = Self.generate()
            defaults.set(generated, forKey: Self.storageKey)
            return generated
        }
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(40))
                .lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
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
            return Self.generate()
        #else
            return ConnectInstallationIDStore(defaults: .standard).deviceId()
        #endif
    }()
}

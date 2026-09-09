import Foundation

/// Non-secret Connect identity, independent of account credentials, computer name, and client tokens.
/// Inject a defaults suite in tests. The process-wide lock also serializes fresh-store creation.
nonisolated struct ConnectInstallationIDStore: DeviceIdStoring, @unchecked Sendable {
    static let storageKey = "connectInstallationID"
    private static let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func deviceId() -> String {
        Self.lock.withLock {
            if let existing = defaults.string(forKey: Self.storageKey), Self.isValid(existing) {
                return existing.lowercased()
            }
            let generated = UserDefaultsDeviceIdStore.generate()
            defaults.set(generated, forKey: Self.storageKey)
            return generated
        }
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    static let liveDeviceID: String = {
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

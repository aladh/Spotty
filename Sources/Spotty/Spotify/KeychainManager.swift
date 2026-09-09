//
//  KeychainManager.swift
//  Spotty
//
//  Manages secure storage of Spotify OAuth tokens in the macOS/iOS Keychain
//

import Foundation
import Security
import SpottyKeychainSupport

/// Manages secure storage of authentication tokens in the Keychain
nonisolated enum KeychainManager {
    // MARK: - Keymaster grant

    private static let keymasterService = "dev.spotty.app.keymaster"
    private static let keymasterTokensKey = "keymaster_tokens"
    private static let retiredKeymasterService = "dev.aural.app.keymaster"

    /// Stored as one item rather than a key per field, which is how the Web API tokens were
    /// kept. The four values are only meaningful together — an access token paired with another
    /// grant's expiry, or with a refresh token that has since rotated, is worse than nothing —
    /// and a single write cannot leave them half-updated.
    static func saveKeymasterTokens(_ tokens: KeymasterTokens) throws {
        clearRetiredKeymasterTokens()
        try save(
            key: keymasterTokensKey,
            data: JSONEncoder().encode(tokens),
            service: keymasterService,
        )
    }

    /// Reads the current grant without collapsing an unavailable keychain into an absent grant.
    ///
    /// Only `errSecItemNotFound` means that no grant exists. Access failures deliberately leave
    /// the retired item alone: a denied read must not perform an unrelated cleanup mutation while
    /// the secure store is unavailable.
    static func loadKeymasterTokens() -> KeymasterGrantLoadResult {
        switch load(key: keymasterTokensKey, service: keymasterService) {
        case let .found(data):
            guard let tokens = KeymasterStoredGrantCodec.decode(data) else { return .failed }
            clearRetiredKeymasterTokens()
            return .found(tokens)
        case .absent:
            clearRetiredKeymasterTokens()
            return .absent
        case .denied:
            return .denied
        case .failed:
            return .failed
        }
    }

    static func clearKeymasterTokens() {
        clearRetiredKeymasterTokens()
        delete(key: keymasterTokensKey, service: keymasterService)
    }

    private static func clearRetiredKeymasterTokens() {
        delete(key: keymasterTokensKey, service: retiredKeymasterService)
    }

    // MARK: - Private Keychain Operations

    private static func save(key: String, data: Data, service: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var addQuery = makeQuery(key: key, service: service)
        addQuery.merge(attributes) { _, new in new }

        let addStatus = SpottyKeychainAdd(addQuery as CFDictionary)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError.saveFailed(addStatus)
        }

        // Update in place so Keychain keeps existing trusted app ACL entries.
        let updateQuery = makeQuery(key: key, service: service)
        let updateStatus = SpottyKeychainUpdate(
            updateQuery as CFDictionary,
            attributes as CFDictionary,
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    private static func load(key: String, service: String) -> RawKeychainReadResult {
        var query = makeQuery(key: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: Unmanaged<CFTypeRef>?
        let status = SpottyKeychainCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result?.takeRetainedValue() as? Data else {
                SpottyLog.authentication.error(
                    "Keychain read failed category=failed status=unexpected-data"
                )
                return .failed
            }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed,
            errSecAuthFailed,
            errSecUserCanceled,
            errSecNotAvailable,
            errSecMissingEntitlement:
            SpottyLog.authentication.error(
                "Keychain read failed category=denied status=\(status, privacy: .public)"
            )
            return .denied
        default:
            SpottyLog.authentication.error(
                "Keychain read failed category=failed status=\(status, privacy: .public)"
            )
            return .failed
        }
    }

    private static func delete(key: String, service: String) {
        let query = makeQuery(key: key, service: service)
        SpottyKeychainDelete(query as CFDictionary)
    }

    /// File-based generic-password items, authorized by this process's code signature.
    ///
    /// `kSecUseDataProtectionKeychain` is omitted. That flag selects the data-protection
    /// keychain, whose entitlement-based access requires a provisioning profile. Spotty
    /// retains the file-based item so existing credentials remain discoverable.
    ///
    /// Self-signed development signatures are build-only: macOS records their changing
    /// CDHash in the item's partition ACL, so they cannot provide silent access across
    /// rebuilds. `build_and_run.sh` therefore requires an Apple-issued team signature;
    /// its stable Team ID is the reusable development access boundary.
    private static func makeQuery(key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

private nonisolated enum RawKeychainReadResult {
    case found(Data)
    case absent
    case denied
    case failed
}

/// Errors that can occur during keychain operations
nonisolated enum KeychainError: Error, LocalizedError, Equatable, Sendable {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            "Failed to save to keychain: \(status)"
        }
    }
}

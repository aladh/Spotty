import Foundation
import SystemConfiguration

/// Swift-owned policy for the name advertised to Spotify Connect.
public nonisolated enum ConnectDeviceIdentity {
    public static let fallbackComputerName = "Mac"

    public static func advertisedName(computerName: String?) -> String {
        let trimmed = computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? fallbackComputerName : trimmed
        return "\(resolved) (Spotty)"
    }

    public static var current: String {
        advertisedName(computerName: systemComputerName())
    }

    private static func systemComputerName() -> String? {
        // Use the user-facing Computer Name from System Settings, not a DNS hostname.
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}

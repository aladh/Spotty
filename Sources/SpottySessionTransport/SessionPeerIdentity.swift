import Foundation
import Security

/// Both peers require the exact bundled executable identity and the same Apple-issued team.
/// No debug flag weakens this policy for a named/live service.
public struct SessionPeerIdentity: Sendable {
    let requirement: String
    public let bundleIdentifier: String

    public init(teamID: String, bundleIdentifier: String) throws {
        let teamCharacters = CharacterSet.uppercaseLetters.union(.decimalDigits)
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard teamID.count == 10, teamID.unicodeScalars.allSatisfy(teamCharacters.contains),
            !bundleIdentifier.isEmpty,
            bundleIdentifier.unicodeScalars.allSatisfy(identifierCharacters.contains)
        else { throw SessionTransportError.invalidPeerIdentity }
        let requirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleIdentifier)\""
        try Self.validate(requirement)
        self.requirement = requirement
        self.bundleIdentifier = bundleIdentifier
    }

    static func currentProcessRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
            SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { throw SessionTransportError.invalidPeerIdentity }
        let result = text as String
        try validate(result)
        return result
    }

    private static func validate(_ text: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw SessionTransportError.invalidPeerIdentity
        }
    }
}

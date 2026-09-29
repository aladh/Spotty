import Foundation

/// Parses the registered callback target without making an authorization decision.
///
/// The listener is registered for `http://127.0.0.1:<port>/login`. Only that origin-form
/// target is accepted, so `GET /` or a lookalike path cannot consume the one-shot callback.
extension LoopbackCallbackServer {
    nonisolated static func parseRequestLine(_ request: String) -> URLComponents? {
        guard let line = firstRequestLine(request) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        guard isHTTPVersion(parts[2]) else { return nil }
        return parseOriginFormCallbackTarget(String(parts[1]))
    }

    // Preserve the listener's accepted numeric versions, including HTTP/2.
    private nonisolated static func isHTTPVersion(_ token: Substring) -> Bool {
        guard token.hasPrefix("HTTP/") else { return false }
        let version = token.dropFirst(5)
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
        }
    }

    /// First HTTP request-line, without a CR, LF, or CRLF terminator.
    ///
    /// Swift treats CRLF as a single `Character`, so this walks Unicode scalars. Empty or
    /// terminator-only input is malformed.
    private nonisolated static func firstRequestLine(_ request: String) -> String? {
        let scalars = request.unicodeScalars
        var end = scalars.startIndex
        while end != scalars.endIndex {
            let scalar = scalars[end]
            if scalar == "\r" || scalar == "\n" { break }
            end = scalars.index(after: end)
        }
        let line = String(scalars[scalars.startIndex..<end])
        return line.isEmpty ? nil : line
    }

    /// Origin-form request-target that names exactly `/login` after percent-decoding.
    private nonisolated static func parseOriginFormCallbackTarget(_ target: String) -> URLComponents? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("://") else {
            return nil
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return nil
        }
        guard components.scheme == "http",
            components.host == "127.0.0.1",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil,
            components.path == KeymasterAuth.redirectPath
        else {
            return nil
        }
        return components
    }
}

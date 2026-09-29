public enum SpotifyURI {
    public static func id(from uri: String) -> String? {
        components(in: uri)?.last.map(String.init)
    }

    public static func id(from uri: String, kind: String) -> String? {
        guard let parts = components(in: uri), parts.count == 3, parts[1] == kind else {
            return nil
        }
        return String(parts[2])
    }

    private static func components(in uri: String) -> [Substring]? {
        // Empty fields are malformed identity evidence, not separators to normalize away.
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "spotify", parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts
    }
}

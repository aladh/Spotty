import Foundation

/// Removes Spotify authentication cookies from the jar used by `URLSession.shared`.
///
/// Sign Out must not call `HTTPCookieStorage.shared.removeCookies(since:)` or otherwise
/// empty the process-wide jar: other clients of the shared storage can coexist in-process
/// during checks, and unrelated cookies are not Spotty's grant.
enum AuthCookieCleanup {
    static func removeSpotifyAuthenticationCookies(
        from storage: HTTPCookieStorage = .shared
    ) {
        for cookie in storage.cookies ?? [] where shouldRemove(cookie) {
            storage.deleteCookie(cookie)
        }
    }

    private static func shouldRemove(_ cookie: HTTPCookie) -> Bool {
        // Cookie paths are origin-form. Anything else is not ours to remove.
        guard cookie.path.hasPrefix("/") else { return false }
        var host = cookie.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        return host == "spotify.com" || host.hasSuffix(".spotify.com")
    }
}

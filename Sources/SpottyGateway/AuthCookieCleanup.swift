import SpottyDomain
import Foundation
import SpottyRuntimeContracts

/// Removes Spotify authentication cookies from the jar used by `URLSession.shared`.
///
/// Sign Out must not call `HTTPCookieStorage.shared.removeCookies(since:)` or otherwise
/// empty the process-wide jar: other clients of the shared storage can coexist in-process
/// during checks, and unrelated cookies are not Spotty's grant.
enum AuthCookieCleanup {
    static func cookiesToDelete(in cookies: [HTTPCookie]) -> [HTTPCookie] {
        let matched = cookies.filter {
            SpotifyAuthenticationCookies.shouldRemove(domain: $0.domain, path: $0.path)
        }
        return matched.sorted {
            ($0.domain.lowercased(), $0.path, $0.name) < ($1.domain.lowercased(), $1.path, $1.name)
        }
    }

    static func removeSpotifyAuthenticationCookies(
        from storage: HTTPCookieStorage = .shared
    ) {
        for cookie in cookiesToDelete(in: storage.cookies ?? []) {
            storage.deleteCookie(cookie)
        }
    }
}

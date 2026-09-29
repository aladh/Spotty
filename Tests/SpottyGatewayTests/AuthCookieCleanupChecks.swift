import Foundation
import Testing
@testable import SpottyGateway

@Suite("Auth Cookie Cleanup")
struct AuthCookieCleanupTests {
    @Test
    func cleanupPreservesOtherDomainsAndOnlyMutatesTheSuppliedJar() throws {
        let storage = try isolatedCookieStorage()
        let peer = try isolatedCookieStorage()
        try #require(storage !== peer)
        let removed = try [
            cookie(domain: "spotify.com"),
            cookie(domain: "spotify.com", path: "/api"),
            cookie(domain: "accounts.spotify.com"),
            cookie(domain: ".spotify.com"),
            cookie(domain: "SPOTIFY.COM", name: "upper"),
            cookie(domain: "..spotify.com", name: "dots"),
            cookie(domain: " spotify.com ", name: "spaces"),
        ]
        let preserved = try [
            cookie(domain: "notspotify.com"),
            cookie(domain: "spotify.com.evil.example"),
            cookie(domain: "example.com"),
            cookie(domain: "spotify.com", path: "relative"),
        ]
        try #require(preserved.last?.path == "relative")
        let peerCookie = try cookie(domain: "spotify.com", name: "peer")
        try seed(removed + preserved, into: storage)
        try seed([peerCookie], into: peer)

        AuthCookieCleanup.removeSpotifyAuthenticationCookies(from: storage)

        #expect(snapshot(storage) == Set(preserved.map(CookieSnapshot.init)))
        #expect(snapshot(peer) == [CookieSnapshot(peerCookie)])
        AuthCookieCleanup.removeSpotifyAuthenticationCookies(from: storage)
        #expect(snapshot(storage) == Set(preserved.map(CookieSnapshot.init)))
        #expect(snapshot(peer) == [CookieSnapshot(peerCookie)])
    }

    @Test
    func anEmptyJarCanBeClearedRepeatedly() throws {
        let storage = try isolatedCookieStorage()
        AuthCookieCleanup.removeSpotifyAuthenticationCookies(from: storage)
        AuthCookieCleanup.removeSpotifyAuthenticationCookies(from: storage)
        #expect(snapshot(storage).isEmpty)
    }

    @Test
    func clearingTheGrantRemovesItsCookiesAndCanBeRepeated() async throws {
        let storage = try isolatedCookieStorage()
        let spotify = try cookie(domain: "accounts.spotify.com")
        let unrelated = try cookie(domain: "example.com")
        let store = GatewayGrantStore()
        let session = KeymasterSession(
            store: store,
            refresher: { _ in throw KeymasterAuthError.grantRevoked },
            cookieCleanup: { AuthCookieCleanup.removeSpotifyAuthenticationCookies(from: storage) })
        let tokens = gatewayTokens()
        try await session.adopt(tokens)
        try #require(store.stored == tokens)

        for _ in 0..<2 {
            try seed([spotify, unrelated], into: storage)
            #expect(await session.clear())
            #expect(store.stored == nil)
            #expect(snapshot(storage) == [CookieSnapshot(unrelated)])
        }
    }
}

private func isolatedCookieStorage() throws -> HTTPCookieStorage {
    let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
    // Require fresh, independent ephemeral jars before inserting or deleting anything.
    let peer = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
    try #require(storage !== peer)
    try #require((storage.cookies ?? []).isEmpty)
    storage.cookieAcceptPolicy = .always
    return storage
}

private func cookie(domain: String, path: String = "/", name: String = "same-name") throws -> HTTPCookie {
    try #require(
        HTTPCookie(properties: [
            .name: name, .value: "synthetic-cookie", .domain: domain, .path: path,
        ]))
}

private func seed(_ cookies: [HTTPCookie], into storage: HTTPCookieStorage) throws {
    for cookie in cookies { storage.setCookie(cookie) }
    // Foundation may normalize or reject properties; prove the complete fixture was admitted.
    try #require(snapshot(storage) == Set(cookies.map(CookieSnapshot.init)))
}

private func snapshot(_ storage: HTTPCookieStorage) -> Set<CookieSnapshot> {
    Set((storage.cookies ?? []).map(CookieSnapshot.init))
}

private struct CookieSnapshot: Hashable {
    let name: String
    let domain: String
    let path: String
    let value: String

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        domain = cookie.domain
        path = cookie.path
        value = cookie.value
    }
}

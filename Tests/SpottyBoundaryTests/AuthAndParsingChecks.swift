import Testing
//
//  AuthAndParsingChecks.swift
//  Spotty
//

import Foundation
import Security
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Auth Flow")
@MainActor
struct AuthFlowTests {
    @Test
    func parsesTokenResponseAndRetainsOmittedRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try KeymasterAuth.parseTokenResponse(
            Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600,"username":"listener"}"#.utf8),
            fallbackRefreshToken: nil, now: now
        )
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.username == "listener")
        #expect(tokens.expiresAt == now.addingTimeInterval(3_600))

        let rotated = try KeymasterAuth.parseTokenResponse(
            Data(#"{"access_token":"at2","expires_in":1800}"#.utf8),
            fallbackRefreshToken: "previous-rt", now: now
        )
        #expect(rotated.refreshToken == "previous-rt")
    }

    @Test(arguments: [
        "{}",
        #"{"refresh_token":"rt"}"#,
        #"{"access_token":123,"expires_in":3600}"#,
        #"{"access_token":"at","refresh_token":"rt","expires_in":"3600"}"#,
        #"{"access_token":"at","refresh_token":"rt"}"#,
    ])
    func rejectsMalformedTokenResponse(_ body: String) {
        #expect(throws: KeymasterAuthError.malformedTokenResponse) {
            try KeymasterAuth.parseTokenResponse(
                Data(body.utf8), fallbackRefreshToken: nil, now: HarnessDates.fixed
            )
        }
    }

    @Test
    func onlyInvalidGrantRevokesAndFailureDescriptionsOmitResponseText() {
        #expect(
            KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
                == .grantRevoked)
        #expect(
            KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_request"}"#.utf8))
                == .tokenExchangeFailed(400))
        #expect(KeymasterAuth.tokenFailure(status: 500, body: Data()) == .tokenExchangeFailed(500))
        let refused = KeymasterAuth.tokenFailure(
            status: 400,
            body: Data(
                #"{"error":"invalid_request","error_description":"SPOTTY_PRIVACY_SENTINEL_token-body_7f3c"}"#.utf8)
        )
        #expect(refused == .tokenExchangeFailed(400))
        #expect(refused.errorDescription == "Token exchange failed (HTTP 400)")
    }

    @Test
    func callbackExtractsCodeOnlyAfterMatchingState() throws {
        #expect(try Self.code(from: "code=abc&state=expected") == "abc")
    }

    @Test(arguments: [
        ("error=access_denied&state=wrong", KeymasterAuthError.stateMismatch),
        ("error=access_denied&state=expected", KeymasterAuthError.authorizationDenied),
        ("state=expected", KeymasterAuthError.noAuthorizationCode),
        ("error=SPOTTY_PRIVACY_SENTINEL_oauth-error_4c1a&state=expected", KeymasterAuthError.authorizationDenied),
    ])
    func callbackRejectsInvalidResponses(_ query: String, error: KeymasterAuthError) {
        #expect(throws: error) { try Self.code(from: query) }
        #expect(KeymasterAuthError.authorizationDenied.errorDescription == "Spotify declined the authorization")
    }

    @Test
    func authorizationURLUsesListeningPortAndPKCE() throws {
        let url = try #require(KeymasterAuth.authorizationURL(port: 49_152, challenge: "challenge", state: "state"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(items.first(where: { $0.name == "redirect_uri" })?.value == "http://127.0.0.1:49152/login")
        #expect(items.first(where: { $0.name == "scope" })?.value?.contains("streaming") == true)
        #expect(items.first(where: { $0.name == "state" })?.value == "state")
        #expect(items.first(where: { $0.name == "code_challenge" })?.value == "challenge")
    }

    @Test
    func pkceChallengeMatchesRFC7636ReferenceVector() {
        #expect(
            PKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func pkceEncodesIndependentStateAndVerifierWithoutPadding() throws {
        var requests: [Int] = []
        let proof = try PKCE { bytes in
            requests.append(bytes.count)
            for index in bytes.indices { bytes[index] = index % 3 == 0 ? 0xFB : 0xFF }
            return errSecSuccess
        }
        #expect(requests == [16, 64])
        #expect(proof.state == String(repeating: "-___", count: 5) + "-w")
        #expect(proof.verifier == String(repeating: "-___", count: 21) + "-w")
    }

    @Test(arguments: [1, 2])
    func pkceRejectsFailureOfEitherRandomValue(_ failingRequest: Int) {
        var requests = 0
        #expect(throws: KeymasterAuthError.secureRandomFailed) {
            try PKCE { bytes in
                requests += 1
                bytes.copyBytes(from: [UInt8](repeating: 0xFF, count: bytes.count))
                return requests == failingRequest ? errSecNotAvailable : errSecSuccess
            }
        }
        #expect(requests == failingRequest)
    }

    private static func code(from query: String) throws -> String {
        let callback = try #require(URLComponents(string: "http://127.0.0.1/login?\(query)"))
        return try KeymasterAuth.authorizationCode(from: callback, expectedState: "expected")
    }
}

@Suite("Loopback Parsing")
struct LoopbackParsingTests {
    @Test
    @MainActor
    func testLoopbackParsing() {
        // The parser itself is covered exhaustively in the domain suite; here just
        // prove the server forwards to it.
        let parsed = LoopbackCallbackServer.parseRequestLine(
            "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n"
        )
        #expect((parsed?.path) == ("/login"), "forwarder parses the login path")
        #expect((LoopbackCallbackServer.parseRequestLine("GET / HTTP/1.1\n")) == nil, "root path rejected")
    }
}

@Suite("Loopback Server")
struct LoopbackServerTests {
    @Test
    @MainActor
    func testLoopbackServer() async {
        do {
            let server = LoopbackCallbackServer(expectedState: "s")
            let port: UInt16
            do {
                port = try await server.start()
            } catch {
                #expect((false) == true, "loopback listener starts")
                return
            }

            let session = URLSession(configuration: .ephemeral)
            async let callback = server.waitForCallback(timeout: .seconds(5))

            let rejectedRoot = await httpStatus(session: session, url: URL(string: "http://127.0.0.1:\(port)/")!)
            #expect((rejectedRoot) == (404), "GET / is not found")
            let rejectedLookalike = await httpStatus(
                session: session,
                url: URL(string: "http://127.0.0.1:\(port)/login/extra?code=steal&state=steal")!
            )
            #expect((rejectedLookalike) == (404), "GET /login/extra is not found")

            let accepted = await httpStatus(
                session: session,
                url: URL(string: "http://127.0.0.1:\(port)/login?code=ok&state=s")!
            )
            #expect((accepted) == (200), "GET /login is accepted")

            do {
                let components = try await callback
                #expect((components.path) == ("/login"), "accepted target is /login")
                #expect(
                    (components.queryItems?.first(where: { $0.name == "code" })?.value) == ("ok"),
                    "code survives rejected predecessors")
            } catch {
                #expect((false) == true, "rejected targets do not finish the waiter")
            }
        }
    }
}

private func httpStatus(session: URLSession, url: URL) async -> Int {
    do {
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    } catch {
        return -1
    }
}

@Suite("Auth Cookie Cleanup")
struct AuthCookieCleanupTests {
    @Test
    @MainActor
    func testAuthCookieCleanup() async {
        do {
            func cookie(_ name: String, domain: String, path: String = "/") -> HTTPCookie {
                HTTPCookie(properties: [
                    .name: name,
                    .value: "token",
                    .domain: domain,
                    .path: path,
                ])!
            }

            let spotify = cookie("sp_dc", domain: "accounts.spotify.com")
            let apex = cookie("sp_key", domain: "spotify.com")
            let lookalike = cookie("sp_dc", domain: "notspotify.com")
            let unrelated = cookie("sid", domain: "example.com")
            let deleted = AuthCookieCleanup.cookiesToDelete(in: [unrelated, lookalike, apex, spotify])
            #expect((Set(deleted.map(\.name))) == (Set(["sp_dc", "sp_key"])), "only Spotify cookies are selected")
            #expect(
                (AuthCookieCleanup.cookiesToDelete(in: [unrelated, lookalike]).map(\.name)) == ([]),
                "a second selection of the remainder is empty")
            #expect(
                (AuthCookieCleanup.cookiesToDelete(in: deleted).map(\.name)) == (deleted.map(\.name)),
                "selection is idempotent")
        }

        do {
            let store = MemoryKeymasterStore()
            let counter = CleanupCounter()
            let session = KeymasterSession(
                store: store,
                refresher: { _ in throw KeymasterAuthError.grantRevoked },
                cookieCleanup: { counter.increment() }
            )
            let tokens = KeymasterTokens(
                accessToken: "at",
                refreshToken: "rt",
                expiresAt: Date().addingTimeInterval(3_600),
                username: "listener"
            )
            do {
                try await session.adopt(tokens)
                #expect((store.stored?.accessToken) == ("at"), "adopt writes the grant")
            } catch {
                #expect((false) == true, "adopt writes the grant")
            }
            #expect(await session.clear())
            #expect((counter.count) == (1), "clearing the grant removes Spotify cookies")
            #expect(await session.clear())
            #expect((counter.count) == (2), "a second clear is still safe")
            #expect((store.stored) == nil, "the grant does not return after cookie cleanup")
        }
    }
}

private final class MemoryKeymasterStore: KeymasterTokenStoring, @unchecked Sendable {
    var stored: KeymasterTokens?

    func loadResult() -> KeymasterGrantLoadResult {
        stored.map(KeymasterGrantLoadResult.found) ?? .absent
    }

    func save(_ tokens: KeymasterTokens) throws {
        stored = tokens
    }

    func clear() {
        stored = nil
    }
}

private final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

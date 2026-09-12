import Testing
//
//  AuthAndParsingChecks.swift
//  Spotty
//

import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Auth Flow")
struct AuthFlowTests {
    @Test
    @MainActor
    func testAuthFlow() {
        do {
            let body = Data(
                """
                {"access_token":"at","refresh_token":"rt","expires_in":3600,"username":"listener"}
                """.utf8)
            let now = Date(timeIntervalSince1970: 1_000_000)

            let tokens = try? KeymasterAuth.parseTokenResponse(body, fallbackRefreshToken: nil, now: now)
            #expect((tokens) != nil, "well-formed response parses")
            if let tokens {
                #expect((tokens.accessToken) == ("at"), "access token")
                #expect((tokens.refreshToken) == ("rt"), "refresh token")
                #expect((tokens.username) == ("listener"), "username")
                #expect(
                    (tokens.expiresAt) == (now.addingTimeInterval(3_600)), "expiry resolves against the injected clock")
            }

            // A refresh that omits its token must keep the previous one alive.
            let rotated = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at2","expires_in":1800}"#.utf8),
                fallbackRefreshToken: "previous-rt",
                now: now
            )
            #expect((rotated?.refreshToken) == ("previous-rt"), "rotation without a new token keeps the old one")

            for malformed in [Data("{}".utf8), Data(#"{"refresh_token":"rt"}"#.utf8)] {
                var threw = false
                do {
                    _ = try KeymasterAuth.parseTokenResponse(malformed, fallbackRefreshToken: nil, now: now)
                } catch {
                    threw = (error as? KeymasterAuthError) == .malformedTokenResponse
                }
                #expect((threw) == true, "response without an access token is malformed")
            }

            // A wrongly-typed access token must fail closed rather than mint an empty credential.
            var wrongType = false
            do {
                _ = try KeymasterAuth.parseTokenResponse(
                    Data(#"{"access_token":123,"expires_in":3600}"#.utf8),
                    fallbackRefreshToken: nil,
                    now: now
                )
            } catch {
                wrongType = (error as? KeymasterAuthError) == .malformedTokenResponse
            }
            #expect((wrongType) == true, "numeric access token is malformed")

            // An unreadable expiry must not silently invent a token lifetime.
            let stringExpiry = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at","refresh_token":"rt","expires_in":"3600"}"#.utf8),
                fallbackRefreshToken: nil,
                now: now
            )
            #expect(
                stringExpiry == nil,
                "string expires_in is rejected rather than inventing a lifetime")

            // An omitted expiry behaves the same way.
            let missingExpiry = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at","refresh_token":"rt"}"#.utf8),
                fallbackRefreshToken: nil,
                now: now
            )
            #expect(
                missingExpiry == nil, "missing expires_in is rejected"
            )
        }

        do {
            let revoked = KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            #expect((revoked == .grantRevoked) == (true), "only invalid_grant revokes the grant")

            var classifiedAsFailure = false
            if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(
                status: 400,
                body: Data(#"{"error":"invalid_request"}"#.utf8)
            ) {
                classifiedAsFailure = true
            }
            #expect((classifiedAsFailure) == true, "a non-revocation refusal keeps the grant")

            var serverErrorKeepsGrant = false
            if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(status: 500, body: Data()) {
                serverErrorKeepsGrant = true
            }
            #expect((serverErrorKeepsGrant) == true, "server errors are transient")

            let sentinel = "SPOTTY_PRIVACY_SENTINEL_token-body_7f3c"
            let refused = KeymasterAuth.tokenFailure(
                status: 400,
                body: Data(#"{"error":"invalid_request","error_description":"\#(sentinel)"}"#.utf8)
            )
            #expect((refused) == (.tokenExchangeFailed(400)), "non-revocation token failures keep HTTP status")
            #expect(
                (refused.errorDescription ?? "") == ("Token exchange failed (HTTP 400)"),
                "token failures surface a stable HTTP category")
            #expect(
                (refused.errorDescription?.contains(sentinel) == false) == true,
                "token failure descriptions omit the response body")
        }

        do {
            func code(from query: String, state: String) throws -> String {
                let callback = URLComponents(string: "http://127.0.0.1/login?\(query)")!
                return try KeymasterAuth.authorizationCode(from: callback, expectedState: state)
            }

            do {
                do {
                    let value = try code(from: "code=abc&state=expected", state: "expected")
                    #expect((value) == ("abc"), "authorization code extracted")

                } catch {
                    Issue.record("\("matching state yields the code"): unexpected error \(error)")
                }
            }

            // A forged or stale redirect must fail on state even when it carries an error
            // that would otherwise read as a user cancellation.
            var mismatched = false
            do {
                _ = try code(from: "error=access_denied&state=wrong", state: "expected")
            } catch {
                mismatched = (error as? KeymasterAuthError) == .stateMismatch
            }
            #expect((mismatched) == true, "state is checked before error and code")

            var denied = false
            do {
                _ = try code(from: "error=access_denied&state=expected", state: "expected")
            } catch {
                denied = (error as? KeymasterAuthError) == .authorizationDenied
            }
            #expect((denied) == true, "user denial is reported as such")

            let deniedSentinel = "SPOTTY_PRIVACY_SENTINEL_oauth-error_4c1a"
            var deniedDescription: String?
            do {
                _ = try code(from: "error=\(deniedSentinel)&state=expected", state: "expected")
                #expect((false) == true, "authorization denial with sentinel text throws")
            } catch let error as LocalizedError {
                deniedDescription = error.errorDescription
            } catch {
                #expect((false) == true, "authorization denial with sentinel text is LocalizedError, got \(error)")
            }
            #expect(
                (deniedDescription ?? "") == ("Spotify declined the authorization"),
                "authorization denial uses a stable category")
            #expect(
                (deniedDescription?.contains(deniedSentinel) == false) == true,
                "authorization denial omits redirect error text")

            var missingCode = false
            do {
                _ = try code(from: "state=expected", state: "expected")
            } catch {
                missingCode = (error as? KeymasterAuthError) == .noAuthorizationCode
            }
            #expect((missingCode) == true, "missing code is reported as such")

            let url = KeymasterAuth.authorizationURL(port: 49_152, challenge: "challenge", state: "state")
            #expect((url) != nil, "authorization URL builds")
            if let url,
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            {
                #expect((items.first(where: { $0.name == "code_challenge_method" })?.value) == ("S256"), "PKCE method")
                #expect(
                    (items.first(where: { $0.name == "redirect_uri" })?.value) == ("http://127.0.0.1:49152/login"),
                    "loopback redirect names the listening port")
                #expect(
                    (items.first(where: { $0.name == "scope" })?.value?.contains("streaming") == true) == true,
                    "streaming scope requested")
            }

            // RFC 7636 Appendix B.
            #expect(
                (PKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
                    == ("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
                "PKCE challenge matches the RFC reference vector")
        }
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
            let server = LoopbackCallbackServer()
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
            await session.clear()
            #expect((counter.count) == (1), "clearing the grant removes Spotify cookies")
            await session.clear()
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

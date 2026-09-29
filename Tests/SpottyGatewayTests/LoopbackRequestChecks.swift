import Foundation
import Testing
@testable import SpottyGateway

@Suite("Loopback Request")
struct LoopbackRequestTests {
    @Test(arguments: [
        ("state=expected&state=wrong&code=first&code=second", "first"),
        ("code=a%2Bb+c&state=expected", "a+b+c"),
        ("error&error=access_denied&state=expected&code=first", "first"),
    ])
    func parsingPreservesQueryOrderAndValues(query: String, code: String) throws {
        let callback = try #require(LoopbackCallbackServer.parseRequestLine("GET /login?\(query) HTTP/1.1\r\n"))
        #expect(try KeymasterAuth.authorizationCode(from: callback, expectedState: "expected") == code)
    }

    @Test(arguments: [
        ("state=wrong&state=expected&code=ok", KeymasterAuthError.stateMismatch),
        ("state&state=expected&code=ok", KeymasterAuthError.stateMismatch),
        ("code=&code=ok&state=expected", KeymasterAuthError.noAuthorizationCode),
        ("error=&code=ok&state=expected", KeymasterAuthError.authorizationDenied),
        ("error=access_denied&code=ok&state=wrong", KeymasterAuthError.stateMismatch),
        ("", KeymasterAuthError.stateMismatch),
    ])
    func parsingDoesNotGrantAuthorization(query: String, error: KeymasterAuthError) throws {
        let callback = try #require(LoopbackCallbackServer.parseRequestLine("GET /login?\(query) HTTP/1.1\r\n"))
        #expect(throws: error) {
            try KeymasterAuth.authorizationCode(from: callback, expectedState: "expected")
        }
    }

    @Test
    func requestLineSyntax() {
        let crlf = LoopbackCallbackServer.parseRequestLine(
            "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n")
        #expect((crlf) != nil, "CRLF GET line parses")
        #expect((crlf?.path) == ("/login"), "path")
        #expect((crlf?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "code parameter")
        #expect((crlf?.queryItems?.first(where: { $0.name == "state" })?.value) == ("xyz"), "state parameter")

        let lf = LoopbackCallbackServer.parseRequestLine("GET /login?code=abc&state=xyz HTTP/1.1\nHost: 127.0.0.1\n")
        #expect((lf?.path) == ("/login"), "LF terminator yields the same path")
        #expect(
            (lf?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"),
            "LF terminator yields the same code")

        let splitLine = LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/1.1")
        #expect((splitLine) != nil, "unterminated split request still parses")
        #expect((splitLine?.path) == ("/login"), "split-request path")
        #expect(
            (splitLine?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "split-request code")
        #expect((LoopbackCallbackServer.parseRequestLine("")) == nil, "empty input rejected")
        #expect((LoopbackCallbackServer.parseRequestLine("\n")) == nil, "newline-only input rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("POST /login?code=abc HTTP/1.1\n")) == nil,
            "non-GET methods rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("get /login?code=abc HTTP/1.1\n")) == nil,
            "lowercase methods rejected")
        let bare = LoopbackCallbackServer.parseRequestLine("GET /login HTTP/1.1\n")
        #expect((bare) != nil, "query-less request parses")
        #expect((bare?.path) == ("/login"), "query-less path")
        #expect((bare?.queryItems) == nil, "no parameters without a query")

        let encodedPath = LoopbackCallbackServer.parseRequestLine("GET /%6Cogin?code=abc&state=xyz HTTP/1.1\n")
        #expect((encodedPath?.path) == ("/login"), "percent-decoded path is /login")
        #expect(
            (encodedPath?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"),
            "percent-decoded path still yields the code")

        let encodedQuery = LoopbackCallbackServer.parseRequestLine("GET /login?code=a%20b&state=xy%26z HTTP/1.1\n")
        #expect(
            (encodedQuery?.queryItems?.first(where: { $0.name == "code" })?.value) == ("a b"),
            "query values stay percent-decoded")
        #expect(
            (encodedQuery?.queryItems?.first(where: { $0.name == "state" })?.value) == ("xy&z"),
            "encoded ampersands stay inside the value")

        #expect((LoopbackCallbackServer.parseRequestLine("GET / HTTP/1.1\n")) == nil, "root path rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /?code=abc&state=xyz HTTP/1.1\n")) == nil,
            "root path with query cannot win")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login/extra?code=abc HTTP/1.1\n")) == nil,
            "prefix lookalike rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /loginn?code=abc HTTP/1.1\n")) == nil,
            "suffix lookalike rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /callback/login?code=abc HTTP/1.1\n")) == nil,
            "embedded /login rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login/?code=abc HTTP/1.1\n")) == nil,
            "trailing slash rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login%2Fextra?code=abc HTTP/1.1\n")) == nil,
            "encoded extra segment rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET //login?code=abc HTTP/1.1\n")) == nil,
            "double-slash target rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET http://127.0.0.1/login?code=abc HTTP/1.1\n")) == nil,
            "absolute-form target rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc\n")) == nil,
            "missing HTTP version rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login HTTP/1.1 extra\n")) == nil,
            "extra request-line tokens rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET\t/login HTTP/1.1\n")) == nil,
            "tab-separated request-line rejected")
        #expect((LoopbackCallbackServer.parseRequestLine("GET /login HTTP/1.0\n")) != nil, "HTTP/1.0 is accepted")
        #expect((LoopbackCallbackServer.parseRequestLine("GET /login HTTP/2\n")) != nil, "HTTP/2 is accepted")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/\n")) == nil,
            "empty HTTP version rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/1.1junk\n")) == nil,
            "suffixed HTTP version rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/not-a-version\n")) == nil,
            "non-numeric HTTP version rejected")
        #expect(
            (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/๒\n")) == nil,
            "Unicode numeric HTTP version rejected")
    }
}

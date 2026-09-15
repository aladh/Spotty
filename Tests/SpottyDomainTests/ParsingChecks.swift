import Testing
import SpottyDomain
import Foundation

@Suite("Parsing")
struct ParsingTests {
    @Test(arguments: ["track", "album", "artist", "playlist", "user"])
    func emptyURIComponentsAreRejected(kind: String) {
        let valid = "spotify:\(kind):entity"
        #expect(SpotifyURI.id(from: valid) == "entity")
        #expect(SpotifyURI.id(from: valid, kind: kind) == "entity")
        for malformed in [":" + valid, valid + ":", "spotify::\(kind):entity", "spotify:\(kind)::entity"] {
            #expect(SpotifyURI.id(from: malformed) == nil)
            #expect(SpotifyURI.id(from: malformed, kind: kind) == nil)
        }
    }

    @Test
    func legacyURIParsingKeepsCompleteComponents() {
        #expect(SpotifyURI.id(from: "spotify:user:alice:playlist:collection") == "collection")
        #expect(SpotifyURI.id(from: "spotify:user:alice:playlist:collection", kind: "playlist") == nil)
        for malformed in ["spotify:user::playlist:collection", "spotify:user:alice:playlist:"] {
            #expect(SpotifyURI.id(from: malformed) == nil)
        }
    }

    @Test
    func testParsing() {
        do {
            #expect(
                (Pagination.nextOffset(offset: 50, pageEntryCount: 50, totalCount: 130)) == (100),
                "mid-collection page advances by its entry count")
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 30, totalCount: 130)) == nil,
                "reaching totalCount ends the walk")
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 50, totalCount: 130)) == nil,
                "overshooting totalCount ends the walk")
            #expect(
                (Pagination.nextOffset(offset: 50, pageEntryCount: 0, totalCount: 130)) == nil,
                "an empty page ends the walk")
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: nil)) == (50),
                "missing totalCount keeps walking")
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 60)) == (50),
                "offset ignores how many entities survived decoding")
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 29, totalCount: 130)) == (129),
                "one short of totalCount keeps walking")
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 50)) == nil,
                "single-page collections end immediately")
            #expect(
                (Pagination.nextOffset(offset: 40, pageEntryCount: 20, totalCount: 0)) == nil,
                "an emptied collection ends the walk")
        }

        do {
            #expect(
                (Pagination.decision(offset: 0, pageEntryCount: 50, totalCount: 130, pagesFetched: 1))
                    == (.fetch(offset: 50)), "ordinary totalCount names the next offset")
            #expect(
                (Pagination.decision(offset: 0, pageEntryCount: 50, totalCount: 50, pagesFetched: 1)) == (.finished),
                "exact page-boundary totalCount finishes")
            #expect(
                (Pagination.decision(offset: 0, pageEntryCount: 0, totalCount: nil, pagesFetched: 1)) == (.finished),
                "empty first page finishes")
            #expect(
                (Pagination.decision(offset: 50, pageEntryCount: 0, totalCount: nil, pagesFetched: 2)) == (.finished),
                "omitted totalCount finishes on an empty page")
            #expect(
                (Pagination.decision(
                    offset: 0,
                    pageEntryCount: 50,
                    totalCount: nil,
                    pagesFetched: 1,
                    requestedOffsets: [0, 50]
                )) == (.failed(.offsetDidNotAdvance)), "a repeated next offset fails rather than refetching")
            #expect(
                (Pagination.decision(
                    offset: 50,
                    pageEntryCount: 50,
                    totalCount: nil,
                    pagesFetched: 2,
                    nextOffset: { offset, _, _ in offset }
                )) == (.failed(.offsetDidNotAdvance)), "a next offset that does not move forward fails")
            #expect(
                (Pagination.decision(
                    offset: 0,
                    pageEntryCount: 50,
                    totalCount: nil,
                    pagesFetched: Pagination.maximumPageCount
                )) == (.failed(.pageLimitReached)), "exhausting the page cap fails instead of continuing")
            #expect(
                (Pagination.decision(
                    offset: 0,
                    pageEntryCount: 50,
                    totalCount: nil,
                    pagesFetched: Pagination.maximumPageCount - 1
                )) == (.fetch(offset: 50)), "the last allowed page may still name a successor before the cap")

            #expect(
                (Pagination.Failure.pageLimitReached.errorDescription)
                    == ("Spotify pagination exceeded the request limit"),
                "cap exhaustion uses a stable category")
            #expect(
                (Pagination.Failure.offsetDidNotAdvance.errorDescription) == ("Spotify pagination did not advance"),
                "non-progress uses a stable category")
        }

        do {
            let crlf = LoopbackRequestParser.parseRequestLine(
                "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n")
            #expect((crlf) != nil, "CRLF GET line parses")
            #expect((crlf?.path) == ("/login"), "path")
            #expect((crlf?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "code parameter")
            #expect((crlf?.queryItems?.first(where: { $0.name == "state" })?.value) == ("xyz"), "state parameter")

            let lf = LoopbackRequestParser.parseRequestLine("GET /login?code=abc&state=xyz HTTP/1.1\nHost: 127.0.0.1\n")
            #expect((lf?.path) == ("/login"), "LF terminator yields the same path")
            #expect(
                (lf?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"),
                "LF terminator yields the same code")

            let splitLine = LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/1.1")
            #expect((splitLine) != nil, "unterminated split request still parses")
            #expect((splitLine?.path) == ("/login"), "split-request path")
            #expect(
                (splitLine?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "split-request code")
            #expect((LoopbackRequestParser.parseRequestLine("")) == nil, "empty input rejected")
            #expect((LoopbackRequestParser.parseRequestLine("\n")) == nil, "newline-only input rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("POST /login?code=abc HTTP/1.1\n")) == nil,
                "non-GET methods rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("get /login?code=abc HTTP/1.1\n")) == nil,
                "lowercase methods rejected")
            let bare = LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.1\n")
            #expect((bare) != nil, "query-less request parses")
            #expect((bare?.path) == ("/login"), "query-less path")
            #expect((bare?.queryItems) == nil, "no parameters without a query")

            let encodedPath = LoopbackRequestParser.parseRequestLine("GET /%6Cogin?code=abc&state=xyz HTTP/1.1\n")
            #expect((encodedPath?.path) == ("/login"), "percent-decoded path is /login")
            #expect(
                (encodedPath?.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"),
                "percent-decoded path still yields the code")

            let encodedQuery = LoopbackRequestParser.parseRequestLine("GET /login?code=a%20b&state=xy%26z HTTP/1.1\n")
            #expect(
                (encodedQuery?.queryItems?.first(where: { $0.name == "code" })?.value) == ("a b"),
                "query values stay percent-decoded")
            #expect(
                (encodedQuery?.queryItems?.first(where: { $0.name == "state" })?.value) == ("xy&z"),
                "encoded ampersands stay inside the value")

            #expect((LoopbackRequestParser.parseRequestLine("GET / HTTP/1.1\n")) == nil, "root path rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /?code=abc&state=xyz HTTP/1.1\n")) == nil,
                "root path with query cannot win")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login/extra?code=abc HTTP/1.1\n")) == nil,
                "prefix lookalike rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /loginn?code=abc HTTP/1.1\n")) == nil,
                "suffix lookalike rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /callback/login?code=abc HTTP/1.1\n")) == nil,
                "embedded /login rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login/?code=abc HTTP/1.1\n")) == nil,
                "trailing slash rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login%2Fextra?code=abc HTTP/1.1\n")) == nil,
                "encoded extra segment rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET //login?code=abc HTTP/1.1\n")) == nil,
                "double-slash target rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET http://127.0.0.1/login?code=abc HTTP/1.1\n")) == nil,
                "absolute-form target rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login?code=abc\n")) == nil,
                "missing HTTP version rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.1 extra\n")) == nil,
                "extra request-line tokens rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET\t/login HTTP/1.1\n")) == nil,
                "tab-separated request-line rejected")
            #expect((LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.0\n")) != nil, "HTTP/1.0 is accepted")
            #expect((LoopbackRequestParser.parseRequestLine("GET /login HTTP/2\n")) != nil, "HTTP/2 is accepted")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/\n")) == nil,
                "empty HTTP version rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/1.1junk\n")) == nil,
                "suffixed HTTP version rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/not-a-version\n")) == nil,
                "non-numeric HTTP version rejected")
            #expect(
                (LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/๒\n")) == nil,
                "Unicode numeric HTTP version rejected")
        }

        do {
            #expect(
                (SpotifyAuthenticationCookies.shouldRemove(domain: "accounts.spotify.com", path: "/")) == true,
                "accounts host is Spotify")
            #expect(
                (SpotifyAuthenticationCookies.shouldRemove(domain: ".spotify.com", path: "/")) == true,
                "leading-dot domain is Spotify")
            #expect(
                (SpotifyAuthenticationCookies.shouldRemove(domain: "www.spotify.com", path: "/api")) == true,
                "subdomain and subdirectory stay Spotify")
            #expect(
                (!SpotifyAuthenticationCookies.shouldRemove(domain: "notspotify.com", path: "/")) == true,
                "lookalike host is not Spotify")
            #expect(
                (!SpotifyAuthenticationCookies.shouldRemove(domain: "spotify.com.evil.example", path: "/")) == true,
                "suffixed lookalike is not Spotify")
            #expect(
                (!SpotifyAuthenticationCookies.shouldRemove(domain: "example.com", path: "/")) == true,
                "unrelated domain is kept")
            #expect(
                (!SpotifyAuthenticationCookies.shouldRemove(domain: "spotify.com", path: "")) == true,
                "empty path is not a cookie path")
        }

        do {
            #expect(
                (SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"))
                    == ("37i9dQZF1DXcBWIGoYBM5M"), "kind-matched playlist uri yields its id")
            #expect(
                (SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist")) == nil,
                "folder uris never pass as playlists")
            #expect(
                (SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist")) == nil, "a mismatched kind is refused")
            #expect(
                (SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789")) == ("xyz789"),
                "kind-free parsing takes the last component")
        }
    }
}

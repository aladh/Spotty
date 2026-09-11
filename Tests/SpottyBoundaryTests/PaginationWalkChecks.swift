import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

@Suite("Pagination Walk")
struct PaginationWalkTests {
    @Test
    @MainActor
    func testPaginationWalk() async {
        do {
            let playlistTransport = ScriptedOffsetTransport { operation, offset in
                guard operation == "fetchPlaylist" else { return (500, Data()) }
                return (200, playlistPage(offset: offset, totalCount: 2))
            }
            let playlist = try? await partnerAPI(transport: playlistTransport.send).playlist(id: "pl")
            #expect(
                (playlist?.content?.items?.compactMap(\.uid)) == (["uid-0", "uid-1"]),
                "playlist concatenates pages in order")
            #expect((playlist?.content?.totalCount) == (2), "playlist freezes totalCount from the first page")
            #expect(
                (playlistTransport.offsets(for: "fetchPlaylist")) == ([0, 1]), "playlist walks exactly the named pages")

            let tracksTransport = ScriptedOffsetTransport { operation, offset in
                guard operation == "fetchLibraryTracks" else { return (500, Data()) }
                if offset == 0 {
                    return (200, libraryTracksPage(offset: offset, totalCount: nil, itemCount: 1))
                }
                return (200, libraryTracksPage(offset: offset, totalCount: nil, itemCount: 0))
            }
            let tracks = try? await partnerAPI(transport: tracksTransport.send).libraryTracks()
            #expect(
                (tracks?.compactMap(\.track?.uri)) == (["spotify:track:t0"]),
                "libraryTracks omitted totalCount ends on an empty page")
            #expect(
                (tracksTransport.offsets(for: "fetchLibraryTracks")) == ([0, 1]),
                "libraryTracks requests the empty terminator")

            let playlistsTransport = ScriptedOffsetTransport { operation, offset in
                guard operation == "libraryV3" else { return (500, Data()) }
                return (200, libraryEntitiesPage(itemCount: offset == 0 ? 0 : 1, totalCount: 0))
            }
            let playlists = try? await partnerAPI(transport: playlistsTransport.send).playlistLibrary()
            #expect((playlists?.count) == (0), "empty first library page yields no playlists")
            #expect(
                (playlistsTransport.offsets(for: "libraryV3")) == ([0]), "empty first library page does not continue")

            let failed = ScriptedOffsetTransport { operation, offset in
                guard operation == "fetchLibraryTracks" else { return (500, Data()) }
                if offset == 0 {
                    return (200, libraryTracksPage(offset: 0, totalCount: 10, itemCount: 1))
                }
                return (503, Data(#"{"error":"SPOTTY_PRIVACY_SENTINEL_api-body_d81f"}"#.utf8))
            }
            await expectThrown(
                "a mid-walk HTTP error stays typed",
                PartnerAPIError.requestFailed(503)
            ) {
                _ = try await partnerAPI(transport: failed.send).libraryTracks()
            }
            #expect(
                (failed.offsets(for: "fetchLibraryTracks")) == ([0, 1, 1, 1]),
                "a mid-walk HTTP error retries that page then stays typed")
        }
    }
}

private func partnerAPI(transport: @escaping SpotifyCredentials.Transport) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: .immediate
    )
}

@MainActor
private func expectThrown<Failure: Error & Equatable>(
    _ label: String,
    _ expected: Failure,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as Failure {
        #expect((error) == (expected), "\(label)")
    } catch {
        #expect((false) == true, "\(label) throws \(Failure.self), got \(error)")
    }
}

private func playlistPage(offset: Int, totalCount: Int) -> Data {
    Data(
        """
        {"data":{"playlistV2":{"uri":"spotify:playlist:pl","name":"Mix","content":{"totalCount":\(totalCount),"items":[{"uid":"uid-\(offset)","itemV2":{"data":{"uri":"spotify:track:t\(offset)","name":"T\(offset)"}}}]}}}}
        """.utf8
    )
}

private func libraryTracksPage(offset: Int, totalCount: Int?, itemCount: Int) -> Data {
    let total = totalCount.map { "\"totalCount\":\($0)," } ?? ""
    let items: String
    if itemCount == 0 {
        items = "[]"
    } else {
        items = "[{\"track\":{\"_uri\":\"spotify:track:t\(offset)\",\"data\":{\"name\":\"T\(offset)\"}}}]"
    }
    return Data(
        """
        {"data":{"me":{"library":{"tracks":{\(total)"items":\(items)}}}}}
        """.utf8
    )
}

private func libraryEntitiesPage(itemCount: Int, totalCount: Int) -> Data {
    let items: String
    if itemCount == 0 {
        items = "[]"
    } else {
        items = "[{\"item\":{\"data\":{\"uri\":\"spotify:playlist:p0\",\"name\":\"P0\"}}}]"
    }
    return Data(
        """
        {"data":{"me":{"libraryV3":{"totalCount":\(totalCount),"items":\(items)}}}}
        """.utf8
    )
}

private struct PathfinderOffsetProbe: Decodable {
    struct Variables: Decodable {
        let offset: Int?
    }

    let operationName: String
    let variables: Variables
}

private final class ScriptedOffsetTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: [Int]] = [:]
    private let response: @Sendable (String, Int) -> (Int, Data)

    init(response: @escaping @Sendable (String, Int) -> (Int, Data)) {
        self.response = response
    }

    func offsets(for operation: String) -> [Int] {
        lock.withLock { recorded[operation] ?? [] }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        let probe = try JSONDecoder().decode(PathfinderOffsetProbe.self, from: request.httpBody ?? Data())
        let offset = probe.variables.offset ?? 0
        lock.lock()
        recorded[probe.operationName, default: []].append(offset)
        lock.unlock()
        let (status, body) = response(probe.operationName, offset)
        let url = request.url ?? URL(string: "https://example.invalid/")!
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

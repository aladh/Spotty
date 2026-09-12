import Foundation
import SpottyDomain
import Testing
@testable import SpottyGateway

@Suite("Catalog Pagination")
@MainActor
struct CatalogPaginationTests {
    @Test
    func albumPagesPreserveOrderAndAdvancePastUnavailableTracks() async throws {
        let transport = CatalogPageTransport { operation, offset in
            #expect(operation == "getAlbum")
            switch offset {
            case 0: return try catalogAlbumPage(tracks: ["first", nil], total: 4)
            case 2: return try catalogAlbumPage(tracks: ["second", "third"], total: 4)
            default: throw HarnessFailure.unavailable
            }
        }

        let album = try await catalogPaginationAPI(transport: transport.send).album(id: "fixture")

        #expect(
            album.tracks.compactMap(\.uri) == ["spotify:track:first", "spotify:track:second", "spotify:track:third"])
        #expect(album.tracksV2?.items?.count == 4)
        #expect(album.tracksV2?.totalCount == 4)
        #expect(transport.offsets == [0, 2])
    }

    @Test
    func discographyOffsetsCountGroupsInsteadOfReleaseEditions() async throws {
        let transport = CatalogPageTransport { operation, offset in
            #expect(operation == "queryArtistDiscographyAll")
            switch offset {
            case 0: return try catalogArtistPage(groups: [["first", "first-deluxe"]], total: 2)
            case 1: return try catalogArtistPage(groups: [["second"]], total: 2)
            default: throw HarnessFailure.unavailable
            }
        }

        let artist = try await catalogPaginationAPI(transport: transport.send).artistDiscography(id: "fixture")

        #expect(
            artist.releases.compactMap(\.uri) == [
                "spotify:album:first", "spotify:album:first-deluxe", "spotify:album:second",
            ])
        #expect(artist.discography?.all?.items?.count == 2)
        #expect(transport.offsets == [0, 1])
    }

    @Test(arguments: [false, true])
    func aKnownTotalCannotFinishWithAnIncompleteEmptyPage(discography: Bool) async {
        let transport = CatalogPageTransport { _, offset in
            if discography {
                return try catalogArtistPage(groups: offset == 0 ? [["first"]] : [], total: 2)
            }
            return try catalogAlbumPage(tracks: offset == 0 ? ["first"] : [], total: 2)
        }
        let api = catalogPaginationAPI(transport: transport.send)

        do {
            if discography {
                _ = try await api.artistDiscography(id: "fixture")
            } else {
                _ = try await api.album(id: "fixture")
            }
            Issue.record("A missing final page must not publish a partial collection as complete")
        } catch {
            #expect(error as? PartnerAPIError == .pagination(.incompleteCollection))
        }
        #expect(transport.offsets == [0, 1])
    }
}

private func catalogPaginationAPI(transport: @escaping SpotifyCredentials.Transport) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: .immediate
    )
}

private func catalogAlbumPage(tracks: [String?], total: Int) throws -> Data {
    let items: [[String: Any]] = tracks.map { identifier in
        guard let identifier else { return ["track": NSNull()] }
        return ["track": ["uri": "spotify:track:\(identifier)", "name": identifier]]
    }
    return try JSONSerialization.data(withJSONObject: [
        "data": [
            "albumUnion": [
                "uri": "spotify:album:fixture", "name": "Fixture Album",
                "tracksV2": ["items": items, "totalCount": total],
            ]
        ]
    ])
}

private func catalogArtistPage(groups: [[String]], total: Int) throws -> Data {
    let items = groups.map { editions in
        ["releases": ["items": editions.map { ["uri": "spotify:album:\($0)", "name": $0] }]]
    }
    return try JSONSerialization.data(withJSONObject: [
        "data": [
            "artistUnion": [
                "uri": "spotify:artist:fixture",
                "discography": ["all": ["items": items, "totalCount": total]],
            ]
        ]
    ])
}

/// Records transport page offsets; the generic catalog harness intentionally exposes complete reads.
private final class CatalogPageTransport: @unchecked Sendable {
    private struct Request: Decodable {
        struct Variables: Decodable { let offset: Int? }
        let operationName: String
        let variables: Variables
    }

    private let lock = NSLock()
    private var recordedOffsets: [Int] = []
    private let page: @Sendable (String, Int) throws -> Data

    init(page: @escaping @Sendable (String, Int) throws -> Data) { self.page = page }

    var offsets: [Int] { lock.withLock { recordedOffsets } }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            let probe = try JSONDecoder().decode(Request.self, from: request.httpBody ?? Data())
            let offset = probe.variables.offset ?? 0
            lock.withLock { recordedOffsets.append(offset) }
            let body = try page(probe.operationName, offset)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid/")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
    }
}

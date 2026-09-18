import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Catalog Pagination")
@MainActor
struct CatalogPaginationTests {
    @Test(arguments: ["Album", "Playlist", "Artist"], [0, 1])
    func unionErrorsFailOnEveryPage(kind: String, errorOffset: Int) async throws {
        let field = kind == "Album" ? "albumUnion" : kind == "Playlist" ? "playlistV2" : "artistUnion"
        let transport = CatalogPageTransport { _, offset in
            if offset == errorOffset {
                return try JSONSerialization.data(withJSONObject: ["data": [field: ["__typename": "GenericError"]]])
            }
            return try catalogCollectionPage(kind: kind, tracks: ["first"], total: 2)
        }
        let api = catalogPaginationAPI(transport: transport.send)
        await #expect(throws: PartnerAPIError.emptyPayload) {
            _ = try await catalogCollectionRead(api: api, kind: kind)
        }
        #expect(transport.offsets == (errorOffset == 0 ? [0] : [0, 1]))
    }

    @Test(arguments: ["Album", "Playlist", "Artist"])
    func legitimateEmptyCollectionsStillSucceed(kind: String) async throws {
        let transport = CatalogPageTransport { _, _ in try catalogCollectionPage(kind: kind, tracks: [], total: 0) }
        let result = try await catalogCollectionRead(api: catalogPaginationAPI(transport: transport.send), kind: kind)
        #expect(result.isEmpty)
        #expect(transport.offsets == [0])
    }

    @Test(arguments: ["Album", "Playlist"])
    func anErrorUnionCannotOverwriteTheSavedCollection(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotty-union-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Data(#"{"data":{"me":{"profile":{"uri":"spotify:user:fixture","name":"Fixture"}}}}"#.utf8)
        let success = CatalogPageTransport { operation, _ in
            if operation == "profileAttributes" { return profile }
            return try catalogCollectionPage(kind: kind, tracks: ["saved", "saved"], total: 2)
        }
        let first = PersistentCatalogProvider(
            source: SpotifyCatalogGateway(api: catalogPaginationAPI(transport: success.send)), rootDirectory: root)
        await first.activate()
        _ = try await first.profile()
        if kind == "Album" {
            _ = try await first.album(id: "fixture")
        } else {
            _ = try await first.playlist(id: "fixture")
        }
        #expect(await first.retire(purge: false))

        let field = kind == "Album" ? "albumUnion" : "playlistV2"
        let failure = CatalogPageTransport { operation, _ in
            if operation == "profileAttributes" { return profile }
            return try JSONSerialization.data(withJSONObject: ["data": [field: ["__typename": "GenericError"]]])
        }
        let reopened = PersistentCatalogProvider(
            source: SpotifyCatalogGateway(api: catalogPaginationAPI(transport: failure.send)), rootDirectory: root)
        await reopened.activate()
        _ = try await reopened.profile()
        await #expect(throws: CatalogReadFailure.compatibility) {
            if kind == "Album" {
                _ = try await reopened.album(id: "fixture")
            } else {
                _ = try await reopened.playlist(id: "fixture")
            }
        }
        let saved: [CatalogTrack]?
        if kind == "Album" {
            saved = try await reopened.cachedAlbum(id: "fixture")?.tracks
        } else {
            saved = try await reopened.cachedPlaylist(id: "fixture")?.tracks
        }
        #expect(saved?.map(\.uri) == ["spotify:track:saved", "spotify:track:saved"])
        #expect(await reopened.retire(purge: true))
    }

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

private func catalogCollectionRead(api: PartnerAPI, kind: String) async throws -> [String] {
    switch kind {
    case "Album": return try await api.album(id: "fixture").tracks.compactMap(\.uri)
    case "Playlist": return try await api.playlist(id: "fixture").content?.items?.compactMap { $0.track?.uri } ?? []
    default: return try await api.artistDiscography(id: "fixture").releases.compactMap(\.uri)
    }
}

private func catalogCollectionPage(kind: String, tracks: [String], total: Int) throws -> Data {
    switch kind {
    case "Album": return try catalogAlbumPage(tracks: tracks, total: total)
    case "Artist": return try catalogArtistPage(groups: tracks.map { [$0] }, total: total)
    default:
        let items = tracks.enumerated().map { index, track in
            ["uid": "uid-\(index)", "itemV2": ["data": ["uri": "spotify:track:\(track)", "name": track]]]
                as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "playlistV2": [
                    "__typename": "Playlist", "uri": "spotify:playlist:fixture",
                    "name": "Fixture", "content": ["items": items, "totalCount": total],
                ]
            ]
        ])
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
                "__typename": "Album",
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
                "__typename": "Artist",
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

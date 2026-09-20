import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Catalog Pagination")
@MainActor
struct CatalogPaginationTests {
    @Test(
        arguments: [
            "Album", "Playlist", "Artist", "Library playlists", "Library albums", "Library artists", "Liked tracks",
        ],
        ["late-growth", "late-shrink", "late-overshoot", "negative", "overfilled"])
    func everyPagedEndpointRejectsContradictoryCounts(kind: String, fault: String) async {
        let totals: [Int?]
        switch fault {
        case "late-growth": totals = [nil, 3, 4]
        case "late-shrink": totals = [nil, 3, 2]
        case "late-overshoot": totals = [nil, nil, 1]
        case "negative": totals = [-1]
        default: totals = [0]
        }
        let transport = CatalogPageTransport { _, offset in
            guard offset < totals.count else { throw HarnessFailure.unavailable }
            return try catalogCollectionPage(kind: kind, tracks: ["entry-\(offset)"], total: totals[offset])
        }
        await #expect(throws: PartnerAPIError.pagination(.incompleteCollection)) {
            _ = try await catalogCollectionRead(api: catalogPaginationAPI(transport: transport.send), kind: kind)
        }
        #expect(transport.offsets == Array(totals.indices))
    }

    @Test(
        arguments: [
            "Album", "Playlist", "Artist", "Library playlists", "Library albums", "Library artists", "Liked tracks",
        ],
        [false, true])
    func everyPagedEndpointAcceptsConsistentLateOrMissingTotals(kind: String, reportsTotal: Bool) async throws {
        let transport = CatalogPageTransport { _, offset in
            try catalogCollectionPage(
                kind: kind, tracks: offset < 3 ? ["entry-\(offset)"] : [],
                total: reportsTotal && offset == 1 ? 3 : nil)
        }
        let items = try await catalogCollectionRead(api: catalogPaginationAPI(transport: transport.send), kind: kind)
        #expect(items.count == 3)
        #expect(transport.offsets == (reportsTotal ? [0, 1, 2] : [0, 1, 2, 3]))
    }

    @Test(
        arguments: ["Album", "Playlist", "Artist"], ["wrong-uri", "missing-items", "negative-total", "changed-total"])
    func aLaterMalformedPageCannotCompleteACollection(kind: String, fault: String) async throws {
        let transport = CatalogPageTransport { _, offset in
            let good = try catalogCollectionPage(kind: kind, tracks: [offset == 0 ? "first" : "last"], total: 2)
            guard offset != 0 else { return good }
            var json = try #require(JSONSerialization.jsonObject(with: good) as? [String: [String: [String: Any]]])
            let field = kind == "Album" ? "albumUnion" : kind == "Playlist" ? "playlistV2" : "artistUnion"
            var member = try #require(json["data"]?[field])
            if fault == "wrong-uri" {
                member["uri"] = "spotify:\(kind.lowercased()):other"
            } else {
                let key = kind == "Album" ? "tracksV2" : "content"
                var list =
                    kind == "Artist"
                    ? (member["discography"] as? [String: [String: Any]])?["all"]
                    : member[key] as? [String: Any]
                if fault == "missing-items" {
                    list?.removeValue(forKey: "items")
                } else {
                    list?["totalCount"] = fault == "negative-total" ? -1 : 3
                }
                if kind == "Artist" { member["discography"] = ["all": list] } else { member[key] = list }
            }
            json["data"]?[field] = member
            return try JSONSerialization.data(withJSONObject: json)
        }
        await #expect(throws: (any Error).self) {
            _ = try await catalogCollectionRead(api: catalogPaginationAPI(transport: transport.send), kind: kind)
        }
        #expect(transport.offsets == [0, 1])
    }

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
            album.items.compactMap { $0.track?.uri } == [
                "spotify:track:first", "spotify:track:second", "spotify:track:third",
            ])
        #expect(album.items.count == 4)
        #expect(album.header.tracksV2?.totalCount == 4)
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
            artist.items.flatMap(\.all).compactMap(\.uri) == [
                "spotify:album:first", "spotify:album:first-deluxe", "spotify:album:second",
            ])
        #expect(artist.items.count == 2)
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
    case "Album": return try await api.album(id: "fixture").items.compactMap { $0.track?.uri }
    case "Playlist": return try await api.playlist(id: "fixture").items.compactMap { $0.track?.uri }
    case "Library playlists": return try await api.playlistLibrary().map(\.id)
    case "Library albums": return try await api.libraryAlbums().compactMap(\.uri)
    case "Library artists": return try await api.libraryArtists().compactMap(\.uri)
    case "Liked tracks": return try await api.libraryTracks().compactMap { $0.track?.uri }
    default: return try await api.artistDiscography(id: "fixture").items.flatMap(\.all).compactMap(\.uri)
    }
}

private func catalogCollectionPage(kind: String, tracks: [String], total: Int?) throws -> Data {
    switch kind {
    case "Album": return try catalogAlbumPage(tracks: tracks, total: total)
    case "Artist": return try catalogArtistPage(groups: tracks.map { [$0] }, total: total)
    case "Library playlists", "Library albums", "Library artists":
        let type = kind == "Library playlists" ? "playlist" : kind == "Library albums" ? "album" : "artist"
        let items = tracks.map { ["item": ["data": ["uri": "spotify:\(type):\($0)", "name": $0]]] }
        return try JSONSerialization.data(withJSONObject: [
            "data": ["me": ["libraryV3": catalogPage(items: items, total: total)]]
        ])
    case "Liked tracks":
        let items = tracks.map { ["track": ["_uri": "spotify:track:\($0)", "data": ["name": $0]]] }
        return try JSONSerialization.data(withJSONObject: [
            "data": ["me": ["library": ["tracks": catalogPage(items: items, total: total)]]]
        ])
    default:
        let items = tracks.enumerated().map { index, track in
            ["uid": "uid-\(index)", "itemV2": ["data": ["uri": "spotify:track:\(track)", "name": track]]]
                as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "playlistV2": [
                    "__typename": "Playlist", "uri": "spotify:playlist:fixture",
                    "name": "Fixture", "content": catalogPage(items: items, total: total),
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

private func catalogAlbumPage(tracks: [String?], total: Int?) throws -> Data {
    let items: [[String: Any]] = tracks.map { identifier in
        guard let identifier else { return ["track": NSNull()] }
        return ["track": ["uri": "spotify:track:\(identifier)", "name": identifier]]
    }
    return try JSONSerialization.data(withJSONObject: [
        "data": [
            "albumUnion": [
                "__typename": "Album",
                "uri": "spotify:album:fixture", "name": "Fixture Album",
                "tracksV2": catalogPage(items: items, total: total),
            ]
        ]
    ])
}

private func catalogArtistPage(groups: [[String]], total: Int?) throws -> Data {
    let items = groups.map { editions in
        ["releases": ["items": editions.map { ["uri": "spotify:album:\($0)", "name": $0] }]]
    }
    return try JSONSerialization.data(withJSONObject: [
        "data": [
            "artistUnion": [
                "__typename": "Artist",
                "uri": "spotify:artist:fixture",
                "discography": ["all": catalogPage(items: items, total: total)],
            ]
        ]
    ])
}

private func catalogPage(items: [[String: Any]], total: Int?) -> [String: Any] {
    var page: [String: Any] = ["items": items]
    if let total { page["totalCount"] = total }
    return page
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

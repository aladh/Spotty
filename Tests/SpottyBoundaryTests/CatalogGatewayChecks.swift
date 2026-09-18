import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway

@Suite("Catalog Gateway")
@MainActor
struct CatalogGatewayTests {
    @Test(arguments: ["Album", "Playlist", "Artist"], ["GenericError", "NotFound", "UnknownUnionMember", ""])
    func errorOrMissingUnionDiscriminatorsCannotBecomeEmptyCatalogResults(kind: String, typename: String) async throws {
        let field = kind == "Album" ? "albumUnion" : kind == "Playlist" ? "playlistV2" : "artistUnion"
        let member = typename.isEmpty ? [:] : ["__typename": typename]
        let source = try JSONSerialization.data(withJSONObject: ["data": [field: member]])
        let catalog = catalogGateway { request in (source, catalogResponse(for: request, status: 200)) }
        await #expect(throws: CatalogReadFailure.compatibility) {
            switch kind {
            case "Album": _ = try await catalog.album(id: "fixture")
            case "Playlist": _ = try await catalog.playlist(id: "fixture")
            default: _ = try await catalog.artist(id: "fixture")
            }
        }
    }

    @Test(arguments: ["Album", "Playlist"])
    func missingCollectionContentsAreNotAnEmptySuccess(kind: String) async throws {
        let field = kind == "Album" ? "albumUnion" : "playlistV2"
        let source = try JSONSerialization.data(withJSONObject: ["data": [field: ["__typename": kind]]])
        let catalog = catalogGateway { request in (source, catalogResponse(for: request, status: 200)) }
        await #expect(throws: CatalogReadFailure.compatibility) {
            if kind == "Album" {
                _ = try await catalog.album(id: "fixture")
            } else {
                _ = try await catalog.playlist(id: "fixture")
            }
        }
    }

    @Test func albumCreditsComeFromTheAlbumEvenWhenTracksAreEmpty() async throws {
        let source = Data(
            #"""
            {"data":{"albumUnion":{"__typename":"Album","uri":"spotify:album:fixture","name":"Album","artists":{"items":[
              {"uri":"spotify:artist:first","profile":{"name":"First Artist"}},
              {"uri":"spotify:artist:second","profile":{"name":"Second Artist"}},
              {"uri":"spotify:playlist:invalid","profile":{"name":"Invalid"}},
              {"profile":{"name":"Unknown destination"}}
            ]},"tracksV2":{"items":[],"totalCount":0}}}}
            """#.utf8)
        let catalog: any CatalogProviding = catalogGateway { request in
            (source, catalogResponse(for: request, status: 200))
        }
        let album = try await catalog.album(id: "fixture")
        #expect(album.artists?.map(\.uri) == ["spotify:artist:first", "spotify:artist:second"])
        #expect(album.artists?.map(\.title) == ["First Artist", "Second Artist"])
        #expect(album.tracks.isEmpty)
        let old = Data(#"{"freshness":{"current":{}},"tracks":[],"releaseDate":"2026"}"#.utf8)
        #expect(try JSONDecoder().decode(CatalogAlbumSnapshot.self, from: old).artists == nil)
    }

    @Test(
        arguments: [
            (nil, nil), ("9876543210", 9_876_543_210), ("0", 0), ("-1", nil),
            ("unavailable", nil), ("99999999999999999999", nil),
        ] as [(String?, Int64?)])
    func albumPlayCountsPreserveKnownValuesWithoutInventingMissingStatistics(count: String?, expected: Int64?)
        async throws
    {
        let jsonCount = try String(decoding: JSONEncoder().encode(count), as: UTF8.self)
        let source = Data(
            """
            {"data":{"albumUnion":{"__typename":"Album","uri":"spotify:album:fixture","tracksV2":{
            "totalCount":1,"items":[{"track":{"uri":"spotify:track:fixture","name":"Fixture Track",
            "playcount":\(jsonCount)}}]}}}}
            """.utf8)
        let catalog: any CatalogProviding = catalogGateway { request in
            (source, catalogResponse(for: request, status: 200))
        }
        let album = try await catalog.album(id: "fixture")
        #expect(album.tracks.map(\.uri) == ["spotify:track:fixture"])
        #expect(album.playCounts?["spotify:track:fixture"] == expected)
    }

    @Test
    func publicCatalogContractPreservesPlayableMetadata() async throws {
        let source = try boundaryFixture(named: "search-tracks")
        let catalog: any CatalogProviding = catalogGateway { request in
            (source, catalogResponse(for: request, status: 200))
        }

        let tracks = try await catalog.searchTracks("fixture", limit: 10)

        let track = try #require(tracks.first)
        #expect(track.uri == "spotify:track:fixture")
        #expect(track.title == "Fixture Track")
        #expect(track.artist == "Fixture Artist")
        #expect(track.album == "Fixture Album")
        #expect(track.duration == 123)
        #expect(track.artists.map(\.uri) == ["spotify:artist:fixture"])
    }

    @Test
    func privateCompatibilityFailureBecomesStableCatalogFailure() async {
        let catalog: any CatalogProviding = catalogGateway { request in
            let source = Data(
                """
                {"errors":[{"message":"private-fixture-operation","extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}
                """.utf8)
            return (source, catalogResponse(for: request, status: 200))
        }

        do {
            _ = try await catalog.profile()
            Issue.record("A retired query must fail through the public catalog contract")
        } catch {
            #expect(error as? CatalogReadFailure == .compatibility)
        }
    }

    @Test
    func transportCancellationRetainsCancellationIdentity() async {
        let catalog: any CatalogProviding = catalogGateway { _ in throw CancellationError() }

        do {
            _ = try await catalog.profile()
            Issue.record("A cancelled catalog read must remain cancelled")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test
    func transportFailuresUsePublicCatalogCategories() {
        let cases: [(any Error, CatalogReadFailure)] = [
            (KeymasterSessionError.noGrant, .sessionExpired),
            (KeymasterAuthError.grantRevoked, .sessionExpired),
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.networkConnectionLost), .offline),
            (URLError(.timedOut), .timedOut),
            (PartnerAPIError.requestFailed(429), .throttled),
            (PartnerAPIError.requestFailed(503), .unavailable),
            (PartnerAPIError.graphQLErrors("private-fixture-operation"), .unavailable),
        ]
        for (source, expected) in cases {
            #expect(SpotifyCatalogGateway.failure(for: source) == expected)
        }
    }
}

private func catalogGateway(transport: @escaping SpotifyCredentials.Transport) -> SpotifyCatalogGateway {
    SpotifyCatalogGateway(
        api: PartnerAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateAccessToken: { _ in },
            invalidateClientToken: { _ in },
            transport: transport,
            retryTiming: .immediate
        )
    )
}

private func catalogResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url ?? URL(string: "https://example.invalid/")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

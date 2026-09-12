import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway

@Suite("Catalog Gateway")
@MainActor
struct CatalogGatewayTests {
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

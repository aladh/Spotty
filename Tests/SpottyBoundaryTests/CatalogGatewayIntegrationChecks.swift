import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Catalog gateway integration")
@MainActor
struct CatalogGatewayIntegrationChecks {
    @Test(
        arguments: [
            (nil, false), ("null", false), ("{}", false),
            (#"{"sections":null}"#, false), (#"{"sections":{}}"#, false),
            (#"{"sections":{"items":null}}"#, false), (#"{"sections":{"items":[]}}"#, true),
        ] as [(String?, Bool)])
    func homeRefreshDistinguishesMissingListsFromEmptyShelves(container: String?, validEmpty: Bool) async throws {
        let loaded = Data(
            #"""
            {"data":{"home":{"__typename":"HomeResponsePayload","sectionContainer":{"sections":{"items":[
              {"uri":"section:fixture","sectionItems":{"items":[{"content":{
                "__typename":"AlbumResponseWrapper","data":{"uri":"spotify:album:fixture","name":"Fixture"}
              }}]}}
            ]}}}}}
            """#.utf8)
        let field = container.map { ",\"sectionContainer\":\($0)" } ?? ""
        let refreshed = Data("{\"data\":{\"home\":{\"__typename\":\"HomeResponsePayload\"\(field)}}}".utf8)
        let requests = HarnessCounters()
        let catalog = catalogGateway { request in
            requests.record("home")
            return (requests.count("home") == 1 ? loaded : refreshed, catalogResponse(for: request, status: 200))
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = HomeLibraryStore(provider: catalog, metadata: metadata, session: session)
        await store.loadHome()
        let original = store.homeSections
        let item = try #require(original.first?.items.first)
        #expect(store.error(for: .home) == nil)

        await store.loadHome(force: true)

        #expect(store.homeSections == (validEmpty ? [] : original))
        #expect((store.error(for: .home) == nil) == validEmpty)
        #expect(metadata.knownItem(for: item.uri) == (validEmpty ? nil : item))
        if !validEmpty {
            await #expect(throws: CatalogReadFailure.compatibility) { _ = try await catalog.home() }
        }
    }

    @Test(arguments: ["Album", "Playlist"])
    func anErrorUnionCannotOverwriteTheSavedCollection(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotty-union-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Data(#"{"data":{"me":{"profile":{"uri":"spotify:user:fixture","name":"Fixture"}}}}"#.utf8)
        let savedPage: Data
        if kind == "Album" {
            savedPage = Data(
                #"""
                {"data":{"albumUnion":{"__typename":"Album","uri":"spotify:album:fixture","tracksV2":{
                  "totalCount":2,"items":[{"track":{"uri":"spotify:track:saved"}},{"track":{"uri":"spotify:track:saved"}}]
                }}}}
                """#.utf8)
        } else {
            savedPage = Data(
                #"""
                {"data":{"playlistV2":{"__typename":"Playlist","uri":"spotify:playlist:fixture","content":{
                  "totalCount":2,"items":[
                    {"uid":"first","itemV2":{"data":{"uri":"spotify:track:saved"}}},
                    {"uid":"second","itemV2":{"data":{"uri":"spotify:track:saved"}}}]
                }}}}
                """#.utf8)
        }
        let first = PersistentCatalogProvider(
            source: catalogGateway { request in
                (isProfileRequest(request) ? profile : savedPage, catalogResponse(for: request, status: 200))
            }, rootDirectory: root)
        await first.activate(accountEpoch: 1)
        _ = try await first.profile()
        if kind == "Album" {
            _ = try await first.album(id: "fixture")
        } else {
            _ = try await first.playlist(id: "fixture")
        }
        #expect(await first.retire(accountEpoch: 1, purge: false))

        let field = kind == "Album" ? "albumUnion" : "playlistV2"
        let failure = try JSONSerialization.data(withJSONObject: ["data": [field: ["__typename": "GenericError"]]])
        let reopened = PersistentCatalogProvider(
            source: catalogGateway { request in
                (isProfileRequest(request) ? profile : failure, catalogResponse(for: request, status: 200))
            }, rootDirectory: root)
        await reopened.activate(accountEpoch: 1)
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
        #expect(await reopened.retire(accountEpoch: 1, purge: true))
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

private func isProfileRequest(_ request: URLRequest) -> Bool {
    let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    return body?["operationName"] as? String == "profileAttributes"
}

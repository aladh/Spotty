import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

@Suite("Playlist Library")
struct PlaylistLibraryTests {
    @Test @MainActor
    func customOrderAndNestedFoldersSurvivePagination() async throws {
        let api = libraryAPI { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let variables = try #require(body["variables"] as? [String: Any])
            #expect(variables["order"] as? String == "Custom Order")
            #expect(variables["flatten"] as? Bool == false)
            let offset = variables["offset"] as? Int ?? 0
            let folder = variables["folderUri"] as? String
            let entries: [(String, String)]
            let total: Int
            switch (folder, offset) {
            case (nil, 0):
                entries = [("spotify:playlist:z", "Zulu"), ("spotify:user:fixture:folder:one", "Quick Lists")]
                total = 3
            case (nil, 2):
                entries = [("spotify:playlist:a", "Alpha")]
                total = 3
            case ("spotify:user:fixture:folder:one", 0):
                entries = [("spotify:playlist:child", "Child"), ("spotify:user:fixture:folder:two", "Nested")]
                total = 2
            case ("spotify:user:fixture:folder:two", 0):
                entries = [("spotify:playlist:deep", "Deep")]
                total = 1
            default:
                Issue.record("Unexpected library page")
                entries = []
                total = 0
            }
            return try libraryPage(entries, total: total, request: request)
        }
        let tree = try await api.playlistLibrary()
        #expect(tree.map(\.title) == ["Zulu", "Quick Lists", "Alpha"])
        #expect(tree.flatMap(\.playlists).map(\.title) == ["Zulu", "Child", "Deep", "Alpha"])
        #expect(tree[1].folderSummary == "1 playlist, 1 folder")
        let collapsed = PlaylistLibraryNode.visibleRows(tree, expanded: [])
        #expect(collapsed.map(\.node.title) == ["Zulu", "Quick Lists", "Alpha"])
        let expanded = PlaylistLibraryNode.visibleRows(tree, expanded: [tree[1].id, "spotify:user:fixture:folder:two"])
        #expect(expanded.map(\.depth) == [0, 0, 1, 1, 2, 0])
        #expect(expanded.map(\.node.title) == ["Zulu", "Quick Lists", "Child", "Nested", "Deep", "Alpha"])
    }

    @Test @MainActor
    func failedChildRequestFailsTheWholeTree() async throws {
        let api = libraryAPI { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let variables = try #require(body["variables"] as? [String: Any])
            if variables["folderUri"] != nil { throw URLError(.notConnectedToInternet) }
            return try libraryPage(
                [("spotify:playlist:first", "First"), ("spotify:user:fixture:folder:one", "Folder")],
                total: 2, request: request)
        }
        do {
            _ = try await api.playlistLibrary()
            Issue.record("A failed folder must not return a partially populated tree")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    @Test @MainActor
    func cyclicFoldersFailInsteadOfPublishingAnIncompleteLibrary() async {
        let api = libraryAPI { request in
            try libraryPage([("spotify:user:fixture:folder:loop", "Loop")], total: 1, request: request)
        }
        do {
            _ = try await api.playlistLibrary()
            Issue.record("Cyclic folder response must fail")
        } catch {
            #expect(error as? PartnerAPIError == .emptyPayload)
        }
    }
}

private func libraryAPI(transport: @escaping SpotifyCredentials.Transport) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" }, clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in }, invalidateClientToken: { _ in },
        transport: transport, retryTiming: .immediate
    )
}

private func libraryPage(_ entries: [(String, String)], total: Int, request: URLRequest) throws -> (Data, URLResponse) {
    let items = entries.map { uri, name in ["item": ["data": ["uri": uri, "name": name]]] }
    let payload: [String: Any] = ["data": ["me": ["libraryV3": ["items": items, "totalCount": total]]]]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (data, response)
}

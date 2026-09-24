import Foundation
import Testing
@testable import SpottyGateway

@Suite("Playlist mutation acknowledgements")
@MainActor
struct PlaylistMutationAcknowledgementTests {
    @Test(arguments: [true, false])
    func matchingResultConfirmsTheRequestedWrite(adding: Bool) async throws {
        let field = adding ? "addItemsToPlaylist" : "removeItemsFromPlaylist"
        let type = adding ? "AddItemsToPlaylistPayload" : "RemoveItemsFromPlaylistPayload"
        try await send(adding: adding, response: response([field: type]))
    }

    @Test(arguments: [
        (true, "removeItemsFromPlaylist", "RemoveItemsFromPlaylistPayload"),
        (true, "moveItemsInPlaylist", "MoveItemsInPlaylistPayload"),
        (false, "addItemsToPlaylist", "AddItemsToPlaylistPayload"),
        (false, "moveItemsInPlaylist", "MoveItemsInPlaylistPayload"),
        (true, "addItemsToPlaylist", "RemoveItemsFromPlaylistPayload"),
        (false, "removeItemsFromPlaylist", "AddItemsToPlaylistPayload"),
        (true, "addItemsToPlaylist", "MoveItemsInPlaylistPayload"),
    ])
    func anotherOperationsSuccessLeavesTheOutcomeUncertain(adding: Bool, field: String, type: String) async {
        await #expect(throws: PartnerAPIError.emptyPayload) {
            try await send(adding: adding, response: response([field: type]))
        }
    }

    @Test(
        arguments: [true, false],
        [
            "{}",
            #"{"data":null}"#,
            #"{"data":{}}"#,
            #"{"data":{"addItemsToPlaylist":null,"removeItemsFromPlaylist":null}}"#,
            #"{"data":{"addItemsToPlaylist":{},"removeItemsFromPlaylist":{}}}"#,
            #"{"data":{"addItemsToPlaylist":{"__typename":""},"removeItemsFromPlaylist":{"__typename":""}}}"#,
        ])
    func missingAcknowledgementLeavesTheOutcomeUncertain(adding: Bool, body: String) async {
        await #expect(throws: PartnerAPIError.emptyPayload) {
            try await send(adding: adding, response: body)
        }
    }

    @Test(arguments: [true, false])
    func explicitRejectionStaysRejected(adding: Bool) async {
        let field = adding ? "addItemsToPlaylist" : "removeItemsFromPlaylist"
        let operation = adding ? "addToPlaylist" : "removeFromPlaylist"
        await #expect(throws: PartnerAPIError.mutationRejected(operation)) {
            try await send(adding: adding, response: response([field: "NotFound"]))
        }
    }

    @Test(arguments: [true, false])
    func unrelatedFailureDoesNotMaskMatchingSuccess(adding: Bool) async throws {
        let fields =
            adding
            ? ["addItemsToPlaylist": "AddItemsToPlaylistPayload", "removeItemsFromPlaylist": "NotFound"]
            : ["addItemsToPlaylist": "NotFound", "removeItemsFromPlaylist": "RemoveItemsFromPlaylistPayload"]
        try await send(adding: adding, response: response(fields))
    }

    @Test(arguments: [true, false])
    func unrelatedSuccessDoesNotMaskMatchingRejection(adding: Bool) async {
        let fields =
            adding
            ? ["addItemsToPlaylist": "NotFound", "removeItemsFromPlaylist": "RemoveItemsFromPlaylistPayload"]
            : ["addItemsToPlaylist": "AddItemsToPlaylistPayload", "removeItemsFromPlaylist": "NotFound"]
        let operation = adding ? "addToPlaylist" : "removeFromPlaylist"
        await #expect(throws: PartnerAPIError.mutationRejected(operation)) {
            try await send(adding: adding, response: response(fields))
        }
    }

    private func response(_ fields: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": fields.mapValues { ["__typename": $0, "message": "SPOTTY_PRIVACY_SENTINEL"] }
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func send(adding: Bool, response body: String) async throws {
        let api = PartnerAPI(
            accessToken: { "fixture-access" }, clientToken: { "fixture-client" },
            invalidateAccessToken: { _ in Issue.record("Unexpected credential retry") },
            invalidateClientToken: { _ in Issue.record("Unexpected credential retry") },
            transport: { request in
                let response = try #require(
                    HTTPURLResponse(url: PartnerAPI.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
                let requestBody = try #require(request.httpBody)
                let envelope = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
                #expect(envelope["operationName"] as? String == (adding ? "addToPlaylist" : "removeFromPlaylist"))
                return (Data(body.utf8), response)
            },
            retryTiming: .init(
                now: { Date(timeIntervalSince1970: 0) },
                sleep: { _ in Issue.record("Unexpected mutation replay") }, unitJitter: { 0 })
        )
        if adding {
            try await api.addToPlaylist(playlistId: "fixture", trackUris: ["spotify:track:fixture"])
        } else {
            try await api.removeFromPlaylist(playlistId: "fixture", uids: ["occurrence"])
        }
    }
}

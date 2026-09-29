import Foundation
import SpottyTestSupport
import Testing
@testable import SpottyGateway

@Suite("Pathfinder response decoding")
struct PathfinderResponseTests {
    private struct Payload: Decodable, Sendable {
        struct Content: Decodable, Sendable { let name: String }
        let data: Content
    }

    @Test(
        arguments: [
            nil, "null", "[]", "{}", "\"unrecognized\"", "[null]", "[{\"message\":42}]",
            "[{\"extensions\":3}]", "[{\"extensions\":{\"code\":7}}]",
            "[{\"message\":\"persistedquerynotfound\"},{\"message\":false}]",
        ] as [String?])
    func absentEmptyOrMalformedErrorsLeavePayloadDecodingUnchanged(errors: String?) throws {
        let field = errors.map { "\"errors\":\($0)," } ?? ""
        let body = Data("{\(field)\"data\":{\"name\":\"Fixture\"}}".utf8)
        let value: Payload = try PartnerAPI().decode(body, operation: .profileAttributes)
        #expect(value.data.name == "Fixture")
    }

    @Test(arguments: [
        ("[{}]", false),
        ("[{\"message\":\"private-fixture-message\"}]", false),
        ("[{\"extensions\":{\"code\":\"PERSISTED_QUERY_NOT_FOUND\"}}]", true),
        ("[{\"extensions\":{\"code\":\"persisted_query_not_found\"}}]", false),
        ("[{\"message\":\"private-fixture PeRsIsTeDqUeRyNoTfOuNd detail\"}]", true),
        ("[{}, {\"extensions\":{\"code\":\"PERSISTED_QUERY_NOT_FOUND\"}}]", true),
    ])
    func recognizedErrorsPrecedeMalformedPayloadAndOmitServerText(errors: String, retired: Bool) throws {
        let body = Data("{\"errors\":\(errors),\"data\":false}".utf8)
        let expected: PartnerAPIError =
            retired
            ? .persistedQueryNotFound(PathfinderOperation.profileAttributes.name)
            : .graphQLErrors(PathfinderOperation.profileAttributes.name)
        #expect(throws: expected) {
            let _: Payload = try PartnerAPI().decode(body, operation: .profileAttributes)
        }
        #expect(expected.localizedDescription.contains("private-fixture") == false)
    }

    @Test(arguments: [false, true], ["[]", "[{\"message\":42}]", "[{\"message\":\"fixture-error\"}]"])
    func mutationAcknowledgementStillRequiresNoRecognizedGraphQLError(removing: Bool, errors: String) async throws {
        let field = removing ? "removeItemsFromPlaylist" : "addItemsToPlaylist"
        let success = removing ? "RemoveItemsFromPlaylistPayload" : "AddItemsToPlaylistPayload"
        let calls = HarnessCounters()
        let api = responseAPI(
            body: "{\"errors\":\(errors),\"data\":{\"\(field)\":{\"__typename\":\"\(success)\"}}}", calls: calls)
        let mutate = {
            if removing {
                try await api.removeFromPlaylist(playlistId: "fixture", uids: ["fixture-occurrence"])
            } else {
                try await api.addToPlaylist(playlistId: "fixture", trackUris: ["spotify:track:fixture"])
            }
        }
        if errors.contains("fixture-error") {
            let operation: PathfinderOperation = removing ? .removeFromPlaylist : .addToPlaylist
            await #expect(throws: PartnerAPIError.graphQLErrors(operation.name)) { try await mutate() }
        } else {
            try await mutate()
        }
        #expect(calls.count("transport") == 1)
    }

    @Test
    func httpFailurePrecedesGraphQLErrorClassification() async {
        let calls = HarnessCounters()
        let api = responseAPI(
            body: #"{"errors":[{"extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}"#,
            status: 503, calls: calls)
        await #expect(throws: PartnerAPIError.requestFailed(503)) {
            try await api.addToPlaylist(playlistId: "fixture", trackUris: ["spotify:track:fixture"])
        }
        #expect(calls.count("transport") == 1)
    }

    @Test
    func malformedPayloadKeepsItsOriginalCodingPath() throws {
        let body = Data(#"{"errors":null,"data":{"name":42}}"#.utf8)
        do {
            let _: Payload = try PartnerAPI().decode(body, operation: .profileAttributes)
            Issue.record("Malformed payload must fail decoding")
        } catch DecodingError.typeMismatch(let type, let context) {
            let isString = type == String.self
            #expect(isString)
            #expect(context.codingPath.map(\.stringValue) == ["data", "name"])
        }
    }

    @Test
    func invalidJSONCannotBecomeARecognizedGraphQLFailure() throws {
        let body = Data(#"{"errors":[{"message":"persistedquerynotfound"}],"data":?}"#.utf8)
        #expect(throws: DecodingError.self) {
            let _: Payload = try PartnerAPI().decode(body, operation: .profileAttributes)
        }
    }

    @Test
    func rootValuesKeepFoundationDecodingBehavior() throws {
        let api = PartnerAPI()
        let array: [Int] = try api.decode(Data("[1,2,3]".utf8), operation: .profileAttributes)
        let scalar: Bool = try api.decode(Data("true".utf8), operation: .profileAttributes)
        let missing: Int? = try api.decode(Data("null".utf8), operation: .profileAttributes)
        let bytes: Data = try api.decode(Data(#""AQID""#.utf8), operation: .profileAttributes)
        let url: URL = try api.decode(Data(#""https://example.invalid/fixture""#.utf8), operation: .profileAttributes)
        let date: Date = try api.decode(Data("12.25".utf8), operation: .profileAttributes)
        let decimal: Decimal = try api.decode(Data("12.25".utf8), operation: .profileAttributes)
        #expect(array == [1, 2, 3])
        #expect(scalar)
        #expect(missing == nil)
        #expect(bytes == Data([1, 2, 3]))
        #expect(url.absoluteString == "https://example.invalid/fixture")
        #expect(decimal == Decimal(string: "12.25"))
        #expect(date.timeIntervalSinceReferenceDate == 12.25)
    }

    private func responseAPI(body: String, status: Int = 200, calls: HarnessCounters) -> PartnerAPI {
        PartnerAPI(
            accessToken: { "fixture-access" }, clientToken: { "fixture-client" },
            invalidateAccessToken: { _ in Issue.record("Unexpected bearer invalidation") },
            invalidateClientToken: { _ in Issue.record("Unexpected client invalidation") },
            transport: { request in
                calls.record("transport")
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            }, retryTiming: .immediate)
    }

}

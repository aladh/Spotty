import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private let privacySentinel = "SPOTTY_PRIVACY_SENTINEL_api-body_d81f"

@MainActor
private func omitSentinel(_ label: String, _ text: String?) {
    #expect((text) != nil, "\(label)")
    #expect((text?.contains(privacySentinel) != true) == true, "\(label) omits the response body")
}

private func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func rejectedTransport(status: Int, body: Data) -> SpotifyCredentials.Transport {
    { @Sendable request in
        (body, httpResponse(url: request.url ?? URL(string: "https://example.invalid/")!, status: status))
    }
}

private func partnerAPI(status: Int, body: String) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateClientToken: { _ in },
        transport: rejectedTransport(status: status, body: Data(body.utf8)),
        retryTiming: .immediate
    )
}

@MainActor
private func expectFailure<Failure: Error & Equatable & LocalizedError>(
    _ label: String,
    _ expected: Failure,
    description: String,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as Failure {
        #expect((error) == (expected), "\(label) keeps typed case")
        #expect((error.errorDescription ?? "") == (description), "\(label) uses a stable category")
        omitSentinel("\(label) LocalizedError", error.errorDescription)
    } catch {
        #expect((false) == true, "\(label) throws \(Failure.self), got \(error)")
    }
}

@Suite("Privacy Sanitization")
struct PrivacySanitizationTests {
    @Test
    @MainActor
    func testPrivacySanitization() async {
        do {
            let clientToken = ClientTokenError.requestFailed(401)
            #expect((clientToken) == (.requestFailed(401)), "client-token failures keep HTTP status")
            #expect(
                (clientToken.errorDescription ?? "") == ("Could not obtain a Spotify client token (HTTP 401)"),
                "client-token failures use a stable HTTP category")
            omitSentinel("client-token LocalizedError", clientToken.errorDescription)

            await expectFailure(
                "Partner HTTP",
                PartnerAPIError.requestFailed(503),
                description: "Spotify rejected the request (HTTP 503)",
                perform: { _ = try await partnerAPI(status: 503, body: "{\"error\":\"\(privacySentinel)\"}").profile() }
            )

            await expectFailure(
                "Partner GraphQL",
                PartnerAPIError.graphQLErrors("profileAttributes"),
                description: "Spotify returned a GraphQL error for profileAttributes",
                perform: {
                    _ = try await partnerAPI(
                        status: 200,
                        body: """
                            {"errors":[{"message":"\(privacySentinel)","extensions":{"code":"INTERNAL"}}]}
                            """
                    ).profile()
                }
            )

            await expectFailure(
                "retired persisted query",
                PartnerAPIError.persistedQueryNotFound("profileAttributes"),
                description: "Spotify no longer recognises the stored query for profileAttributes",
                perform: {
                    _ = try await partnerAPI(
                        status: 200,
                        body: """
                            {"errors":[{"message":"\(privacySentinel) persistedQueryNotFound","extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}
                            """
                    ).profile()
                }
            )

            #expect(
                (PartnerAPIError.pagination(.pageLimitReached)) == (.pagination(.pageLimitReached)),
                "pagination cap failures keep a stable category")
            #expect(
                (PartnerAPIError.pagination(.pageLimitReached).errorDescription ?? "")
                    == ("Spotify pagination exceeded the request limit"), "pagination cap failures omit payloads")
            omitSentinel(
                "pagination cap LocalizedError",
                PartnerAPIError.pagination(.pageLimitReached).errorDescription
            )
            #expect(
                (PartnerAPIError.pagination(.offsetDidNotAdvance).errorDescription ?? "")
                    == ("Spotify pagination did not advance"), "pagination non-progress failures omit payloads")
            omitSentinel(
                "pagination non-progress LocalizedError",
                PartnerAPIError.pagination(.offsetDidNotAdvance).errorDescription
            )

            let connect = SpotifyConnectAPI(
                accessToken: { "fixture-access" },
                clientToken: { "fixture-client" },
                invalidateClientToken: { _ in },
                transport: rejectedTransport(status: 502, body: Data(privacySentinel.utf8)),
                retryTiming: .immediate
            )
            await expectFailure(
                "Connect",
                SpotifyConnectAPIError.requestFailed(502),
                description: "Spotify rejected the command (HTTP 502)",
                perform: { try await connect.send(.pause, from: "source", to: "target") }
            )

            let queue = SpotifyWebPlayerAPI(
                accessToken: { "fixture-access" },
                transport: rejectedTransport(
                    status: 429,
                    body: Data("{\"error\":\"\(privacySentinel)\"}".utf8)
                ),
                retryTiming: .immediate
            )
            await expectFailure(
                "queue Web API",
                SpotifyWebPlayerAPIError.requestFailed(429),
                description: "Spotify rejected the queue request (HTTP 429)",
                perform: { _ = try await queue.queue() }
            )
            do {
                _ = try await SpotifyWebPlayerAPI(
                    accessToken: { "fixture-access" },
                    transport: rejectedTransport(status: 403, body: Data(privacySentinel.utf8)),
                    retryTiming: .immediate
                ).queue()
                #expect((false) == true, "forbidden queue failures throw")
            } catch let error as SpotifyWebPlayerAPIError {
                #expect((error.statusCode ?? -1) == (403), "401/403 capability still reads status")
                omitSentinel("forbidden queue LocalizedError", error.errorDescription)
            } catch {
                #expect((false) == true, "forbidden queue failures throw SpotifyWebPlayerAPIError")
            }

            let attributes = TrackAttributesAPI(
                accessToken: { "fixture-access" },
                clientToken: { "fixture-client" },
                invalidateClientToken: { _ in },
                transport: rejectedTransport(status: 500, body: Data(privacySentinel.utf8)),
                retryTiming: .immediate
            )
            await expectFailure(
                "track-attribute",
                TrackAttributesAPIError.requestFailed(500),
                description: "Spotify rejected the attribute request (HTTP 500)",
                perform: {
                    _ = try await attributes.attributes(for: ["spotify:track:6rqhFgbbKwnb9MLmUQDhG6"])
                }
            )

            let failedPhase = PlaybackSessionPhase.failed(
                PartnerAPIError.requestFailed(503).errorDescription ?? privacySentinel
            )
            #expect((sessionPhaseLogLabel(failedPhase)) == ("failed"), "failed session phases log a stable category")
            omitSentinel("session phase public log label", sessionPhaseLogLabel(failedPhase))
            let publicLog =
                "Session phase changed: \(sessionPhaseLogLabel(.ready)) -> \(sessionPhaseLogLabel(failedPhase)); epoch=8"
            omitSentinel("public session phase log", publicLog)
            #expect((publicLog.contains("epoch=8")) == true, "session phase logs keep epoch")
        }
    }
}

import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

private let fixtureURI = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
private let otherFixtureURI = "spotify:track:0000000000000000000001"

private let metadataBody = Data(
    #"{"name":"Fixture Title","artist":[{"name":"First","gid":"00000000000000000000000000000001"},{"name":"Second","gid":"0000000000000000000000000000003e"}],"album":{"cover_group":{"image":[{"file_id":"small","width":64,"height":64},{"file_id":"large","width":300,"height":300}]}},"duration":123000}"#
        .utf8
)

@Suite("Connect Metadata Transport")
struct ConnectMetadataTransportTests {
    @Test
    @MainActor
    func testConnectMetadataTransport() async {
        do {
            let transport = RecordingConnectTransport(steps: [.http(status: 200, body: metadataBody)])
            let metadata: SpotifyConnectTrackMetadata?
            do {
                metadata = try await connectAPI(transport: transport.send).trackMetadata(for: fixtureURI)
            } catch {
                #expect((false) == true, "successful metadata throws \(error)")
                metadata = nil
            }

            #expect((metadata?.title) == ("Fixture Title"), "title is decoded")
            #expect((metadata?.artist) == ("First, Second"), "artists are joined")
            #expect(
                metadata?.artists.map(\.uri) == [
                    "spotify:artist:0000000000000000000001", "spotify:artist:0000000000000000000010",
                ])
            #expect(metadata?.artists.map(\.title) == ["First", "Second"])
            #expect((metadata?.duration) == (123.0), "duration is milliseconds")
            #expect(
                (metadata?.artworkURL) == (URL(string: "https://i.scdn.co/image/large")),
                "largest cover becomes the artwork URL")
            #expect((metadata?.uri) == (fixtureURI), "the requested URI is preserved")
            #expect((transport.methods) == (["GET"]), "successful metadata is one GET")
            #expect((transport.callCount) == (1), "successful metadata is one attempt")
            #expect(
                (transport.paths.allSatisfy { path in
                    path.hasPrefix("/metadata/4/track/") && path.contains("market=from_token")
                }) == true, "the GET is the metadata track path")
            #expect((transport.authorizationTokens) == (["fixture-access"]), "the GET carries the bearer")
            #expect((transport.clientTokens) == (["fixture-client"]), "the GET carries the client token")
            #expect((transport.appPlatforms) == ([SpotifyCredentials.appPlatform]), "the GET is desktop-client signed")
            #expect((transport.origins) == ([SpotifyCredentials.origin]), "the GET carries the xpui origin")
        }

        do {
            let transport = RecordingConnectTransport(steps: [
                .http(status: 200, body: metadataBody),
                .http(status: 200, body: metadataBody),
            ])
            let api = connectAPI(transport: transport.send)
            async let first = api.trackMetadata(for: fixtureURI)
            async let second = api.trackMetadata(for: otherFixtureURI)
            let titles = [(try? await first)?.title, (try? await second)?.title]

            #expect((titles.allSatisfy { $0 == "Fixture Title" }) == true, "both concurrent fetches succeed")
            #expect((transport.methods) == (["GET", "GET"]), "two tracks are two GETs")
            #expect((transport.callCount) == (2), "two tracks are two attempts")
            #expect((Set(transport.paths).count == 2) == true, "distinct track URLs stay distinct")
        }

        do {
            let budget = SpotifyTransientRetry.maximumAttempts
            let exhausted = RecordingConnectTransport(
                steps: Array(repeating: .http(status: 502, body: Data()), count: budget)
            )
            await expectThrown(
                "HTTP 502 stays requestFailed after the budget",
                SpotifyConnectAPIError.requestFailed(502)
            ) {
                _ = try await connectAPI(transport: exhausted.send).trackMetadata(for: fixtureURI)
            }
            #expect((exhausted.methods) == (Array(repeating: "GET", count: budget)), "every replayable attempt is GET")
        }

        do {
            let unused = RecordingConnectTransport(steps: [.http(status: 200, body: metadataBody)])
            await expectThrown(
                "an invalid track URI never hits the wire",
                SpotifyConnectAPIError.invalidTrackURI
            ) {
                _ = try await connectAPI(transport: unused.send).trackMetadata(for: "spotify:album:not-a-track")
            }
            #expect((unused.callCount) == (0), "invalid URI is zero attempts")

            let malformed = RecordingConnectTransport(steps: [.http(status: 200, body: Data("{}".utf8))])
            await expectThrown(
                "an empty JSON object is malformed",
                SpotifyConnectAPIError.malformedResponse
            ) {
                _ = try await connectAPI(transport: malformed.send).trackMetadata(for: fixtureURI)
            }
            #expect((malformed.methods) == (["GET"]), "malformed JSON is one GET")

            let emptyTitle = RecordingConnectTransport(steps: [
                .http(status: 200, body: Data(#"{"name":""}"#.utf8))
            ])
            await expectThrown(
                "an empty title is malformed",
                SpotifyConnectAPIError.malformedResponse
            ) {
                _ = try await connectAPI(transport: emptyTitle.send).trackMetadata(for: fixtureURI)
            }
            #expect((emptyTitle.methods) == (["GET"]), "empty title is one GET")
        }
    }
}

private func connectAPI(transport: @escaping SpotifyCredentials.Transport) -> SpotifyConnectAPI {
    SpotifyConnectAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: .immediate
    )
}

@MainActor
private func expectThrown<Failure: Error & Equatable>(
    _ label: String,
    _ expected: Failure,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as Failure {
        #expect((error) == (expected), "\(label)")
    } catch {
        #expect((false) == true, "\(label) throws \(Failure.self), got \(error)")
    }
}

private enum ConnectTransportStep {
    case http(status: Int, body: Data = Data(), headers: [String: String] = [:])
}

private final class RecordingConnectTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [ConnectTransportStep]
    private var index = 0
    private var recordedMethods: [String] = []
    private var recordedPaths: [String] = []
    private var authorizations: [String] = []
    private var clients: [String] = []
    private var platforms: [String] = []
    private var recordedOrigins: [String] = []

    init(steps: [ConnectTransportStep]) {
        self.steps = steps
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var methods: [String] {
        lock.withLock { recordedMethods }
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    var authorizationTokens: [String] {
        lock.withLock { authorizations }
    }

    var clientTokens: [String] {
        lock.withLock { clients }
    }

    var appPlatforms: [String] {
        lock.withLock { platforms }
    }

    var origins: [String] {
        lock.withLock { recordedOrigins }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recordedMethods.append(request.httpMethod ?? "GET")
        if let url = request.url {
            recordedPaths.append(url.path + (url.query.map { "?\($0)" } ?? ""))
        }
        if let access = SpotifyCredentials.accessTokenCarried(by: request) {
            authorizations.append(access)
        }
        if let client = request.value(forHTTPHeaderField: "Client-Token") {
            clients.append(client)
        }
        if let platform = request.value(forHTTPHeaderField: "App-Platform") {
            platforms.append(platform)
        }
        if let origin = request.value(forHTTPHeaderField: "Origin") {
            recordedOrigins.append(origin)
        }
        let url = request.url ?? URL(string: "https://example.invalid/")!
        guard index < steps.count else {
            index += 1
            return (
                Data(),
                HTTPURLResponse(url: url, statusCode: 598, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let step = steps[index]
        index += 1
        switch step {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        }
    }
}

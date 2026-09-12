import Foundation
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Catalog Mutation Admission")
@MainActor
struct CatalogMutationAdmissionTests {
    @Test(arguments: [false, true])
    func retirementFencesAValidatedMutationBeforeCredentialsAreCleared(removal: Bool) async throws {
        let transport = PlaylistAdmissionTransport()
        let accesses = HarnessCounters()
        let credentials = HarnessClock.parked()
        let gateway = SpotifyCatalogGateway(
            api: mutationAdmissionAPI(transport: transport.send) {
                accesses.record("token")
                if accesses.count("token") == 3 { try await credentials.sleep(seconds: 1) }
                return "still-valid-original-grant"
            })
        let shutdown = HarnessEngineGate(result: .ok)
        defer { shutdown.release(); credentials.releaseAll() }
        let engine = HarnessEngine()
        engine.onShutdown = { shutdown.enter() }
        let account = HarnessAccount(hasGrant: true)
        let environment = HarnessEnvironment.make(engine: engine, account: account, playlistMutations: gateway)
        let runtime = SessionRuntimeActor.sync {
            let runtime = PlaybackSessionRuntime(environment: environment)
            runtime.accountStore.publishPhase(.ready)
            return runtime
        }
        let context = PlaylistMutationContext(accountEpoch: 1)
        let mutation = Task {
            do {
                if removal {
                    try await environment.playlistMutations.removeFromPlaylist(
                        playlistId: "owned", uids: ["known"], context: context)
                } else {
                    try await environment.playlistMutations.addToPlaylist(
                        playlistId: "owned", trackUris: ["spotify:track:new"], context: context)
                }
                Issue.record("Retirement must fence an undispatched playlist mutation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await expectEventually { credentials.waiterCount == 1 }
        #expect(await transport.operations.contains("profileAttributes"))
        #expect(await transport.operations.contains("fetchPlaylist"))
        let retirement = Task { await runtime.logout() }
        await expectEventually { shutdown.hasStarted }
        #expect(account.clearCount == 0, "The original grant still exists while engine teardown is blocked")
        credentials.releaseAll()
        await mutation.value
        #expect(await transport.mutations.isEmpty)
        shutdown.release()
        await retirement.value

        SessionRuntimeActor.sync { runtime.accountStore.publishPhase(.ready) }
        let readsBefore = await transport.operations.count
        do {
            try await environment.playlistMutations.addToPlaylist(
                playlistId: "owned", trackUris: ["spotify:track:late"], context: context)
            Issue.record("A deferred old-account action must not acquire the replacement account")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await transport.operations.count == readsBefore)
    }

    @Test
    func removalValidatesTheCompletePlaylistBeforeDispatch() async throws {
        let transport = PlaylistAdmissionTransport(uids: ["first", "last"], pageSize: 1)
        let gateway = SpotifyCatalogGateway(api: mutationAdmissionAPI(transport: transport.send))

        try await gateway.removeFromPlaylist(playlistId: "owned", uids: ["last"])

        let operations = await transport.operations
        #expect(operations.filter { $0 == "profileAttributes" }.count == 1)
        #expect(operations.filter { $0 == "fetchPlaylist" }.count == 2)
        #expect(operations.last == "removeFromPlaylist")
        #expect(await transport.playlistOffsets == [0, 1])
        #expect(await transport.removedUIDs == [["last"]])
    }

    @Test(arguments: [false, true])
    func aWireMutationRefusalBecomesATypedRejectionWithoutReplay(removal: Bool) async {
        let transport = PlaylistAdmissionTransport(rejectMutations: true)
        let gateway = SpotifyCatalogGateway(api: mutationAdmissionAPI(transport: transport.send))
        await expectRejectedMutation {
            if removal {
                try await gateway.removeFromPlaylist(playlistId: "owned", uids: ["known"])
            } else {
                try await gateway.addToPlaylist(playlistId: "owned", trackUris: ["spotify:track:added"])
            }
        }
        #expect(await transport.mutations.count == 1)
    }

    @Test(arguments: [false, true])
    func aForeignOwnerCannotDispatchAPlaylistWrite(removal: Bool) async {
        let transport = PlaylistAdmissionTransport(ownerURI: "spotify:user:someone-else")
        let gateway = SpotifyCatalogGateway(api: mutationAdmissionAPI(transport: transport.send))

        await expectRejectedMutation {
            if removal {
                try await gateway.removeFromPlaylist(playlistId: "owned", uids: ["known"])
            } else {
                try await gateway.addToPlaylist(playlistId: "owned", trackUris: ["spotify:track:added"])
            }
        }

        #expect(await transport.mutations.isEmpty)
        #expect(await transport.operations.contains("profileAttributes"))
        #expect(await transport.operations.contains("fetchPlaylist"))
    }

    @Test
    func everyWriteRevalidatesTheCurrentProfile() async throws {
        let transport = PlaylistAdmissionTransport()
        let gateway = SpotifyCatalogGateway(api: mutationAdmissionAPI(transport: transport.send))
        try await gateway.addToPlaylist(playlistId: "owned", trackUris: ["spotify:track:first"])
        await transport.setProfileURI("spotify:user:replacement")

        await expectRejectedMutation {
            try await gateway.addToPlaylist(playlistId: "owned", trackUris: ["spotify:track:second"])
        }

        #expect(await transport.mutations == ["addToPlaylist"])
        #expect(await transport.operations.filter { $0 == "profileAttributes" }.count == 2)
    }

    @Test(arguments: [0, 1, 2])
    func removalRejectsUnknownOrAmbiguousOccurrences(scenario: Int) async {
        let listed = scenario == 2 ? ["known", "known"] : ["known"]
        let requested = scenario == 0 ? ["unknown"] : scenario == 1 ? ["known", "known"] : ["known"]
        let transport = PlaylistAdmissionTransport(uids: listed, pageSize: 1)
        let gateway = SpotifyCatalogGateway(api: mutationAdmissionAPI(transport: transport.send))

        await expectRejectedMutation {
            try await gateway.removeFromPlaylist(playlistId: "owned", uids: requested)
        }

        #expect(await transport.mutations.isEmpty)
    }

    @Test
    func replacementCredentialsCannotAuthorizeAPreviouslyValidatedMutation() async throws {
        let session = KeymasterSession(
            store: MutationGrantStore(),
            refresher: { _ in throw HarnessFailure.unavailable },
            cookieCleanup: {}
        )
        try await session.adopt(HarnessFixtures.tokens())
        let transport = PlaylistAdmissionTransport()
        let accesses = HarnessCounters()
        let gateway = SpotifyCatalogGateway(
            api: mutationAdmissionAPI(transport: transport.send),
            mutationAPI: { _ in
                let generation = await session.credentialGeneration
                return mutationAdmissionAPI(transport: transport.send) {
                    accesses.record("token")
                    // Profile and playlist validation have each obtained their original grant;
                    // replace it at the mutation's next credential acquisition.
                    if accesses.count("token") == 3 {
                        try await session.adopt(HarnessFixtures.tokens(accessToken: "replacement-access"))
                    }
                    return try await session.accessToken(expectedGeneration: generation)
                }
            }
        )

        do {
            try await gateway.removeFromPlaylist(playlistId: "owned", uids: ["known"])
            Issue.record("An account replacement must fence a previously validated mutation")
        } catch {
            #expect(error as? PlaylistMutationFailure == .failed)
        }

        #expect(accesses.count("token") == 3)
        #expect(await transport.mutations.isEmpty)
        #expect(try await session.accessToken() == "replacement-access")
    }

    @Test
    func generationScopedCredentialsRejectAReplacementGrant() async throws {
        let session = KeymasterSession(
            store: MutationGrantStore(),
            refresher: { _ in throw HarnessFailure.unavailable },
            cookieCleanup: {}
        )
        try await session.adopt(HarnessFixtures.tokens(accessToken: "initial-access"))
        let originalGeneration = await session.credentialGeneration
        #expect(try await session.accessToken(expectedGeneration: originalGeneration) == "initial-access")
        try await session.adopt(HarnessFixtures.tokens(accessToken: "replacement-access"))

        for refresh in [false, true] {
            do {
                if refresh {
                    _ = try await session.refreshIgnoringExpiry(
                        rejected: "initial-access", expectedGeneration: originalGeneration)
                } else {
                    _ = try await session.accessToken(expectedGeneration: originalGeneration)
                }
                Issue.record("A scoped credential read must reject a replacement account generation")
            } catch {
                #expect(error as? KeymasterSessionError == .noGrant)
            }
        }
        let replacementGeneration = await session.credentialGeneration
        #expect(replacementGeneration != originalGeneration)
        #expect(try await session.accessToken(expectedGeneration: replacementGeneration) == "replacement-access")
    }
}

@MainActor
private func expectRejectedMutation(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("An unverified playlist mutation must not dispatch")
    } catch {
        #expect(error as? PlaylistMutationFailure == .rejected)
    }
}

private func mutationAdmissionAPI(
    transport: @escaping SpotifyCredentials.Transport,
    accessToken: @escaping @Sendable () async throws -> String = { "fixture-access" }
) -> PartnerAPI {
    PartnerAPI(
        accessToken: accessToken,
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: .immediate
    )
}

/// Scripts the gateway's private read/write transport, which the domain catalog harness cannot expose.
private actor PlaylistAdmissionTransport {
    private struct Request: Decodable {
        struct Variables: Decodable {
            let offset: Int?
            let uids: [String]?
        }
        let operationName: String
        let variables: Variables
    }

    private var profileURI = "spotify:user:listener"
    private let ownerURI: String
    private let uids: [String]
    private let pageSize: Int
    private let rejectMutations: Bool
    private(set) var operations: [String] = []
    private(set) var mutations: [String] = []
    private(set) var playlistOffsets: [Int] = []
    private(set) var removedUIDs: [[String]] = []

    init(
        ownerURI: String = "spotify:user:listener", uids: [String] = ["known"], pageSize: Int = .max,
        rejectMutations: Bool = false
    ) {
        self.ownerURI = ownerURI
        self.uids = uids
        self.pageSize = pageSize
        self.rejectMutations = rejectMutations
    }

    func setProfileURI(_ uri: String) { profileURI = uri }

    nonisolated var send: SpotifyCredentials.Transport {
        { [self] request in try await response(for: request) }
    }

    private func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let probe = try JSONDecoder().decode(Request.self, from: request.httpBody ?? Data())
        operations.append(probe.operationName)
        let payload: [String: Any]
        switch probe.operationName {
        case "profileAttributes":
            payload = ["data": ["me": ["profile": ["uri": profileURI, "name": "Fixture Listener"]]]]
        case "fetchPlaylist":
            let offset = probe.variables.offset ?? 0
            playlistOffsets.append(offset)
            let entries = uids.dropFirst(offset).prefix(pageSize).map { uid in
                ["uid": uid, "itemV2": ["data": ["uri": "spotify:track:\(uid)", "name": uid]]] as [String: Any]
            }
            payload = [
                "data": [
                    "playlistV2": [
                        "uri": "spotify:playlist:owned", "name": "Fixture Playlist",
                        "ownerV2": ["data": ["uri": ownerURI, "name": "Fixture Owner"]],
                        "content": ["items": entries, "totalCount": uids.count],
                    ]
                ]
            ]
        case "addToPlaylist":
            mutations.append(probe.operationName)
            payload = [
                "data": [
                    "addItemsToPlaylist": ["__typename": rejectMutations ? "NotFound" : "AddItemsToPlaylistPayload"]
                ]
            ]
        case "removeFromPlaylist":
            mutations.append(probe.operationName)
            removedUIDs.append(probe.variables.uids ?? [])
            payload = [
                "data": [
                    "removeItemsFromPlaylist": [
                        "__typename": rejectMutations ? "NotFound" : "RemoveItemsFromPlaylistPayload"
                    ]
                ]
            ]
        default:
            throw HarnessFailure.unavailable
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid/")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

/// Isolated credential persistence for the generation fence; no account or catalog fake owns this port.
private final class MutationGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: KeymasterTokens?

    func loadResult() -> KeymasterGrantLoadResult {
        lock.withLock { tokens.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws { lock.withLock { self.tokens = tokens } }
    func clear() { lock.withLock { tokens = nil } }
}

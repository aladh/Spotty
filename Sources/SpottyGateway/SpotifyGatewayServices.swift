import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// An opaque notification identity. Only its credential owner can say whether it still applies;
/// replacing or clearing the grant invalidates notifications already queued for delivery.
package struct AccountGrantRevocation: Equatable, Sendable {
    private let id = UUID()
    package init() {}
}

/// Account primitives are package-only: desktop contracts contain no credentials or auth implementation.
package protocol AccountSession: Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens
    func hasGrant() async -> Bool
    func grantState() async -> KeymasterGrantState
    func reauthenticationRequired() async -> Bool
    func markReauthenticationRequired() async
    func accessToken() async throws -> String
    func adopt(_ tokens: KeymasterTokens) async throws
    func clear() async -> Bool
    func revocations() -> AsyncStream<AccountGrantRevocation>
    /// Reads notification validity only; does not refresh credentials or access persistence.
    func isCurrent(_ revocation: AccountGrantRevocation) async -> Bool
}

extension AccountSession {
    package func grantState() async -> KeymasterGrantState { await hasGrant() ? .available : .absent }
    package func reauthenticationRequired() async -> Bool { false }
    package func markReauthenticationRequired() async {}
}

struct LiveAccountSession: AccountSession {
    private let session: KeymasterSession
    private let openAuthorizationURL: @Sendable (URL) async -> Bool

    init(
        session: KeymasterSession,
        openAuthorizationURL: @escaping @Sendable (URL) async -> Bool
    ) {
        self.session = session
        self.openAuthorizationURL = openAuthorizationURL
    }
    func authorizeInteractively() async throws -> KeymasterTokens {
        try await KeymasterAuth.authorize(openInBrowser: openAuthorizationURL)
    }
    func hasGrant() async -> Bool { await session.hasGrant }
    func grantState() async -> KeymasterGrantState { await session.retryGrantState() }
    func reauthenticationRequired() async -> Bool { await session.reauthenticationRequired() }
    func markReauthenticationRequired() async { await session.markReauthenticationRequired() }
    func accessToken() async throws -> String { try await session.accessToken() }
    func adopt(_ tokens: KeymasterTokens) async throws { try await session.adopt(tokens) }
    func clear() async -> Bool { await session.clear() }
    func revocations() -> AsyncStream<AccountGrantRevocation> { session.grantRevocations() }
    func isCurrent(_ revocation: AccountGrantRevocation) async -> Bool { await session.isCurrent(revocation) }
}

extension SpotifyConnectAPI: RemotePlaybackClient {}
extension SpotifyWebPlayerAPI: WebQueueClient {}

/// Playback commands retain their own dispatch lane; catalog synchronization must not park pause
/// or seek behind a page walk. Only the metadata read participates in shared enrichment admission.
private struct LiveRemotePlaybackClient: RemotePlaybackClient {
    let commands = SpotifyConnectAPI()
    let metadata: SpotifyConnectAPI

    func send(_ command: SpotifyConnectCommand, from sourceID: String, to targetID: String) async throws {
        try await commands.send(command, from: sourceID, to: targetID)
    }
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        try await metadata.trackMetadata(for: uri)
    }
}

/// Each attempt owns one permit, including folder pages. Credential refresh and retry cooldown
/// do not occupy request capacity, so interactive reads can pass queued enrichment.
nonisolated enum SpotifyGatewayTransport {
    static func admitted(
        priority: SpotifyRequestAdmission.Priority,
        admission: SpotifyRequestAdmission = .shared,
        transport: @escaping SpotifyCredentials.Transport = { try await URLSession.shared.data(for: $0) }
    ) -> SpotifyCredentials.Transport {
        { request in
            try await admission.withPermit(priority: priority) { try await transport(request) }
        }
    }
}

/// Production composition can obtain typed ports; private HTTP clients cannot escape this module.
package struct SpotifyGatewayServices: Sendable {
    package let remote: any RemotePlaybackClient
    package let webQueue: any WebQueueClient
    package let account: any AccountSession
    package let catalog: any CatalogProviding
    package let playlistMutations: any PlaylistMutationDispatching

    package init(openAuthorizationURL: @escaping @Sendable (URL) async -> Bool) {
        let interactive = SpotifyGatewayTransport.admitted(priority: .interactive)
        let enrichment = SpotifyGatewayTransport.admitted(priority: .enrichment)
        let catalog = SpotifyCatalogGateway(
            api: PartnerAPI(transport: interactive),
            mutationAPI: { authorization in
                let session = KeymasterSession.shared
                let generation = await session.credentialGeneration
                return PartnerAPI(
                    accessToken: { try await session.accessToken(expectedGeneration: generation) },
                    invalidateAccessToken: { rejected in
                        _ = try await session.refreshIgnoringExpiry(rejected: rejected, expectedGeneration: generation)
                    },
                    transport: SpotifyGatewayTransport.admitted(priority: .interactive) { request in
                        guard await session.credentialGeneration == generation else {
                            throw KeymasterSessionError.noGrant
                        }
                        try Task.checkCancellation()
                        try authorization.authorizeDispatch()
                        return try await URLSession.shared.data(for: request)
                    }
                )
            }
        )
        remote = LiveRemotePlaybackClient(metadata: SpotifyConnectAPI(transport: enrichment))
        webQueue = SpotifyWebPlayerAPI(transport: interactive)
        account = LiveAccountSession(session: .shared, openAuthorizationURL: openAuthorizationURL)
        self.catalog = catalog
        playlistMutations = catalog
    }
}

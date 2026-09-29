import SpottyDomain
import SpottyEngineAdapter
import SpottyGateway
import SpottyRuntimeContracts
import Foundation

package nonisolated final class UserDefaultsPlaybackPreferences: PlaybackPreferences, @unchecked Sendable {
    package static let shared = UserDefaultsPlaybackPreferences()

    private enum Key {
        static let shuffle = "playback.shuffle.fewer-repeats"
        static let remoteDevice = "playback.last-remote-device-id"
        static let history = "playback.fewer-repeats.history"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func shuffleEnabled() -> Bool { lock.withLock { defaults.bool(forKey: Key.shuffle) } }

    package func setShuffleEnabled(_ enabled: Bool) {
        lock.withLock { defaults.set(enabled, forKey: Key.shuffle) }
    }

    package func lastRemoteDeviceID() -> String? {
        lock.withLock { defaults.string(forKey: Key.remoteDevice) }
    }

    package func setLastRemoteDeviceID(_ id: String?) {
        if let id {
            lock.withLock { defaults.set(id, forKey: Key.remoteDevice) }
        } else {
            lock.withLock { defaults.removeObject(forKey: Key.remoteDevice) }
        }
    }

    package func shuffleHistory() -> [String: TimeInterval] {
        guard
            let data = lock.withLock({ defaults.data(forKey: Key.history) }),
            let history = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return history
    }

    package func setShuffleHistory(_ history: [String: TimeInterval]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        lock.withLock { defaults.set(data, forKey: Key.history) }
    }
}

package nonisolated struct PlaybackEnvironment: Sendable {
    let remote: any RemotePlaybackClient
    let local: any LocalPlaybackEngine
    let webQueue: any WebQueueClient
    let account: any AccountSession
    let audioOutput: any AudioOutputPreparing
    package let artwork: any ArtworkProviding
    let preferences: any PlaybackPreferences
    package let lifecycle: any SystemLifecycleEvents
    package let clock: any PlaybackClock
    package let catalog: any CatalogProviding
    package let playlistMutations: any PlaylistMutating
    let catalogSessionAdmission: CatalogSessionAdmission
    let queueServiceHook: (any QueueServiceHook)?
    let catalogCacheLifecycle: (any CatalogCacheLifecycle)?

    /// Hand-written so checks can pass a hook. A defaulted stored property is
    /// dropped from the synthesized memberwise initializer, which then rejects
    /// `queueServiceHook:` as an extra argument.
    init(
        remote: any RemotePlaybackClient,
        local: any LocalPlaybackEngine,
        webQueue: any WebQueueClient,
        account: any AccountSession,
        audioOutput: any AudioOutputPreparing,
        preferences: any PlaybackPreferences,
        lifecycle: any SystemLifecycleEvents,
        clock: any PlaybackClock,
        catalog: any CatalogProviding,
        playlistMutations: any PlaylistMutationDispatching,
        queueServiceHook: (any QueueServiceHook)? = nil,
        catalogCacheLifecycle: (any CatalogCacheLifecycle)? = nil,
        artwork: any ArtworkProviding = UnavailableArtworkProvider()
    ) {
        self.remote = remote
        self.local = local
        self.webQueue = webQueue
        self.account = account
        self.audioOutput = audioOutput
        self.artwork = artwork
        self.preferences = preferences
        self.lifecycle = lifecycle
        self.clock = clock
        self.catalog = catalog
        let catalogAdmission = CatalogSessionAdmission()
        catalogSessionAdmission = catalogAdmission
        self.playlistMutations = AccountScopedPlaylistMutations(source: playlistMutations, admission: catalogAdmission)
        self.queueServiceHook = queueServiceHook
        self.catalogCacheLifecycle = catalogCacheLifecycle
    }

    package static func live(
        openAuthorizationURL: @escaping @Sendable (URL) async -> Bool,
        lifecycle: any SystemLifecycleEvents
    ) -> PlaybackEnvironment {
        let services = SpotifyGatewayServices(openAuthorizationURL: openAuthorizationURL)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotty/Catalog", isDirectory: true)
        let catalog = PersistentCatalogProvider(source: services.catalog, rootDirectory: root)
        return PlaybackEnvironment(
            remote: services.remote,
            local: RustPlaybackEngine.shared,
            webQueue: services.webQueue,
            account: services.account,
            audioOutput: LiveAudioOutput(),
            preferences: UserDefaultsPlaybackPreferences.shared,
            lifecycle: lifecycle,
            clock: SystemPlaybackClock(),
            catalog: catalog,
            playlistMutations: services.playlistMutations,
            catalogCacheLifecycle: catalog,
            artwork: ArtworkPipeline()
        )
    }

}

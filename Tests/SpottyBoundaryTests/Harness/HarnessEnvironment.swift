import Foundation
import SpottyDomain
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts
@testable import SpottyEngineAdapter
@testable import SpottySessionRuntime

/// The one composition point for boundary checks.
///
/// Every dependency defaults to its harness fake, so a check names only the collaborators it is
/// about. The defaults are deliberately inert: the engine succeeds and records, the Connect
/// client succeeds, the web queue and catalog are unavailable, the account has no grant, and the
/// clock is stuck at `HarnessDates.fixed`.
enum HarnessEnvironment {
    static func make(
        engine: any LocalPlaybackEngine = HarnessEngine(),
        remote: any RemotePlaybackClient = HarnessRemote(),
        webQueue: any WebQueueClient = HarnessWebQueue(),
        account: any AccountSession = HarnessAccount(),
        audioOutput: any AudioOutputPreparing = HarnessAudioOutput(),
        preferences: any PlaybackPreferences = HarnessPreferences(),
        lifecycle: any SystemLifecycleEvents = HarnessLifecycleEvents(),
        clock: any PlaybackClock = HarnessClock.sticky(),
        catalog: any CatalogProviding = HarnessCatalog(),
        playlistMutations: any PlaylistMutating = HarnessPlaylistMutations(),
        trackAttributes: any TrackAttributesProviding = HarnessTrackAttributes(),
        queueServiceHook: (any QueueServiceHook)? = nil
    ) -> PlaybackEnvironment {
        PlaybackEnvironment(
            remote: remote,
            local: engine,
            webQueue: webQueue,
            account: account,
            audioOutput: audioOutput,
            preferences: preferences,
            lifecycle: lifecycle,
            clock: clock,
            catalog: catalog,
            playlistMutations: playlistMutations,
            trackAttributes: trackAttributes,
            queueServiceHook: queueServiceHook
        )
    }

    /// Builds a store and the presenter it publishes through. The presenter defaults to one
    /// driven by the environment's own clock, so a parked clock holds messages visible.
    @MainActor
    static func makeStore(
        environment: PlaybackEnvironment,
        feedback: TransientFeedbackPresenter? = nil
    ) -> (store: PlaybackStore, feedback: TransientFeedbackPresenter) {
        let presenter = feedback ?? TransientFeedbackPresenter(clock: environment.clock)
        return (PlaybackStore(environment: environment, feedback: presenter), presenter)
    }

    /// The common case: a store whose feedback presenter shares the environment's clock.
    @MainActor
    static func makePlaybackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
        makeStore(environment: environment).store
    }
}

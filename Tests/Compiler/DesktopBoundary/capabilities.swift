import SpottyDomain
import SpottyRuntimeContracts
import SpottySessionRuntime

// Compile as the desktop's package peer, without testable runtime access. Inferred member types
// must not provide a route around the concrete-module import restriction.
func readDesktopCatalogPorts(_ environment: PlaybackEnvironment) {
    _ = environment.catalog
    _ = environment.trackAttributes
    _ = environment.playlistMutations
    _ = environment.artwork
    _ = environment.clock
}

@SessionRuntimeActor
func useSupportedRuntimeActions(_ runtime: PlaybackSessionRuntime) {
    let value = runtime.presentation()
    _ = value.semantic
    _ = value.timeline
    _ = value.queueEntries
    _ = value.devices
    _ = value.commandRoute
    _ = runtime.presentations()
    runtime.play(uri: "spotify:track:synthetic")
    runtime.togglePlayback()
}

func rejectInferredEnvironmentCapabilities(_ environment: PlaybackEnvironment) {
    #if NEG_ENV_LOCAL
        _ = environment.local
    #elseif NEG_ENV_ACCOUNT
        _ = environment.account
    #elseif NEG_ENV_REMOTE
        _ = environment.remote
    #elseif NEG_ENV_WEB_QUEUE
        _ = environment.webQueue
    #elseif NEG_ENV_AUDIO_OUTPUT
        _ = environment.audioOutput
    #elseif NEG_ENV_PREFERENCES
        _ = environment.preferences
    #elseif NEG_ENV_QUEUE_HOOK
        _ = environment.queueServiceHook
    #elseif NEG_ENV_CATALOG_LIFECYCLE
        _ = environment.catalogCacheLifecycle
    #elseif NEG_ENV_MUTATION_ADMISSION
        _ = environment.playlistMutationAdmission
    #elseif NEG_ENV_INITIALIZER
        _ = PlaybackEnvironment.init
    #endif
}

@SessionRuntimeActor
func rejectInferredRuntimeCapabilities(_ runtime: PlaybackSessionRuntime) {
    #if NEG_RUNTIME_ENVIRONMENT
        _ = runtime.environment
    #elseif NEG_RUNTIME_COORDINATOR
        _ = runtime.coordinator
    #elseif NEG_RUNTIME_ACCOUNT_STORE
        _ = runtime.accountStore
    #elseif NEG_RUNTIME_EFFECTS
        _ = runtime.effects
    #elseif NEG_RUNTIME_QUEUE_SERVICE
        _ = runtime.queueService
    #elseif NEG_RUNTIME_STATE
        _ = runtime.state
    #elseif NEG_RUNTIME_PRESENTATION_STATE
        _ = runtime.presentation().state
    #elseif NEG_RUNTIME_GENERATION_WRITE
        runtime.engineGeneration = runtime.engineGeneration
    #elseif NEG_RUNTIME_CATALOG_STATE
        _ = runtime.catalog
    #elseif NEG_RUNTIME_CATALOG_SESSION
        _ = runtime.catalogSession
    #elseif NEG_RUNTIME_TEARDOWN
        _ = runtime.teardown
    #elseif NEG_RUNTIME_SEND
        runtime.send(.session(.signedOut), source: .account)
    #elseif NEG_RUNTIME_REDUCE
        runtime.reduce(.session(.signedOut), source: .account)
    #elseif NEG_RUNTIME_PERFORM_COMMAND
        runtime.performCommand("Synthetic probe", operation: .pause)
    #elseif NEG_RUNTIME_ENGINE_EVENT
        runtime.receive([], revision: 0, engineEpoch: 0)
    #endif
}

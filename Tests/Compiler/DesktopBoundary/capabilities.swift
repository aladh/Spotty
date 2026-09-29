import SpottyDomain
import SpottyRuntimeContracts
import SpottySessionRuntime

// Compile as the desktop's package peer, without testable runtime access. Inferred member types
// must not provide a route around the concrete-module import restriction.
func readDesktopCatalogPorts(_ environment: PlaybackEnvironment) {
    _ = environment.catalog
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
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.local
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.account
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.remote
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.webQueue
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.audioOutput
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.preferences
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.queueServiceHook
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.catalogCacheLifecycle
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = environment.catalogSessionAdmission
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = PlaybackEnvironment.init
}

@SessionRuntimeActor
func rejectInferredRuntimeCapabilities(_ runtime: PlaybackSessionRuntime) {
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.environment
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.coordinator
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.accountStore
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.effects
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.queueService
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.state
    // expected-error@+1 {{value of type 'RuntimePresentation' has no member 'state'}}
    _ = runtime.presentation().state
    // expected-error@+1 {{'engineGeneration' is a get-only property}}
    runtime.engineGeneration = runtime.engineGeneration
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.catalogMetadata
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.catalogSession
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    _ = runtime.lifecycle
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    runtime.send(.session(.signedOut), source: .account)
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    runtime.reduce(.session(.signedOut), source: .account)
    // expected-error@+2 {{is inaccessible due to 'internal' protection level}}
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    runtime.submitCommand(.pause, failureMessage: "Synthetic probe")
    // expected-error@+1 {{is inaccessible due to 'internal' protection level}}
    runtime.receive([], revision: 0, engineEpoch: 0)
}

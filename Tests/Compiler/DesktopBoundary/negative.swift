@testable import SpottyCore
import SpottySessionRuntime

// Even testable desktop clients (including the Demo) must import a concrete implementation
// explicitly to name it. A session/runtime re-export must not silently reopen this boundary.
// Every type must produce its own diagnostic, so one hidden type cannot mask another leaked type.
func rejectDesktopImplementationAccess() {
    // expected-error@+1 {{cannot find 'KeymasterSession' in scope}}
    _ = KeymasterSession.self
    // expected-error@+1 {{cannot find 'KeymasterTokens' in scope}}
    _ = KeymasterTokens.self
    // expected-error@+1 {{cannot find 'KeymasterFileStore' in scope}}
    _ = KeymasterFileStore.self
    // expected-error@+1 {{cannot find 'SpotifyCredentials' in scope}}
    _ = SpotifyCredentials.self
    // expected-error@+1 {{cannot find 'PartnerAPI' in scope}}
    _ = PartnerAPI.self
    // expected-error@+1 {{cannot find 'SpotifyGatewayServices' in scope}}
    _ = SpotifyGatewayServices.self
    // expected-error@+1 {{cannot find 'PersistentCatalog' in scope}}
    _ = PersistentCatalog.self
    // expected-error@+1 {{cannot find 'CatalogEntityObservations' in scope}}
    _ = CatalogEntityObservations.self
    // expected-error@+1 {{cannot find 'RustPlaybackEngine' in scope}}
    _ = RustPlaybackEngine.self
    // expected-error@+1 {{cannot find 'AudioRenderer' in scope}}
    _ = AudioRenderer.self
    // expected-error@+1 {{cannot find 'PlaybackCore' in scope}}
    _ = PlaybackCore.self
}

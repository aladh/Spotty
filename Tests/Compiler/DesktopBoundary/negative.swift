@testable import SpottyCore
import SpottySessionRuntime

// Even testable desktop clients (including the Demo) must import a concrete implementation
// explicitly to name it. A session/runtime re-export must not silently reopen this boundary.
// Each branch is checked independently, so one hidden type cannot mask another leaked type.
func rejectDesktopImplementationAccess() {
    #if NEG_KEYMASTER_SESSION
        _ = KeymasterSession.self
    #elseif NEG_KEYMASTER_TOKENS
        _ = KeymasterTokens.self
    #elseif NEG_KEYMASTER_FILE_STORE
        _ = KeymasterFileStore.self
    #elseif NEG_SPOTIFY_CREDENTIALS
        _ = SpotifyCredentials.self
    #elseif NEG_PARTNER_API
        _ = PartnerAPI.self
    #elseif NEG_GATEWAY_FACTORY
        _ = SpotifyGatewayServices.self
    #elseif NEG_CATALOG_STORAGE
        _ = PersistentCatalog.self
    #elseif NEG_RUST_ENGINE
        _ = RustPlaybackEngine.self
    #elseif NEG_AUDIO_RENDERER
        _ = AudioRenderer.self
    #elseif NEG_PLAYBACK_CORE
        _ = PlaybackCore.self
    #endif
}

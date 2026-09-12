import SpottyRuntimeContracts

/// Stable, privacy-safe UI copy for catalog capability failures.
nonisolated enum CatalogErrorPresentation {
    static func message(for error: any Error) -> String {
        switch error as? CatalogReadFailure {
        case .compatibility:
            "Spotify changed how this content loads. Update Spotty to try again."
        case .sessionExpired:
            "Your Spotify session has expired. Sign in again to continue."
        case .offline:
            "Couldn't connect to Spotify. Check your connection and try again."
        case .timedOut:
            "Spotify took too long to respond. Try again."
        case .throttled:
            "Spotify is receiving too many requests. Wait a moment and try again."
        case .unavailable, nil:
            "Couldn't load this content from Spotify. Try again."
        }
    }
}

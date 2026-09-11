import Foundation

/// One privacy-safe boundary between transport diagnostics and catalog UI copy.
nonisolated enum CatalogErrorPresentation {
    static func message(for error: any Error) -> String {
        if case PartnerAPIError.persistedQueryNotFound = error {
            return "Spotify changed how this content loads. Update Spotty to try again."
        }
        if error is KeymasterSessionError || error as? KeymasterAuthError == .grantRevoked {
            return "Your Spotify session has expired. Sign in again to continue."
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "Couldn't connect to Spotify. Check your connection and try again."
            case .timedOut:
                return "Spotify took too long to respond. Try again."
            default: break
            }
        }
        if case PartnerAPIError.requestFailed(429) = error {
            return "Spotify is receiving too many requests. Wait a moment and try again."
        }
        return "Couldn't load this content from Spotify. Try again."
    }
}

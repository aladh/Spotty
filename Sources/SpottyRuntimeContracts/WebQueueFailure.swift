import Foundation

public enum WebQueueFailure: Error, LocalizedError, Equatable {
    case malformedResponse
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "Spotify returned an unreadable queue"
        case let .requestFailed(status):
            "Spotify rejected the queue request (HTTP \(status))"
        }
    }

    public var statusCode: Int? {
        guard case let .requestFailed(status) = self else { return nil }
        return status
    }
}

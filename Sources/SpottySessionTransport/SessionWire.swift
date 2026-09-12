import Foundation
import SpottyRuntimeContracts

public enum SessionTransportError: Error, Equatable, Sendable {
    case disconnected
    case notConnected
    case incompatibleVersion
    case payloadTooLarge
    case invalidPayload
    case staleSession
    case tooManyRequests
    case unknownOutcome(commandID: UUID)
    case invalidPeerIdentity
}

enum SessionWire {
    static let version = 1
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumPendingRequests = 64
    static let maximumCommandItems = 256
    static let maximumQueueEntries = 4_096
    static let maximumStringBytes = 4_096

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw SessionTransportError.payloadTooLarge }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw SessionTransportError.payloadTooLarge }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw SessionTransportError.invalidPayload }
    }

    static func validate(_ command: SessionCommand) throws {
        switch command.action {
        case let .playURI(uri): try validate(strings: [uri])
        case let .playTracks(tracks, contextURI):
            guard !tracks.isEmpty, tracks.count <= maximumCommandItems else {
                throw SessionTransportError.invalidPayload
            }
            try validate(strings: tracks.map(\.uri) + (contextURI.map { [$0] } ?? []))
        case let .addToQueue(uris):
            guard !uris.isEmpty, uris.count <= maximumCommandItems else {
                throw SessionTransportError.invalidPayload
            }
            try validate(strings: uris)
        case let .removeUpcoming(ids):
            guard !ids.isEmpty, ids.count <= maximumCommandItems else {
                throw SessionTransportError.invalidPayload
            }
            try validate(strings: Array(ids))
        case let .seek(fraction):
            guard fraction.isFinite, (0...1).contains(fraction) else {
                throw SessionTransportError.invalidPayload
            }
        case let .transfer(device):
            try validate(strings: [device.id])
            guard device.name.utf8.count <= maximumStringBytes, device.type.utf8.count <= maximumStringBytes else {
                throw SessionTransportError.invalidPayload
            }
        default: break
        }
    }

    static func validate(_ snapshot: SessionSnapshot) throws {
        guard snapshot.queue.entries.count <= maximumQueueEntries,
            snapshot.devices.devices.count <= 256, snapshot.receipts.count <= 256,
            snapshot.presentation.timing.position.isFinite,
            snapshot.presentation.timing.duration.isFinite
        else { throw SessionTransportError.invalidPayload }
    }

    private static func validate(strings: [String]) throws {
        guard strings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumStringBytes }) else {
            throw SessionTransportError.invalidPayload
        }
    }
}

struct SessionWireRequest: Codable, Sendable {
    var version = SessionWire.version
    let id: UUID
    let body: Body

    enum Body: Codable, Sendable {
        case handshake
        case snapshot(sessionID: UUID)
        case command(SessionCommand)
    }
}

struct SessionWireResponse: Codable, Sendable {
    var version = SessionWire.version
    let id: UUID
    let body: Body

    enum Body: Codable, Sendable {
        case snapshot(SessionSnapshot)
        case receipt(SessionCommandReceipt)
        case failure(Failure)
    }

    enum Failure: String, Codable, Sendable {
        case incompatibleVersion, invalidPayload, payloadTooLarge, staleSession, handshakeRequired

        var error: SessionTransportError {
            switch self {
            case .incompatibleVersion: .incompatibleVersion
            case .invalidPayload: .invalidPayload
            case .payloadTooLarge: .payloadTooLarge
            case .staleSession: .staleSession
            case .handshakeRequired: .notConnected
            }
        }
    }
}

struct SessionWirePublication: Codable, Sendable {
    var version = SessionWire.version
    let snapshot: SessionSnapshot
}

/// A skipped semantic revision requires a fresh authoritative read. Full snapshots in event
/// messages do not erase the fact that command history may have been lost along the way.
struct SessionRevisionCursor: Sendable {
    private(set) var sessionID: UUID?
    private(set) var revision: UInt64?

    mutating func reset(to snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionID
        revision = snapshot.revision
    }

    mutating func accept(_ snapshot: SessionSnapshot) -> Decision {
        guard snapshot.sessionID == sessionID, let revision else { return .resynchronize }
        guard snapshot.revision > revision else { return .ignore }
        guard revision < .max, snapshot.revision == revision + 1 else { return .resynchronize }
        self.revision = snapshot.revision
        return .publish
    }

    enum Decision { case publish, ignore, resynchronize }
}

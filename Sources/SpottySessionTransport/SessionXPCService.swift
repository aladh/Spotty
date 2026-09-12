import Darwin
import Foundation
import SpottyRuntimeContracts

@objc protocol SessionXPCRequests {
    func exchange(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

@objc protocol SessionXPCPublications {
    func publish(_ data: Data, acknowledgement: @escaping @Sendable () -> Void)
}

/// The bundled helper owns this host for its lifetime. Its runtime owns engines, audio and account
/// resources; the host only validates/fragments the process boundary and retains connections.
public final class SessionXPCServiceHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let runtime: any SessionRuntimeServing
    private let peerRequirement: String
    private let isSynthetic: Bool
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    public init(runtime: any SessionRuntimeServing, clientIdentity: SessionPeerIdentity) {
        listener = .service()
        self.runtime = runtime
        peerRequirement = clientIdentity.requirement
        isSynthetic = false
        super.init()
        listener.delegate = self
    }

    private init(syntheticRuntime: any SessionRuntimeServing, requirement: String) {
        listener = .anonymous()
        runtime = syntheticRuntime
        peerRequirement = requirement
        isSynthetic = true
        super.init()
        listener.delegate = self
    }

    deinit {
        listener.invalidate()
        for connection in connections.values { connection.invalidate() }
    }

    /// Synthetic clients receive only this anonymous endpoint. This constructor cannot select,
    /// discover or fall back to a named live service, even when a live app is running.
    public static func synthetic(runtime: any SessionRuntimeServing) throws -> SessionXPCServiceHost {
        let host = try SessionXPCServiceHost(
            syntheticRuntime: runtime, requirement: SessionPeerIdentity.currentProcessRequirement())
        host.resume()
        return host
    }

    public func makeSyntheticClient() throws -> SessionXPCClient {
        guard isSynthetic else { throw SessionTransportError.invalidPeerIdentity }
        return SessionXPCClient(endpoint: listener.endpoint, peerRequirement: peerRequirement)
    }

    public func resume() { listener.resume() }

    public func invalidate() {
        listener.invalidate()
        let retained = lock.withLock {
            let retained = Array(connections.values)
            connections.removeAll()
            return retained
        }
        retained.forEach { $0.invalidate() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        let admitted = lock.withLock {
            guard connections.count < 8 else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard admitted else { return false }
        connection.setCodeSigningRequirement(peerRequirement)
        connection.exportedInterface = NSXPCInterface(with: SessionXPCRequests.self)
        connection.remoteObjectInterface = NSXPCInterface(with: SessionXPCPublications.self)
        let peer = SessionXPCPeer(runtime: runtime, connection: SessionConnectionReference(value: connection))
        connection.exportedObject = SessionXPCRequestReceiver(peer: peer)
        let identifier = ObjectIdentifier(connection)
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.invalidationHandler = { [weak self] in
            self?.removeConnection(identifier)
            Task { await peer.invalidate() }
        }
        connection.resume()
        return true
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        _ = lock.withLock { connections.removeValue(forKey: id) }
    }
}

private final class SessionXPCRequestReceiver: NSObject, SessionXPCRequests, Sendable {
    let peer: SessionXPCPeer
    init(peer: SessionXPCPeer) { self.peer = peer }

    func exchange(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(await peer.exchange(data)) }
    }
}

/// Configuration finishes before resume. Afterwards the host may invalidate while the peer uses
/// NSXPC's thread-safe proxy operations; mutable protocol state remains isolated to the peer actor.
private struct SessionConnectionReference: @unchecked Sendable {
    let value: NSXPCConnection
}

private actor SessionXPCPeer {
    private let runtime: any SessionRuntimeServing
    private let connection: NSXPCConnection
    private var sessionID: UUID?
    private var subscription: Task<Void, Never>?
    private var active = true
    private var inFlight = 0
    private var handshakeStarted = false
    private var publicationInFlight = false
    private var pendingPublication: SessionSnapshot?

    init(runtime: any SessionRuntimeServing, connection: SessionConnectionReference) {
        self.runtime = runtime
        self.connection = connection.value
    }

    func invalidate() {
        active = false
        subscription?.cancel()
        subscription = nil
        pendingPublication = nil
    }

    func exchange(_ data: Data) async -> Data {
        let request: SessionWireRequest
        do { request = try SessionWire.decode(SessionWireRequest.self, from: data) } catch {
            return failure(
                id: UUID(), reason: data.count > SessionWire.maximumBytes ? .payloadTooLarge : .invalidPayload)
        }
        guard request.version == SessionWire.version else {
            return failure(id: request.id, reason: .incompatibleVersion)
        }
        guard active, inFlight < SessionWire.maximumPendingRequests else {
            return failure(id: request.id, reason: .invalidPayload)
        }
        inFlight += 1
        defer { inFlight -= 1 }
        var submittedCommand: SessionCommand?
        do {
            let body: SessionWireResponse.Body
            switch request.body {
            case .handshake:
                guard !handshakeStarted else { return failure(id: request.id, reason: .invalidPayload) }
                handshakeStarted = true
                let stream = await runtime.subscribe()
                let snapshot = await runtime.snapshot()
                guard active else { return failure(id: request.id, reason: .handshakeRequired) }
                try SessionWire.validate(snapshot)
                sessionID = snapshot.sessionID
                subscription = Task { [weak self] in
                    for await snapshot in stream {
                        guard !Task.isCancelled else { break }
                        await self?.publish(snapshot)
                    }
                }
                body = .snapshot(snapshot)
            case let .snapshot(requestedSession):
                guard sessionID != nil else { return failure(id: request.id, reason: .handshakeRequired) }
                // A replacement runtime/account is represented by the complete snapshot's new ID.
                guard requestedSession == sessionID else { return failure(id: request.id, reason: .staleSession) }
                let snapshot = await runtime.snapshot()
                try SessionWire.validate(snapshot)
                sessionID = snapshot.sessionID
                body = .snapshot(snapshot)
            case let .command(command):
                guard let sessionID else { return failure(id: request.id, reason: .handshakeRequired) }
                guard command.sessionID == sessionID else { return failure(id: request.id, reason: .staleSession) }
                try SessionWire.validate(command)
                submittedCommand = command
                body = .receipt(await runtime.submit(command))
            }
            return try SessionWire.encode(SessionWireResponse(id: request.id, body: body))
        } catch {
            if let command = submittedCommand {
                // The runtime may already have dispatched. An invalid/oversized result cannot
                // be converted into a rejection that suggests this mutation is safe to retry.
                let receipt = SessionCommandReceipt(
                    commandID: command.id, sessionID: command.sessionID, disposition: .unknown,
                    message: "The command result could not be delivered.")
                return (try? SessionWire.encode(SessionWireResponse(id: request.id, body: .receipt(receipt)))) ?? Data()
            }
            return failure(
                id: request.id,
                reason: error as? SessionTransportError == .payloadTooLarge ? .payloadTooLarge : .invalidPayload)
        }
    }

    private func publish(_ snapshot: SessionSnapshot) {
        guard active else { return }
        if publicationInFlight {
            // Only one outgoing event and one newest replacement are retained. A coalesced
            // semantic revision is visible to the client's resynchronization cursor.
            pendingPublication = snapshot
            return
        }
        do {
            try SessionWire.validate(snapshot)
            let data = try SessionWire.encode(SessionWirePublication(snapshot: snapshot))
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak connection] _ in
                    connection?.invalidate()
                }) as? SessionXPCPublications
            else { connection.invalidate(); return }
            publicationInFlight = true
            proxy.publish(data) { [weak self] in
                Task { await self?.publicationAcknowledged() }
            }
        } catch { connection.invalidate() }
    }

    private func publicationAcknowledged() {
        publicationInFlight = false
        guard let snapshot = pendingPublication else { return }
        pendingPublication = nil
        publish(snapshot)
    }

    private func failure(id: UUID, reason: SessionWireResponse.Failure) -> Data {
        // Fixed-size error envelopes are always within the bound and contain no untrusted payload.
        (try? SessionWire.encode(SessionWireResponse(id: id, body: .failure(reason)))) ?? Data()
    }
}

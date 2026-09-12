import Foundation
import SpottyRuntimeContracts

public enum SessionClientEvent: Sendable {
    case snapshot(SessionSnapshot)
    case commandsUnknown([SessionCommandReceipt])
    case disconnected(unknownCommands: [SessionCommandReceipt])
}

/// One explicit connection attempt. A broken connection closes admission and settles outstanding
/// writes as unknown. The caller may reconnect for a full snapshot; no pending request is replayed.
public actor SessionXPCClient {
    private let destination: Destination
    private let peerRequirement: String
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var cursor = SessionRevisionCursor()
    private var pending: [UUID: PendingRequest] = [:]
    private var unsettledCommands: [UUID: SessionCommand] = [:]
    private var subscribers: [UUID: AsyncStream<SessionClientEvent>.Continuation] = [:]
    private var handshakePublication: SessionSnapshot?
    private var resynchronizing = false
    private var resynchronizationPublication: SessionSnapshot?
    public private(set) var currentSnapshot: SessionSnapshot?
    public private(set) var unknownOutcomes: [SessionCommandReceipt] = []

    public init(serviceName: String, serviceIdentity: SessionPeerIdentity) throws {
        guard serviceName == serviceIdentity.bundleIdentifier else { throw SessionTransportError.invalidPeerIdentity }
        destination = .bundled(serviceName)
        peerRequirement = serviceIdentity.requirement
    }

    init(endpoint: NSXPCListenerEndpoint, peerRequirement: String) {
        destination = .synthetic(endpoint)
        self.peerRequirement = peerRequirement
    }

    @discardableResult
    public func connect() async throws -> SessionSnapshot {
        if let currentSnapshot, connection != nil { return currentSnapshot }
        guard connection == nil else { throw SessionTransportError.notConnected }
        let connection: NSXPCConnection
        switch destination {
        case let .bundled(name): connection = NSXPCConnection(serviceName: name)
        case let .synthetic(endpoint): connection = NSXPCConnection(listenerEndpoint: endpoint)
        }
        let generation = UUID()
        connection.setCodeSigningRequirement(peerRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: SessionXPCRequests.self)
        connection.exportedInterface = NSXPCInterface(with: SessionXPCPublications.self)
        connection.exportedObject = SessionXPCPublicationReceiver(client: self, connectionID: generation)
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionLost(generation) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionLost(generation) }
        }
        self.connection = connection
        connectionID = generation
        connection.resume()
        do {
            let reply = try await request(.handshake)
            guard generation == connectionID else { throw SessionTransportError.disconnected }
            guard case let .snapshot(snapshot) = reply else { throw SessionTransportError.invalidPayload }
            try acceptComplete(snapshot)
            if let buffered = handshakePublication {
                handshakePublication = nil
                await receive(snapshot: buffered, generation: generation)
            }
            guard generation == connectionID, let currentSnapshot else { throw SessionTransportError.disconnected }
            return currentSnapshot
        } catch {
            connectionLost(generation)
            throw error
        }
    }

    public func disconnect() {
        if let connectionID { connectionLost(connectionID) }
    }

    public func submit(_ command: SessionCommand) async throws -> SessionCommandReceipt {
        guard let currentSnapshot, connection != nil else { throw SessionTransportError.notConnected }
        let submittedGeneration = connectionID
        guard command.sessionID == currentSnapshot.sessionID else { throw SessionTransportError.staleSession }
        try SessionWire.validate(command)
        guard unsettledCommands[command.id] == nil else { throw SessionTransportError.invalidPayload }
        guard unsettledCommands.count < SessionWire.maximumPendingRequests else {
            throw SessionTransportError.tooManyRequests
        }
        if command.action.mayWrite { unsettledCommands[command.id] = command }
        let reply: SessionWireResponse.Body
        do {
            reply = try await request(.command(command), command: command)
        } catch {
            if submittedGeneration == connectionID { unsettledCommands.removeValue(forKey: command.id) }
            throw error
        }
        guard submittedGeneration == connectionID else {
            throw command.action.mayWrite
                ? SessionTransportError.unknownOutcome(commandID: command.id) : .disconnected
        }
        guard command.sessionID == self.currentSnapshot?.sessionID else {
            throw command.action.mayWrite
                ? SessionTransportError.unknownOutcome(commandID: command.id) : .staleSession
        }
        guard case let .receipt(receipt) = reply,
            receipt.commandID == command.id, receipt.sessionID == command.sessionID
        else {
            if let connectionID { connectionLost(connectionID) }
            throw command.action.mayWrite
                ? SessionTransportError.unknownOutcome(commandID: command.id) : .invalidPayload
        }
        if receipt.disposition == .unknown { rememberUnknown([receipt]) }
        if receipt.disposition.isTerminal { unsettledCommands.removeValue(forKey: command.id) }
        if let unknown = unknownOutcomes.first(where: {
            $0.commandID == command.id && $0.sessionID == command.sessionID
        }) {
            return unknown
        }
        if let terminal = self.currentSnapshot?.receipts.first(where: {
            $0.commandID == command.id && $0.sessionID == command.sessionID && $0.disposition.isTerminal
        }) {
            return terminal
        }
        return receipt
    }

    public func subscribe() -> AsyncStream<SessionClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        subscribers[id] = continuation
        if let currentSnapshot { continuation.yield(.snapshot(currentSnapshot)) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    private func request(
        _ body: SessionWireRequest.Body, command: SessionCommand? = nil
    ) async throws -> SessionWireResponse.Body {
        guard let connection, let generation = connectionID else { throw SessionTransportError.notConnected }
        guard pending.count < SessionWire.maximumPendingRequests else { throw SessionTransportError.tooManyRequests }
        let id = UUID()
        let data = try SessionWire.encode(SessionWireRequest(id: id, body: body))
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.connectionLost(generation)
            }
            pending[id] = PendingRequest(continuation: continuation, command: command, timeout: timeout)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    Task { await self?.connectionLost(generation) }
                }) as? SessionXPCRequests
            else {
                connectionLost(generation)
                return
            }
            proxy.exchange(data) { [weak self] response in
                Task { await self?.receivedResponse(response, requestID: id, generation: generation) }
            }
        }
    }

    private func receivedResponse(_ data: Data, requestID: UUID, generation: UUID) {
        guard generation == connectionID, let request = pending[requestID] else { return }
        do {
            let response = try SessionWire.decode(SessionWireResponse.self, from: data)
            guard response.version == SessionWire.version else { throw SessionTransportError.incompatibleVersion }
            guard response.id == requestID else { throw SessionTransportError.invalidPayload }
            pending.removeValue(forKey: requestID)
            request.timeout.cancel()
            if case let .failure(failure) = response.body {
                request.continuation.resume(throwing: failure.error)
            } else {
                request.continuation.resume(returning: response.body)
            }
        } catch { connectionLost(generation) }
    }

    fileprivate func receive(_ data: Data, generation: UUID) async {
        guard generation == connectionID else { return }
        do {
            let publication = try SessionWire.decode(SessionWirePublication.self, from: data)
            guard publication.version == SessionWire.version else { throw SessionTransportError.incompatibleVersion }
            try SessionWire.validate(publication.snapshot)
            await receive(snapshot: publication.snapshot, generation: generation)
        } catch { connectionLost(generation) }
    }

    private func receive(snapshot: SessionSnapshot, generation: UUID) async {
        guard generation == connectionID else { return }
        guard currentSnapshot != nil else {
            handshakePublication = snapshot
            return
        }
        if resynchronizing {
            resynchronizationPublication = snapshot
            return
        }
        switch cursor.accept(snapshot) {
        case .ignore: return
        case .publish:
            currentSnapshot = snapshot
            settleReceipts(in: snapshot)
            broadcast(.snapshot(snapshot))
        case .resynchronize:
            guard !resynchronizing, let sessionID = currentSnapshot?.sessionID else { return }
            resynchronizing = true
            do {
                let response = try await request(.snapshot(sessionID: sessionID))
                guard generation == connectionID else { return }
                guard case let .snapshot(complete) = response else { throw SessionTransportError.invalidPayload }
                // A later contiguous publication can arrive while this read is in flight.
                if complete.sessionID != currentSnapshot?.sessionID
                    || complete.revision >= (currentSnapshot?.revision ?? 0)
                {
                    try acceptComplete(complete)
                }
            } catch { connectionLost(generation) }
            guard generation == connectionID else { return }
            resynchronizing = false
            if let buffered = resynchronizationPublication {
                resynchronizationPublication = nil
                await receive(snapshot: buffered, generation: generation)
            }
        }
    }

    private func acceptComplete(_ snapshot: SessionSnapshot) throws {
        try SessionWire.validate(snapshot)
        retireCommands(outside: snapshot.sessionID)
        cursor.reset(to: snapshot)
        currentSnapshot = snapshot
        settleReceipts(in: snapshot)
        broadcast(.snapshot(snapshot))
    }

    private func retireCommands(outside sessionID: UUID) {
        let retired = unsettledCommands.values.filter { $0.sessionID != sessionID }
        let unknown = retired.map {
            SessionCommandReceipt(
                commandID: $0.id, sessionID: $0.sessionID, disposition: .unknown,
                message: "The account session ended before this command was observed.")
        }
        for command in retired { unsettledCommands.removeValue(forKey: command.id) }
        let retiredRequests = pending.filter { $0.value.command.map { $0.sessionID != sessionID } ?? false }
        for (id, request) in retiredRequests {
            pending.removeValue(forKey: id)
            request.timeout.cancel()
            if let command = request.command, command.action.mayWrite {
                request.continuation.resume(throwing: SessionTransportError.unknownOutcome(commandID: command.id))
            } else {
                request.continuation.resume(throwing: SessionTransportError.staleSession)
            }
        }
        guard !unknown.isEmpty else { return }
        rememberUnknown(unknown)
        broadcast(.commandsUnknown(unknown))
    }

    private func settleReceipts(in snapshot: SessionSnapshot) {
        for receipt in snapshot.receipts where receipt.disposition.isTerminal {
            guard unsettledCommands[receipt.commandID]?.sessionID == receipt.sessionID else { continue }
            if receipt.disposition == .unknown { rememberUnknown([receipt]) }
            unsettledCommands.removeValue(forKey: receipt.commandID)
        }
    }

    private func rememberUnknown(_ receipts: [SessionCommandReceipt]) {
        for receipt in receipts {
            guard
                !unknownOutcomes.contains(where: {
                    $0.commandID == receipt.commandID && $0.sessionID == receipt.sessionID
                })
            else { continue }
            // Retained uncertainty carries only operation/session identities, never track payloads
            // or an account-specific service error through the replacement account's lifetime.
            unknownOutcomes.append(
                .init(
                    commandID: receipt.commandID, sessionID: receipt.sessionID, disposition: .unknown,
                    message: "The command outcome could not be confirmed."))
        }
        unknownOutcomes = Array(unknownOutcomes.suffix(256))
    }

    private func connectionLost(_ generation: UUID) {
        guard generation == connectionID else { return }
        let lostConnection = connection
        connection = nil
        connectionID = nil
        currentSnapshot = nil
        handshakePublication = nil
        resynchronizationPublication = nil
        resynchronizing = false
        cursor = SessionRevisionCursor()
        let requests = pending.values
        pending.removeAll()
        let unknown = unsettledCommands.values.map { command in
            SessionCommandReceipt(
                commandID: command.id, sessionID: command.sessionID, disposition: .unknown,
                message: "Communication ended before the command outcome was received.")
        }
        unsettledCommands.removeAll()
        for request in requests {
            request.timeout.cancel()
            if let command = request.command, command.action.mayWrite {
                request.continuation.resume(throwing: SessionTransportError.unknownOutcome(commandID: command.id))
            } else {
                request.continuation.resume(throwing: SessionTransportError.disconnected)
            }
        }
        rememberUnknown(unknown)
        broadcast(.disconnected(unknownCommands: unknown))
        lostConnection?.invalidate()
    }

    private func broadcast(_ event: SessionClientEvent) {
        for subscriber in subscribers.values { subscriber.yield(event) }
    }

    private enum Destination: @unchecked Sendable {
        case bundled(String)
        case synthetic(NSXPCListenerEndpoint)
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<SessionWireResponse.Body, any Error>
        let command: SessionCommand?
        let timeout: Task<Void, Never>
    }
}

private final class SessionXPCPublicationReceiver: NSObject, SessionXPCPublications, @unchecked Sendable {
    weak var client: SessionXPCClient?
    let connectionID: UUID
    init(client: SessionXPCClient, connectionID: UUID) {
        self.client = client
        self.connectionID = connectionID
    }

    func publish(_ data: Data, acknowledgement: @escaping @Sendable () -> Void) {
        Task {
            await client?.receive(data, generation: connectionID)
            acknowledgement()
        }
    }
}

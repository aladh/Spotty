//
//  LoopbackCallbackServer.swift
//  Spotty
//
//  A one-shot HTTP listener on loopback, for OAuth redirects that are not a custom scheme.
//

import Foundation
import SpottyRuntimeContracts
import SpottyDomain
import Network

/// Receives a single OAuth redirect on `http://127.0.0.1:<port>/login`.
///
/// `ASWebAuthenticationSession` cannot serve this flow: Spotify's desktop client id is
/// registered with a plain-HTTP loopback redirect rather than a custom scheme, and
/// `ASWebAuthenticationSession` only intercepts custom schemes and associated-domain HTTPS.
/// So the browser opens normally and the redirect lands here.
///
/// One request, one answer, then the listener closes — nothing about this outlives the grant.
/// The port is assigned by the system rather than fixed: Spotify accepts any loopback port for
/// a first-party client id, and a hardcoded one would collide with whatever else is listening.
actor LoopbackCallbackServer {
    enum ServerError: Error, LocalizedError {
        case listenerFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .listenerFailed(message):
                "Could not listen for the Spotify redirect: \(message)"
            case .timedOut:
                "Timed out waiting for the Spotify redirect"
            }
        }
    }

    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<URLComponents, Error>?
    private enum State {
        case idle
        case listening
        // Retain a callback that beats its waiter; nil means the result was consumed.
        case finished(Result<URLComponents, Error>?)
    }
    private var state = State.idle
    private var timeout: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var activeConnectionCount: Int { connections.count }

    /// Starts listening on a system-assigned loopback port and returns it.
    ///
    /// Waits for the listener to reach `.ready`: until then the port is a placeholder, and
    /// advertising it would send Spotify a redirect to `127.0.0.1:0`, which reaches nothing.
    func start() async throws -> UInt16 {
        try Task.checkCancellation()
        guard case .idle = state else {
            throw ServerError.listenerFailed("listener already started or stopped")
        }
        state = .listening
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. The redirect never leaves this machine, so nothing else should be
        // able to reach the listener.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            let failure = ServerError.listenerFailed(String(describing: error))
            finish(.failure(failure))
            throw failure
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }

        self.listener = listener

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let port = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<UInt16, Error>) in
                    startWaiter = continuation
                    // Keep observing failures after readiness, without retaining the listener.
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        let result: Result<UInt16, Error>
                        switch state {
                        case .ready:
                            if let port = listener?.port?.rawValue, port != 0 {
                                result = .success(port)
                            } else {
                                result = .failure(ServerError.listenerFailed("no port assigned"))
                            }
                        case let .failed(error):
                            result = .failure(ServerError.listenerFailed(String(describing: error)))
                        case .cancelled:
                            result = .failure(CancellationError())
                        default:
                            return
                        }
                        Task { await self?.listenerChanged(result) }
                    }
                    listener.start(queue: .global(qos: .userInitiated))
                }
                try Task.checkCancellation()
                guard case .listening = state else { throw CancellationError() }
                return port
            } onCancel: {
                Task { await self.stop() }
            }
        } catch {
            finish(.failure(error))
            throw error
        }
    }

    private func accept(_ connection: NWConnection) {
        guard case .listening = state else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .global(qos: .userInitiated))
        Self.receiveRequest(on: connection) { [weak self] callback in
            Task { await self?.requestCompleted(on: connection, callback: callback) }
        }
    }

    private func requestCompleted(on connection: NWConnection, callback: URLComponents?) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        if let callback { finish(.success(callback)) }
    }

    private func listenerChanged(_ result: Result<UInt16, Error>) {
        switch result {
        case .success: resumeStart(result)
        case let .failure(error): finish(.failure(error))
        }
    }

    /// Resolves `start()`, at most once.
    private func resumeStart(_ result: Result<UInt16, Error>) {
        guard let startWaiter else { return }
        self.startWaiter = nil
        startWaiter.resume(with: result)
    }

    /// Waits for the redirect until it arrives or the caller explicitly cancels.
    ///
    /// Human authorization has no predictable duration: password-manager recovery, two-factor
    /// authentication, or simply stepping away can all take longer than a fixed deadline. The
    /// app therefore supplies a visible Cancel Sign-In action and cancellation, rather than a
    /// timer, owns the listener lifetime.
    ///
    /// The timeout delivers into the same one-shot path as a real callback rather than racing
    /// it in a task group, so whichever arrives first is the answer and the other cannot leave
    /// a continuation dangling.
    func waitForCallback(timeout duration: Duration? = nil) async throws -> URLComponents {
        guard waiter == nil else {
            throw ServerError.listenerFailed("callback already awaited")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { finish(.failure(CancellationError())) }
                switch state {
                case .idle:
                    continuation.resume(throwing: ServerError.listenerFailed("listener not started"))
                case let .finished(result):
                    state = .finished(nil)
                    continuation.resume(with: result ?? .failure(CancellationError()))
                case .listening:
                    waiter = continuation
                    if let duration {
                        timeout = Task { [weak self] in
                            try? await Task.sleep(for: duration)
                            guard !Task.isCancelled else { return }
                            await self?.finish(.failure(ServerError.timedOut))
                        }
                    }
                }
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
    }

    /// One terminal transition owns the result and every resource opened for this grant.
    private func finish(_ result: Result<URLComponents, Error>) {
        if case .finished = state { return }
        state = .finished(waiter == nil ? result : nil)
        timeout?.cancel()
        timeout = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()

        // Clearing the listener handler suppresses its cancellation callback.
        if case let .failure(error) = result {
            resumeStart(.failure(error))
        } else {
            resumeStart(.failure(CancellationError()))
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
    }

    /// Reads one HTTP request and answers it, so the browser tab shows something human.
    ///
    /// Accumulates until the request line is complete: `receive` returns as soon as a single
    /// byte is available, and TCP does not promise the browser's request arrives in one piece,
    /// so parsing the first chunk would reject a perfectly good redirect that happened to be
    /// split.
    ///
    /// A rejected or broken request ends only its connection. Only a callback completes the grant.
    private nonisolated static func receiveRequest(
        on connection: NWConnection,
        completion: @escaping @Sendable (URLComponents?) -> Void,
    ) {
        @Sendable func read(_ accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if error != nil {
                    connection.cancel()
                    completion(nil)
                    return
                }

                let buffer = accumulated + (data ?? Data())
                guard buffer.count <= 8192 else {
                    connection.cancel()
                    completion(nil)
                    return
                }

                guard let text = String(data: buffer, encoding: .utf8),
                    text.contains("\r\n") || text.contains("\n")
                else {
                    // Not a whole request line yet. Keep reading unless the peer is done or
                    // the request is implausibly large for what a redirect can carry.
                    if isComplete || buffer.count >= 8192 {
                        connection.cancel()
                        completion(nil)
                    } else {
                        read(buffer)
                    }
                    return
                }

                guard let components = parseRequestLine(text) else {
                    // A complete request line that is not GET /login must not finish the
                    // one-shot waiter: otherwise GET / or a lookalike wins the first-callback
                    // race and the real redirect is dropped.
                    reply(on: connection, status: "404 Not Found", body: "Not Found") { completion(nil) }
                    return
                }

                let body = "<html><body>Spotty is authorized. You can close this tab.</body></html>"
                // Flush the browser's response before the terminal transition closes all peers.
                reply(on: connection, status: "200 OK", body: body, contentType: "text/html; charset=utf-8") {
                    completion(components)
                }
            }
        }

        read(Data())
    }

    private nonisolated static func reply(
        on connection: NWConnection,
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        completion: @escaping @Sendable () -> Void
    ) {
        let response = """
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in
                connection.cancel()
                completion()
            })
    }

    /// Pulls the query out of an HTTP request line: `GET /login?code=…&state=… HTTP/1.1`.
    ///
    /// Split out so the parsing can be tested without a socket.
    nonisolated static func parseRequestLine(_ request: String) -> URLComponents? {
        LoopbackRequestParser.parseRequestLine(request)
    }
}

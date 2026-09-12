import Foundation
import os
import SpottyRuntimeContracts

protocol ArtworkSourceLoading: Sendable {
    func load(_ url: URL) async throws -> Data
    func cancelAll() async
}

/// No shared response cache, authentication state or disk cache participates in artwork loads.
actor ArtworkSourceLoader: ArtworkSourceLoading {
    private let maximumSourceBytes: Int
    private let allowFileURLs: Bool
    private let protocolClasses: [AnyClass]?
    private var generation: UInt64 = 0
    private var session: URLSession
    private var transfers: ArtworkTransferDelegate
    private var fileReads: [UUID: Task<Data, any Error>] = [:]

    init(
        maximumSourceBytes: Int = 8 * 1_024 * 1_024, allowFileURLs: Bool = false,
        protocolClasses: [AnyClass]? = nil
    ) {
        precondition(maximumSourceBytes > 0 && maximumSourceBytes < Int.max)
        self.maximumSourceBytes = maximumSourceBytes
        self.allowFileURLs = allowFileURLs
        self.protocolClasses = protocolClasses
        let transfers = ArtworkTransferDelegate()
        self.transfers = transfers
        session = Self.makeSession(delegate: transfers, protocolClasses: protocolClasses)
    }

    func load(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let stamp = generation
        if url.isFileURL {
            guard allowFileURLs else { throw ArtworkFailure.unsupportedURL }
            let limit = maximumSourceBytes
            let id = UUID()
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ArtworkFailure.unsupportedURL }
                if let size = values.fileSize, size > limit { throw ArtworkFailure.tooLarge }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: limit + 1) ?? Data()
                try Task.checkCancellation()
                guard data.count <= limit else { throw ArtworkFailure.tooLarge }
                return data
            }
            fileReads[id] = task
            defer { fileReads[id] = nil }
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == stamp else { throw CancellationError() }
            return data
        }
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ArtworkFailure.unsupportedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        let transfer = transfers.register(task, maximumBytes: maximumSourceBytes)
        let data = try await transfer.value()
        try Task.checkCancellation()
        guard generation == stamp else { throw CancellationError() }
        return data
    }

    func cancelAll() {
        generation &+= 1
        fileReads.values.forEach { $0.cancel() }
        fileReads.removeAll()
        transfers.cancelAll()
        session.invalidateAndCancel()
        transfers = ArtworkTransferDelegate()
        session = Self.makeSession(delegate: transfers, protocolClasses: protocolClasses)
    }

    private static func makeSession(delegate: ArtworkTransferDelegate, protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

/// URLSession supplies chunks on its delegate queue. Each chunk is checked before one append;
/// the account actor suspends only for the whole transfer, never to consume individual bytes.
private final class ArtworkTransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let transfers = OSAllocatedUnfairLock(initialState: [Int: ArtworkTransfer]())

    func register(_ task: URLSessionDataTask, maximumBytes: Int) -> ArtworkTransfer {
        let id = task.taskIdentifier
        let transfer = ArtworkTransfer(task: task, maximumBytes: maximumBytes) { [weak self] in
            self?.transfers.withLock { $0[id] = nil }
        }
        transfers.withLock { $0[id] = transfer }
        return transfer
    }

    func cancelAll() {
        let pending = transfers.withLock { value in
            let pending = Array(value.values)
            value.removeAll()
            return pending
        }
        pending.forEach { $0.cancel() }
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let transfer = transfers.withLock { $0[dataTask.taskIdentifier] }
        completionHandler(transfer?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfers.withLock { $0[dataTask.taskIdentifier] }?.receive(data)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        transfers.withLock { $0[task.taskIdentifier] }?.complete(error: error)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil, request.url?.password == nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Cancellation can precede continuation installation or race any delegate callback. This lock
/// owns both the capped source buffer and the exactly-once completion of one network request.
private final class ArtworkTransfer: Sendable {
    private struct State: Sendable {
        var data = Data()
        var receivedResponse = false
        var finished = false
        var continuation: CheckedContinuation<Data, any Error>?
        var earlyResult: Result<Data, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let task: URLSessionDataTask
    private let maximumBytes: Int
    private let onFinish: @Sendable () -> Void

    init(task: URLSessionDataTask, maximumBytes: Int, onFinish: @escaping @Sendable () -> Void) {
        self.task = task
        self.maximumBytes = maximumBytes
        self.onFinish = onFinish
    }

    func value() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { value -> Result<Data, any Error>? in
                    if value.finished {
                        guard let result = value.earlyResult else { preconditionFailure("Transfer awaited twice") }
                        value.earlyResult = nil
                        return result
                    }
                    precondition(value.continuation == nil, "Transfer awaited twice")
                    value.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) } else { task.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            complete(error: ArtworkFailure.unavailable)
            return false
        }
        guard response.expectedContentLength <= maximumBytes else {
            complete(error: ArtworkFailure.tooLarge)
            return false
        }
        return state.withLock { value in
            guard !value.finished else { return false }
            value.receivedResponse = true
            value.data.reserveCapacity(max(0, Int(response.expectedContentLength)))
            return true
        }
    }

    func receive(_ data: Data) {
        let failure = state.withLock { value -> ArtworkFailure? in
            guard !value.finished else { return nil }
            guard value.receivedResponse else { return .unavailable }
            guard data.count <= maximumBytes - value.data.count else { return .tooLarge }
            value.data.append(data)
            return nil
        }
        if let failure { complete(error: failure) }
    }

    func cancel() { complete(error: CancellationError()) }

    func complete(error: (any Error)?) {
        let completion = state.withLock { value -> (Result<Data, any Error>, CheckedContinuation<Data, any Error>?)? in
            guard !value.finished else { return nil }
            value.finished = true
            let result: Result<Data, any Error>
            if let error {
                result = .failure(error)
            } else if value.receivedResponse {
                result = .success(value.data)
            } else {
                result = .failure(ArtworkFailure.unavailable)
            }
            value.data = Data()
            let continuation = value.continuation
            value.continuation = nil
            if continuation == nil { value.earlyResult = result }
            return (result, continuation)
        }
        guard let (result, continuation) = completion else { return }
        onFinish()
        task.cancel()
        continuation?.resume(with: result)
    }
}
